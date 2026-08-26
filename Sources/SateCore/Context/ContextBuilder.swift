import Foundation

/// Per-model context budget. Model strings are free-form (`anthropic/claude-opus-5`,
/// `dynamic/my-route`, …) and the gateway does not expose a context-length table,
/// so the numbers are user-editable rather than looked up.
public struct ContextWindow: Sendable, Hashable, Codable {
    public var model: String
    public var inputBudgetTokens: Int
    /// Held back so the completion has room; the provider counts prompt + output
    /// against one window.
    public var reserveForOutputTokens: Int

    public init(model: String, inputBudgetTokens: Int = 100_000, reserveForOutputTokens: Int = 8000) {
        self.model = model
        self.inputBudgetTokens = inputBudgetTokens
        self.reserveForOutputTokens = reserveForOutputTokens
    }

    /// Tokens actually available to history + system prompt.
    public var effectiveBudgetTokens: Int {
        max(0, inputBudgetTokens - reserveForOutputTokens)
    }

    private enum CodingKeys: String, CodingKey {
        case model, inputBudgetTokens, reserveForOutputTokens
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        inputBudgetTokens = try container.decodeIfPresent(Int.self, forKey: .inputBudgetTokens) ?? 100_000
        reserveForOutputTokens = try container.decodeIfPresent(Int.self, forKey: .reserveForOutputTokens) ?? 8000
    }
}

public struct BuiltContext: Sendable {
    /// Ready to serialize onto the wire: system prompt first (when set), then the
    /// surviving branch messages, reasoning stripped.
    public var messages: [Message]
    public var estimatedTokens: Int
    /// Branch messages that did not make it — trimmed pairs *and* empty assistant
    /// turns that were skipped. The system prompt is not counted; it is never dropped.
    public var droppedMessageCount: Int

    public init(messages: [Message], estimatedTokens: Int, droppedMessageCount: Int) {
        self.messages = messages
        self.estimatedTokens = estimatedTokens
        self.droppedMessageCount = droppedMessageCount
    }
}

/// Turns a conversation branch into the exact `messages[]` to send.
///
/// Trimming is oldest-first at *pair* granularity: dropping a user turn without
/// its assistant reply leaves the model reading a reply to nothing, which
/// degrades answers and confuses providers that validate alternation.
///
/// Intermediate search rounds (tool calls + tool results) are evicted before
/// dropping whole dialogue turns (R3.3) — search snippets age worse than dialogue.
public struct ContextBuilder: Sendable {
    public var estimator: TokenEstimator

    public init(estimator: TokenEstimator = TokenEstimator()) {
        self.estimator = estimator
    }

    public func build(branch: [Message], systemPrompt: String?, window: ContextWindow) -> BuiltContext {
        let sanitized = sanitize(branch)
        var groups = group(sanitized)
        let budget = window.effectiveBudgetTokens

        let systemCost: Int
        let systemMessage: Message?
        if let systemPrompt, !systemPrompt.isEmpty {
            systemMessage = Message(role: .system, content: [.text(systemPrompt)])
            systemCost = estimator.estimate(characters: systemPrompt.count, model: window.model)
                + TokenEstimator.perMessageOverheadTokens
        } else {
            systemMessage = nil
            systemCost = 0
        }

        func groupCost(_ g: MessageGroup) -> Int {
            g.messages.reduce(0) { partial, message in
                var chars = message.text.count
                if let toolCalls = message.toolCalls {
                    for call in toolCalls {
                        chars += call.name.count + call.arguments.count
                    }
                }
                return partial + estimator.estimate(characters: chars, model: window.model)
                    + TokenEstimator.perMessageOverheadTokens
            }
        }

        var total = systemCost + groups.map(groupCost).reduce(0, +)

        // Pass 1 (R3.3): Trim oldest search rounds from older, non-protected groups
        // before dropping whole dialogue turns.
        if total > budget {
            for i in 0 ..< groups.count where !groups[i].isProtected {
                let trimmed = trimSearchRounds(from: groups[i].messages)
                if trimmed.count < groups[i].messages.count {
                    let oldCost = groupCost(groups[i])
                    groups[i].messages = trimmed
                    let newCost = groupCost(groups[i])
                    total -= (oldCost - newCost)
                    if total <= budget {
                        break
                    }
                }
            }
        }

        // Pass 2: Drop oldest non-protected turn groups.
        var dropped = Set<Int>()
        var index = 0
        while total > budget, index < groups.count {
            // A protected group (the latest user turn, or a pinned system turn) is
            // sent even when it alone blows the budget: better a provider error
            // that names the real limit than silently answering without the question.
            if !groups[index].isProtected {
                dropped.insert(index)
                total -= groupCost(groups[index])
            }
            index += 1
        }

        var messages: [Message] = []
        if let systemMessage {
            messages.append(systemMessage)
        }
        var keptBranchCount = 0
        for (position, group) in groups.enumerated() where !dropped.contains(position) {
            messages.append(contentsOf: group.messages)
            keptBranchCount += group.messages.count
        }

        return BuiltContext(
            messages: messages,
            estimatedTokens: estimator.estimate(messages, systemPrompt: nil, model: window.model),
            droppedMessageCount: branch.count - keptBranchCount
        )
    }

    /// Re-trims after a context-length rejection. The provider's real limit is
    /// unknown, so shrink the previously-attempted budget by a fraction rather
    /// than guessing an absolute number.
    public func rebuild(
        branch: [Message],
        systemPrompt: String?,
        window: ContextWindow,
        shrinkTo fraction: Double
    ) -> BuiltContext {
        let clamped = min(max(fraction, 0.05), 1.0)
        let shrunkBudget = Int((Double(window.effectiveBudgetTokens) * clamped).rounded(.down))
        var narrowed = window
        narrowed.inputBudgetTokens = shrunkBudget + window.reserveForOutputTokens
        return build(branch: branch, systemPrompt: systemPrompt, window: narrowed)
    }

    /// Distinguishes "your prompt is too big" from every other 400. Providers all
    /// phrase it differently and none of them use a stable error code, so the app
    /// matches text; a false positive costs one wasted retry, a false negative
    /// shows the user a dead end.
    public static func isContextLengthError(_ message: String) -> Bool {
        // Backticks appear in Anthropic's wording; drop them so one pattern matches
        // both the raw and the prettified message.
        let normalized = message.lowercased().replacingOccurrences(of: "`", with: "")
        let patterns = [
            "context length",
            "context_length_exceeded",
            "maximum context",
            "too many tokens",
            "prompt is too long",
            "input length and max_tokens exceed",
        ]
        return patterns.contains { normalized.contains($0) }
    }

    // MARK: - Internals

    private struct MessageGroup {
        var messages: [Message]
        var isProtected: Bool
    }

    /// Drops empty assistant turns, orphaned tools, and strips reasoning.
    ///
    /// Tool calls and tool responses are validated so that an assistant message
    /// with `tool_calls` is never sent without its matching tool responses.
    private func sanitize(_ branch: [Message]) -> [Message] {
        var result: [Message] = []
        var i = 0

        while i < branch.count {
            let message = branch[i]

            if message.role == .assistant {
                let hasToolCalls = !(message.toolCalls?.isEmpty ?? true)
                let textEmpty = message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                // Empty assistant turn with no tool calls is dropped.
                if textEmpty, !hasToolCalls {
                    i += 1
                    continue
                }

                var copy = message
                copy.reasoning = nil

                if hasToolCalls {
                    // Check if following messages contain corresponding tool results.
                    var toolMessages: [Message] = []
                    var j = i + 1
                    while j < branch.count, branch[j].role == .tool {
                        var toolCopy = branch[j]
                        toolCopy.reasoning = nil
                        toolMessages.append(toolCopy)
                        j += 1
                    }

                    if toolMessages.isEmpty {
                        // Orphaned assistant tool_calls with no tool responses.
                        // If it has text, strip toolCalls; otherwise drop it.
                        if !textEmpty {
                            copy.toolCalls = nil
                            result.append(copy)
                        }
                    } else {
                        result.append(copy)
                        result.append(contentsOf: toolMessages)
                    }
                    i = j
                    continue
                } else {
                    result.append(copy)
                    i += 1
                    continue
                }
            } else if message.role == .tool {
                // Orphaned tool message not preceded by assistant toolCalls is dropped.
                i += 1
                continue
            } else {
                var copy = message
                copy.reasoning = nil
                result.append(copy)
                i += 1
            }
        }

        return result
    }

    /// Trims intermediate search rounds (assistant tool_call + tool responses)
    /// from a turn group, keeping the user message and final assistant reply.
    private func trimSearchRounds(from messages: [Message]) -> [Message] {
        guard messages.count > 2 else { return messages }
        guard let userMsg = messages.first, userMsg.role == .user else { return messages }
        guard let lastAssistant = messages.last, lastAssistant.role == .assistant,
              (lastAssistant.toolCalls?.isEmpty ?? true)
        else {
            return messages
        }

        // Return user turn + final assistant reply, shedding intermediate search rounds.
        return [userMsg, lastAssistant]
    }

    /// Splits the branch into droppable units. A unit starts at each user message
    /// and absorbs the assistant (and tool) turns that answer it.
    private func group(_ messages: [Message]) -> [MessageGroup] {
        var groups: [MessageGroup] = []
        var lastUserGroup: Int?
        for message in messages {
            if message.role == .user || groups.isEmpty {
                groups.append(MessageGroup(messages: [message], isProtected: false))
            } else {
                groups[groups.count - 1].messages.append(message)
            }
            if message.role == .user {
                lastUserGroup = groups.count - 1
            }
            // A system turn embedded in the branch is an instruction, not history.
            if message.role == .system {
                groups[groups.count - 1].isProtected = true
            }
        }
        if let lastUserGroup {
            groups[lastUserGroup].isProtected = true
        }
        return groups
    }
}
