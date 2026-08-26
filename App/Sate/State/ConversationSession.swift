import Foundation

// MARK: - Producer-side accumulation

/// Shared accumulator between the streaming loop and the trailing-flush timer.
///
/// A plain lock rather than an actor: `append` runs once per delta (hundreds per
/// second) and an actor would cost an executor hop each time, which is exactly
/// what the coalescer exists to avoid.
///
/// Both producers only ever *stage* text here; the main actor is the sole
/// consumer via `take()`. That is what makes ordering safe — two producers
/// hopping to the main actor independently could otherwise deliver flushes out
/// of order, and a response would render scrambled.
final class DeltaBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var coalescer: DeltaCoalescer
    private var readyText = ""
    private var readyReasoning = ""

    init(coalescer: DeltaCoalescer = DeltaCoalescer()) {
        self.coalescer = coalescer
    }

    /// Producer side. Returns true when a main-actor delivery should be scheduled.
    func append(text: String = "", reasoning: String = "") -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let flush = coalescer.append(text: text, reasoning: reasoning) else { return false }
        readyText += flush.text
        readyReasoning += flush.reasoning
        return true
    }

    /// Trailing timer and terminal drain: promotes whatever the cadence rule is
    /// still holding back. Returns true when there is something to deliver.
    func drainPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let flush = coalescer.drain() {
            readyText += flush.text
            readyReasoning += flush.reasoning
        }
        return !readyText.isEmpty || !readyReasoning.isEmpty
    }

    /// Main-actor side. Nil when another delivery already consumed everything.
    func take() -> DeltaCoalescer.Flush? {
        lock.lock()
        defer { lock.unlock() }
        guard !readyText.isEmpty || !readyReasoning.isEmpty else { return nil }
        let flush = DeltaCoalescer.Flush(text: readyText, reasoning: readyReasoning)
        readyText.removeAll(keepingCapacity: true)
        readyReasoning.removeAll(keepingCapacity: true)
        return flush
    }
}

// MARK: - Outcome

/// The single terminal result of one generation, delivered to the main actor
/// exactly once. `committed` is the assistant message already written to the
/// transcript — the view model does not persist anything itself.
struct GenerationOutcome: Sendable {
    var committed: Message?
    var finishReason: FinishReason?
    var usage: Usage?
    var error: GatewayError?
    var trace: NetworkTrace?
}

/// Main-actor callbacks a generation reports through. Passed as values rather
/// than a delegate so `ConversationSession` never holds the view model.
struct GenerationEvents: Sendable {
    var started: @MainActor @Sendable (_ responseID: String?, _ model: String?) -> Void
    var searching: (@MainActor @Sendable (String) -> Void)?
    /// The buffer is handed over rather than a `Flush` so the drain happens on
    /// the main actor — see `DeltaBuffer`.
    var flushed: @MainActor @Sendable (DeltaBuffer) -> Void
    var completed: @MainActor @Sendable (GenerationOutcome) -> Void

    init(
        started: @escaping @MainActor @Sendable (String?, String?) -> Void,
        searching: (@MainActor @Sendable (String) -> Void)? = nil,
        flushed: @escaping @MainActor @Sendable (DeltaBuffer) -> Void,
        completed: @escaping @MainActor @Sendable (GenerationOutcome) -> Void
    ) {
        self.started = started
        self.searching = searching
        self.flushed = flushed
        self.completed = completed
    }
}

// MARK: - Session

/// Owns the streaming and tool-execution `Task` for one conversation (R2.8 / R2).
///
/// The task lives here, held by `AppEnvironment`, and *not* in a SwiftUI `.task`:
/// `.task` is cancelled when the view disappears, so navigating back to the
/// conversation list would abort a response the user already paid for.
actor ConversationSession {
    /// Trailing-edge flush cadence. The coalescer holds back a delta that arrives
    /// less than ~16 ms after the last flush; if the model then pauses, that tail
    /// would sit unrendered until the next token. 50 ms is invisible to the eye
    /// and cheap enough to run for the whole length of a response.
    private static let trailingFlushNanoseconds: UInt64 = 50_000_000
    /// R2.4: at most one sidecar write every 2 s. More often stalls the stream on
    /// file I/O; less often risks losing a visible amount of paid-for text.
    private static let checkpointInterval: TimeInterval = 2

    nonisolated let conversationID: UUID
    private nonisolated let store: ConversationStore
    private var task: Task<Void, Never>?

    init(conversationID: UUID, store: ConversationStore) {
        self.conversationID = conversationID
        self.store = store
    }

    var isGenerating: Bool {
        task != nil
    }

    /// Starts a generation loop. Returns false when one is already in flight for this
    /// conversation (R2.10: max one).
    @discardableResult
    func start(
        request: ChatCompletionRequest,
        client: any LLMStreaming,
        searchProvider: (any SearchProvider)? = nil,
        searchEnabled: Bool = false,
        maxSearchRounds: Int = ToolRunner.maxRoundsDefault,
        searchResultsPerQuery: Int = ToolRunner.defaultResultsPerCall,
        parentID: UUID?,
        events: GenerationEvents
    ) -> Bool {
        guard task == nil else { return false }
        let conversationID = self.conversationID
        let store = self.store
        // Detached: the generation must outlive whatever view or task asked for
        // it, and the heavy per-delta loop must not run on this actor's executor.
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = await Self.generate(
                request: request,
                client: client,
                searchProvider: searchProvider,
                searchEnabled: searchEnabled,
                maxSearchRounds: maxSearchRounds,
                searchResultsPerQuery: searchResultsPerQuery,
                parentID: parentID,
                conversationID: conversationID,
                store: store,
                events: events
            )
            // Cleared before the callback so `isGenerating` is already false when
            // the view model reacts and, e.g., immediately starts a retry.
            await self?.clearTask()
            await MainActor.run { events.completed(outcome) }
        }
        return true
    }

    /// Cooperative cancel. The partial is still committed — see `generate`.
    func cancel() {
        task?.cancel()
    }

    /// Cancels and waits for the commit to land. Used for fork-mid-stream
    /// (R2.5): cancel → commit interrupted → append new user node → regenerate.
    func cancelAndWait() async {
        guard let task else { return }
        task.cancel()
        await task.value
    }

    private func clearTask() {
        task = nil
    }

    // MARK: The generation itself

    /// `static` and therefore nonisolated: every delta is handled on the
    /// concurrent executor, with no hop to this actor and none to the main actor
    /// except when the coalescer says it is time to render.
    private static func generate(
        request: ChatCompletionRequest,
        client: any LLMStreaming,
        searchProvider: (any SearchProvider)?,
        searchEnabled: Bool,
        maxSearchRounds: Int,
        searchResultsPerQuery: Int,
        parentID: UUID?,
        conversationID: UUID,
        store: ConversationStore,
        events: GenerationEvents
    ) async -> GenerationOutcome {
        var currentParentID = parentID
        var currentMessages = request.messages
        var currentRequest = request
        var round = 1
        var allSources: [SearchResult] = []
        var totalPromptTokens = 0
        var totalCompletionTokens = 0
        var finalOutcome: GenerationOutcome?
        let toolRunner = ToolRunner(
            searchProvider: searchProvider,
            maxRounds: maxSearchRounds,
            resultsPerQuery: searchResultsPerQuery
        )

        while round <= maxSearchRounds + 1 {
            let buffer = DeltaBuffer()
            var text = ""
            var reasoning = ""
            var finishReason: FinishReason?
            var roundUsage: Usage?
            var responseModel: String?
            var failure: GatewayError?
            var lastCheckpoint = Date()
            var toolCallFragments: [Int: (id: String?, name: String?, arguments: String)] = [:]

            let ticker = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: trailingFlushNanoseconds)
                    } catch {
                        return
                    }
                    guard buffer.drainPending() else { continue }
                    await MainActor.run { events.flushed(buffer) }
                }
            }

            do {
                for try await event in client.stream(currentRequest, conversationID: conversationID) {
                    switch event {
                    case let .started(responseID, model):
                        responseModel = model
                        await MainActor.run { events.started(responseID, model) }
                    case let .textDelta(delta):
                        text += delta
                        if buffer.append(text: delta) {
                            await MainActor.run { events.flushed(buffer) }
                        }
                    case let .reasoningDelta(delta):
                        reasoning += delta
                        if buffer.append(reasoning: delta) {
                            await MainActor.run { events.flushed(buffer) }
                        }
                    case let .toolCallDelta(index, id, name, argumentsFragment):
                        var current = toolCallFragments[index] ?? (id: nil, name: nil, arguments: "")
                        if let id {
                            current.id = id
                        }
                        if let name {
                            current.name = name
                        }
                        current.arguments += argumentsFragment
                        toolCallFragments[index] = current
                    case let .finished(reason, reported):
                        finishReason = reason
                        if let reported {
                            roundUsage = reported
                        }
                    }

                    if Date().timeIntervalSince(lastCheckpoint) >= checkpointInterval,
                       !text.isEmpty || !reasoning.isEmpty
                    {
                        lastCheckpoint = Date()
                        try? await store.checkpoint(
                            conversationID: conversationID,
                            parentID: currentParentID,
                            text: text,
                            reasoning: reasoning,
                            model: currentRequest.model
                        )
                    }
                }
            } catch let error as GatewayError {
                failure = error
            } catch is CancellationError {
                failure = .cancelled
            } catch {
                failure = .protocolError("\(error)")
            }

            if failure == nil, Task.isCancelled {
                failure = .cancelled
            }

            ticker.cancel()
            if buffer.drainPending() {
                await MainActor.run { events.flushed(buffer) }
            }

            if let roundUsage {
                totalPromptTokens += roundUsage.promptTokens
                totalCompletionTokens += roundUsage.completionTokens
            }

            let orderedToolCalls: [ToolCall] = toolCallFragments.keys.sorted().compactMap { index in
                guard let fragment = toolCallFragments[index],
                      let name = fragment.name ?? (fragment.id != nil ? "web_search" : nil)
                else { return nil }
                return ToolCall(
                    id: fragment.id ?? "call_\(index)",
                    name: name,
                    arguments: fragment.arguments
                )
            }

            let shouldExecuteTools = searchEnabled
                && failure == nil
                && (finishReason == .toolCalls || !orderedToolCalls.isEmpty)
                && round <= maxSearchRounds

            if shouldExecuteTools {
                // Commit the assistant turn carrying tool_calls (R2.3).
                let assistantMsg = Message(
                    parentID: currentParentID,
                    role: .assistant,
                    content: text.isEmpty ? [] : [.text(text)],
                    reasoning: reasoning.isEmpty ? nil : reasoning,
                    model: responseModel ?? currentRequest.model,
                    finishReason: .toolCalls,
                    usage: roundUsage,
                    interrupted: false,
                    logID: await client.lastTrace?.logID,
                    toolCalls: orderedToolCalls
                )

                do {
                    try await store.append(assistantMsg, to: conversationID)
                    currentParentID = assistantMsg.id
                    currentMessages.append(assistantMsg)
                } catch {
                    failure = .protocolError("The assistant tool call message could not be saved.")
                    break
                }

                if Task.isCancelled {
                    failure = .cancelled
                    break
                }

                // Execute tool calls via ToolRunner.
                let executionResults = await toolRunner.execute(
                    toolCalls: orderedToolCalls,
                    round: round,
                    onSearching: { query in
                        Task { @MainActor in events.searching?(query) }
                    }
                )

                if Task.isCancelled {
                    failure = .cancelled
                    break
                }

                // Commit tool result messages in deterministic index order (R2.5).
                for result in executionResults {
                    let toolMsg = Message(
                        parentID: currentParentID,
                        role: .tool,
                        content: [.text(result.content)],
                        toolCallID: result.toolCallID,
                        sources: result.results.isEmpty ? nil : result.results
                    )
                    do {
                        try await store.append(toolMsg, to: conversationID)
                        currentParentID = toolMsg.id
                        currentMessages.append(toolMsg)
                        allSources.append(contentsOf: result.results)
                    } catch {
                        failure = .protocolError("The tool response message could not be saved.")
                        break
                    }
                }

                if Task.isCancelled || failure != nil {
                    break
                }

                // Prepare next round request with updated message history.
                currentRequest.messages = currentMessages
                round += 1
                continue
            } else {
                // Final answer or non-tool completion.
                let cumulativeUsage: Usage? = (totalPromptTokens > 0 || totalCompletionTokens > 0)
                    ? Usage(
                        promptTokens: totalPromptTokens,
                        completionTokens: totalCompletionTokens,
                        totalTokens: Usage.clampedSum(totalPromptTokens, totalCompletionTokens)
                    )
                    : roundUsage

                let trace = await client.lastTrace
                var outcome = GenerationOutcome(
                    finishReason: finishReason,
                    usage: cumulativeUsage,
                    error: failure,
                    trace: trace
                )

                let clean = failure == nil && (finishReason?.isClean ?? false)
                if !text.isEmpty || !reasoning.isEmpty || !allSources.isEmpty {
                    let message = Message(
                        parentID: currentParentID,
                        role: .assistant,
                        content: [.text(text)],
                        reasoning: reasoning.isEmpty ? nil : reasoning,
                        model: responseModel ?? currentRequest.model,
                        finishReason: finishReason ?? .truncated,
                        usage: cumulativeUsage,
                        interrupted: !clean,
                        logID: outcome.trace?.logID,
                        sources: allSources.isEmpty ? nil : allSources
                    )
                    do {
                        try await store.append(message, to: conversationID)
                        outcome.committed = message
                    } catch {
                        outcome.error = outcome.error ?? .protocolError("The response could not be saved.")
                    }
                } else {
                    try? await store.clearCheckpoint(conversationID)
                }

                finalOutcome = outcome
                break
            }
        }

        if let finalOutcome {
            return finalOutcome
        }

        return GenerationOutcome(
            finishReason: .truncated,
            usage: nil,
            error: .cancelled,
            trace: await client.lastTrace
        )
    }
}
