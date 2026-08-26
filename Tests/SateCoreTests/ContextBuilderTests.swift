import Foundation
import Testing
@testable import SateCore

private let testModel = "anthropic/claude-opus-5"

/// 360 characters is exactly 100 tokens at the default 3.6 chars/token, so every
/// budget in these tests is arithmetic rather than guesswork.
private func text(_ count: Int = 360, _ filler: Character = "a") -> String {
    String(repeating: String(filler), count: count)
}

private func userMessage(_ characters: Int = 360) -> Message {
    Message.user(text(characters))
}

private func assistantMessage(_ characters: Int = 360, reasoning: String? = nil) -> Message {
    Message(role: .assistant, content: [.text(text(characters, "b"))], reasoning: reasoning)
}

/// `pairs` user/assistant exchanges followed by a fresh, unanswered user turn.
private func branch(pairs: Int) -> [Message] {
    var messages: [Message] = []
    for _ in 0..<pairs {
        messages.append(userMessage())
        messages.append(assistantMessage())
    }
    messages.append(userMessage())
    return messages
}

@Suite("ContextBuilder")
struct ContextBuilderTests {
    private let builder = ContextBuilder()

    @Test("Trims oldest first, keeping the system prompt and the latest user turn")
    func trimsOldestFirst() {
        let history = branch(pairs: 4)
        let prompt = text(36, "s")
        // 14 (system) + 4 * 208 (pairs) + 104 (latest user) = 950 estimated.
        let window = ContextWindow(model: testModel, inputBudgetTokens: 600, reserveForOutputTokens: 100)
        let built = builder.build(branch: history, systemPrompt: prompt, window: window)

        #expect(built.messages.first?.role == .system)
        #expect(built.messages.first?.text == prompt)
        #expect(built.messages.last?.id == history.last?.id)
        #expect(built.estimatedTokens <= window.effectiveBudgetTokens)
        // Three oldest pairs go; the last pair and the new user turn stay.
        #expect(built.messages.count == 4)
        #expect(built.droppedMessageCount == 6)
        #expect(built.messages.dropFirst().map(\.id) == history.suffix(3).map(\.id))
    }

    @Test("Never leaves a dangling assistant turn")
    func neverSplitsPairs() {
        let history = branch(pairs: 4)
        let window = ContextWindow(model: testModel, inputBudgetTokens: 500, reserveForOutputTokens: 100)
        let built = builder.build(branch: history, systemPrompt: nil, window: window)

        #expect(built.messages.first?.role == .user)
        var previousRole: MessageRole?
        for message in built.messages {
            if message.role == .assistant {
                #expect(previousRole == .user)
            }
            previousRole = message.role
        }
    }

    @Test("A single over-budget user message is still sent")
    func oversizedUserMessageSurvives() {
        let huge = userMessage(36_000)
        let window = ContextWindow(model: testModel, inputBudgetTokens: 100, reserveForOutputTokens: 0)
        let built = builder.build(branch: [huge], systemPrompt: "hi", window: window)

        #expect(built.droppedMessageCount == 0)
        #expect(built.messages.count == 2)
        #expect(built.messages.last?.id == huge.id)
        // Deliberately over budget: the provider gets to state the real limit.
        #expect(built.estimatedTokens > window.effectiveBudgetTokens)
    }

    @Test("Empty assistant turns are skipped")
    func skipsEmptyAssistantMessages() {
        let first = userMessage(10)
        let interrupted = Message(role: .assistant, content: [.text("")])
        let whitespace = Message(role: .assistant, content: [.text("  \n ")])
        let latest = userMessage(10)
        let window = ContextWindow(model: testModel)
        let built = builder.build(branch: [first, interrupted, whitespace, latest], systemPrompt: nil, window: window)

        #expect(built.messages.map(\.id) == [first.id, latest.id])
        #expect(built.messages.allSatisfy { $0.role == .user })
        #expect(built.droppedMessageCount == 2)
    }

    @Test("Reasoning is stripped and not counted")
    func stripsReasoning() {
        let answer = assistantMessage(10, reasoning: text(10_000, "r"))
        let history = [userMessage(10), answer, userMessage(10)]
        let window = ContextWindow(model: testModel)
        let built = builder.build(branch: history, systemPrompt: nil, window: window)

        #expect(built.messages.count == 3)
        #expect(built.messages.allSatisfy { $0.reasoning == nil })
        #expect(built.messages[1].text == answer.text)
        // 3 messages * (3 content tokens + 4 framing); the 10k reasoning chars are
        // absent, so nothing near 2778 tokens shows up.
        #expect(built.estimatedTokens == 3 * (3 + TokenEstimator.perMessageOverheadTokens))
    }

    @Test("Nothing is dropped when the branch fits")
    func keepsEverythingWhenUnderBudget() {
        let history = branch(pairs: 3)
        let built = builder.build(
            branch: history,
            systemPrompt: "be brief",
            window: ContextWindow(model: testModel)
        )
        #expect(built.droppedMessageCount == 0)
        #expect(built.messages.count == history.count + 1)
    }

    @Test("No system message is emitted when there is no system prompt")
    func omitsEmptySystemPrompt() {
        let history = branch(pairs: 1)
        let withNil = builder.build(branch: history, systemPrompt: nil, window: ContextWindow(model: testModel))
        let withEmpty = builder.build(branch: history, systemPrompt: "", window: ContextWindow(model: testModel))
        #expect(withNil.messages.count == history.count)
        #expect(withEmpty.messages.count == history.count)
        #expect(!withNil.messages.contains { $0.role == .system })
    }

    @Test("rebuild(shrinkTo:) drops strictly more than the original build")
    func rebuildShrinksFurther() {
        let history = branch(pairs: 4)
        let prompt = text(36, "s")
        // 800 usable tokens: one pair goes. 600 after shrinking: two pairs go.
        let window = ContextWindow(model: testModel, inputBudgetTokens: 900, reserveForOutputTokens: 100)
        let original = builder.build(branch: history, systemPrompt: prompt, window: window)
        let retried = builder.rebuild(branch: history, systemPrompt: prompt, window: window, shrinkTo: 0.75)

        #expect(original.droppedMessageCount == 2)
        #expect(retried.droppedMessageCount == 4)
        #expect(retried.droppedMessageCount > original.droppedMessageCount)
        #expect(retried.estimatedTokens < original.estimatedTokens)
        #expect(retried.messages.last?.id == history.last?.id)
        #expect(retried.messages.first?.role == .system)
    }

    @Test("rebuild never trims away the latest user turn, however small the fraction")
    func rebuildKeepsLatestUserTurn() {
        let history = branch(pairs: 4)
        let window = ContextWindow(model: testModel, inputBudgetTokens: 900, reserveForOutputTokens: 100)
        let retried = builder.rebuild(branch: history, systemPrompt: "sys", window: window, shrinkTo: 0.0)
        #expect(retried.messages.contains { $0.id == history.last?.id })
        #expect(retried.messages.first?.role == .system)
    }

    @Test("An empty branch produces just the system prompt")
    func emptyBranch() {
        let built = builder.build(branch: [], systemPrompt: "sys", window: ContextWindow(model: testModel))
        #expect(built.messages.count == 1)
        #expect(built.messages.first?.role == .system)
        #expect(built.droppedMessageCount == 0)
    }

    @Test("A calibrated estimator changes what fits", arguments: [2.0, 6.0])
    func calibrationAffectsTrimming(ratio: Double) {
        var estimator = TokenEstimator()
        for _ in 0..<20 {
            estimator.calibrate(model: testModel, characters: Int(ratio * 1000), promptTokens: 1000)
        }
        var calibrated = ContextBuilder()
        calibrated.estimator = estimator
        let history = branch(pairs: 4)
        let window = ContextWindow(model: testModel, inputBudgetTokens: 600, reserveForOutputTokens: 100)
        let built = calibrated.build(branch: history, systemPrompt: nil, window: window)
        // Fewer chars per token => more tokens per message => more gets dropped.
        if ratio < 3.6 {
            #expect(built.droppedMessageCount > 6)
        } else {
            #expect(built.droppedMessageCount < 6)
        }
        #expect(built.messages.last?.id == history.last?.id)
    }

    @Test("Context-length rejections are recognised", arguments: [
        "This model's maximum context length is 200000 tokens, however you requested 250000",
        "context_length_exceeded",
        "Context Length exceeded for this request",
        "prompt is too long: 250000 tokens > 200000 maximum",
        "Too Many Tokens in the request",
        "input length and `max_tokens` exceed context limit: 199000 + 4096 > 200000",
        "input length and max_tokens exceed context limit"
    ])
    func detectsContextLengthErrors(message: String) {
        #expect(ContextBuilder.isContextLengthError(message))
    }

    @Test("Other 400s are not mistaken for context-length rejections", arguments: [
        "",
        "invalid_api_key: the provided token is not valid",
        "model not found: anthropic/nope",
        "rate limit exceeded, retry after 30s",
        "temperature must be between 0 and 2",
        "content policy violation"
    ])
    func rejectsUnrelatedErrors(message: String) {
        #expect(!ContextBuilder.isContextLengthError(message))
    }
}

@Suite("SateSettings context configuration")
struct SateSettingsTests {
    @Test("Fresh settings carry the documented defaults")
    func defaults() {
        let settings = SateSettings()
        #expect(settings.defaultModel == "anthropic/claude-opus-5")
        #expect(settings.titleModel == "openai/gpt-5.2-mini")
        #expect(settings.maxTokens == 4096)
        #expect(settings.includeUsage)
        #expect(settings.collectLogPayload)
        #expect(settings.temperature == nil)
        #expect(!settings.showDebugPanel)
        #expect(!settings.isConfigured)
    }

    @Test("isConfigured tracks the account ID only")
    func isConfigured() {
        var settings = SateSettings()
        settings.accountID = "   "
        #expect(!settings.isConfigured)
        settings.accountID = "abc123"
        #expect(settings.isConfigured)
    }

    @Test("Decoding a blob missing most keys falls back to defaults")
    func decodesSparseBlob() throws {
        let json = Data(#"{"accountID":"acct","maxTokens":8192,"unknownFutureKey":true}"#.utf8)
        let settings = try JSONDecoder().decode(SateSettings.self, from: json)
        #expect(settings.accountID == "acct")
        #expect(settings.maxTokens == 8192)
        #expect(settings.gatewayID == "")
        #expect(settings.defaultModel == "anthropic/claude-opus-5")
        #expect(settings.titleModel == "openai/gpt-5.2-mini")
        #expect(settings.includeUsage)
        #expect(settings.contextWindows.isEmpty)
        #expect(settings.isConfigured)
    }

    @Test("Decoding an empty object yields exactly the defaults")
    func decodesEmptyObject() throws {
        let settings = try JSONDecoder().decode(SateSettings.self, from: Data("{}".utf8))
        #expect(settings == SateSettings())
    }

    @Test("Settings round-trip through Codable and never carry the token")
    func codableRoundTrip() throws {
        var settings = SateSettings()
        settings.accountID = "acct"
        settings.gatewayID = "gw"
        settings.temperature = 0.7
        settings.contextWindows["dynamic/route"] = ContextWindow(
            model: "dynamic/route", inputBudgetTokens: 32_000, reserveForOutputTokens: 2_000
        )
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(SateSettings.self, from: data) == settings)

        // The Cloudflare token belongs to the SecretStore and must never appear in
        // a settings blob, which is written to UserDefaults in the clear.
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = Set(object?.keys ?? [:].keys)
        #expect(!keys.contains("token"))
        #expect(!keys.contains("apiToken"))
        #expect(!keys.contains("secret"))
        #expect(keys.contains("maxTokens"))
    }

    @Test("window(for:) returns the stored budget or a default one")
    func windowLookup() {
        var settings = SateSettings()
        settings.contextWindows["openai/gpt-5.2"] = ContextWindow(
            model: "openai/gpt-5.2", inputBudgetTokens: 40_000, reserveForOutputTokens: 4_000
        )
        let stored = settings.window(for: "openai/gpt-5.2")
        #expect(stored.inputBudgetTokens == 40_000)
        #expect(stored.effectiveBudgetTokens == 36_000)

        let fallback = settings.window(for: "anthropic/claude-opus-5")
        #expect(fallback.model == "anthropic/claude-opus-5")
        #expect(fallback.inputBudgetTokens == 100_000)
    }

    @Test("A ContextWindow blob missing keys decodes with defaults")
    func contextWindowSparseDecode() throws {
        let window = try JSONDecoder().decode(ContextWindow.self, from: Data(#"{"model":"m"}"#.utf8))
        #expect(window.inputBudgetTokens == 100_000)
        #expect(window.reserveForOutputTokens == 8_000)
    }

    @Test("InMemorySecretStore stores and clears the token")
    func inMemorySecretStore() throws {
        let store = InMemorySecretStore()
        let empty = try store.token()
        #expect(empty == nil)
        try store.setToken("cf-token")
        let stored = try store.token()
        #expect(stored == "cf-token")
        try store.setToken(nil)
        let cleared = try store.token()
        #expect(cleared == nil)
        let seeded = try InMemorySecretStore(token: "seed").token()
        #expect(seeded == "seed")
    }
}
