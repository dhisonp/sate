import Foundation

/// One outbound chat-completions call, in app vocabulary. The codec turns this
/// into wire JSON; nothing here knows about Cloudflare or HTTP.
public struct ChatCompletionRequest: Sendable, Hashable {
    public var model: String
    /// Already trimmed to fit the context window by `ContextBuilder` — the codec
    /// never drops history for size, only for wire-legality.
    public var messages: [Message]
    public var systemPrompt: String?
    /// Always encoded, falling back to `ChatCompletionsCodec.defaultMaxTokens`:
    /// a client-side cancel does not reliably abort the upstream generation, so
    /// this is the only hard bound on the worst-case bill for a runaway answer.
    public var maxTokens: Int?
    public var temperature: Double?
    /// `stream_options: {include_usage: true}` is a per-model toggle because a
    /// few OpenAI-compat providers reject the field with a 400.
    public var includeUsage: Bool
    /// Provider passthrough, merged at the TOP LEVEL of the body.
    public var extra: [String: JSONValue]

    public init(
        model: String,
        messages: [Message] = [],
        systemPrompt: String? = nil,
        maxTokens: Int? = ChatCompletionsCodec.defaultMaxTokens,
        temperature: Double? = nil,
        includeUsage: Bool = true,
        extra: [String: JSONValue] = [:]
    ) {
        self.model = model
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.includeUsage = includeUsage
        self.extra = extra
    }
}

/// Pure, synchronous OpenAI chat-completions codec: request → JSON body, and one
/// SSE `data:` payload → zero or more `StreamEvent`s. No networking, no state.
///
/// **Finish/usage contract with `GatewayClient`** — the codec is stateless, so it
/// cannot know what an earlier chunk said. It therefore reports every terminal
/// signal it sees:
///   * a chunk carrying `choices[0].finish_reason` → `.finished(reason, usage?)`
///   * the `stream_options.include_usage` trailer (empty `choices` + `usage`) →
///     `.finished(.stop, usage)` — `.stop` is a placeholder, not an observation
/// `GatewayClient` coalesces these into exactly one terminal event: it keeps the
/// FIRST reason it saw and attaches the LAST usage it saw. Callers that use the
/// codec directly must do the same.
public struct ChatCompletionsCodec: Sendable {
    /// Conservative ceiling used whenever the caller supplies no `maxTokens`.
    public static let defaultMaxTokens = 4096

    /// Body keys the codec owns outright. `extra` may tune `max_tokens`,
    /// `temperature` or `stream_options`, but must never be able to retarget the
    /// request (`model`), rewrite the conversation (`messages`), or silently turn
    /// streaming off (`stream`) — that would strand the SSE reader.
    private static let reservedKeys: Set<String> = ["model", "messages", "stream"]

    public init() {}

    // MARK: - Encoding

    public func encodeBody(_ request: ChatCompletionRequest, stream: Bool) throws -> Data {
        var body: [String: JSONValue] = [
            "max_tokens": .number(Double(request.maxTokens ?? Self.defaultMaxTokens))
        ]
        if let temperature = request.temperature {
            body["temperature"] = .number(temperature)
        }
        if stream, request.includeUsage {
            body["stream_options"] = .object(["include_usage": .bool(true)])
        }
        for (key, value) in request.extra where !Self.reservedKeys.contains(key) {
            body[key] = value
        }
        body["model"] = .string(request.model)
        body["messages"] = .array(encodeMessages(request))
        body["stream"] = .bool(stream)

        let object = Self.foundationObject(.object(body))
        guard JSONSerialization.isValidJSONObject(object) else {
            throw GatewayError.protocolError("Request body is not encodable as JSON")
        }
        // JSONSerialization (rather than JSONEncoder) so integral numbers encode as
        // `4096` and not `4096.0`; some providers reject a float `max_tokens`.
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func encodeMessages(_ request: ChatCompletionRequest) -> [JSONValue] {
        var out: [JSONValue] = []
        if let prompt = request.systemPrompt, !prompt.isEmpty {
            out.append(.object(["role": .string("system"), "content": .string(prompt)]))
        }
        for message in request.messages {
            let text = message.text
            // `reasoning`/`reasoning_content` is display-only: replaying it makes
            // several backends 400, and it inflates the prompt for no benefit.
            // An empty assistant turn (cancelled before the first token) is also a
            // 400 on several backends, so it is dropped rather than sent blank.
            if message.role == .assistant, text.isEmpty { continue }
            out.append(.object(["role": .string(message.role.rawValue), "content": .string(text)]))
        }
        return out
    }

    /// JSON-object graph for `JSONSerialization`, collapsing integral doubles to
    /// `Int` so they render without a decimal point.
    private static func foundationObject(_ value: JSONValue) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let flag):
            return flag
        case .number(let number):
            if number.rounded() == number, number.magnitude < 9.007199254740992e15 {
                return Int(number)
            }
            return number
        case .string(let string):
            return string
        case .array(let values):
            return values.map(foundationObject)
        case .object(let values):
            return values.mapValues(foundationObject)
        }
    }

    // MARK: - Decoding

    /// Decode one SSE `data:` payload into 0..n events. `[DONE]` and blank
    /// payloads decode to nothing — termination is the client's business.
    public func decode(dataPayload: String) throws -> [StreamEvent] {
        let trimmed = dataPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "[DONE]" { return [] }
        let root = try Self.object(from: Data(trimmed.utf8), context: "stream chunk")
        try Self.throwIfError(root)

        var events = startedEvents(root)
        let usage = root["usage"].flatMap(Self.usage)
        let choices = Self.list(root["choices"]) ?? []

        // The `include_usage` trailer carries an EMPTY choices array — indexing it
        // blindly is the classic crash here.
        guard let choice = Self.fields(choices.first) else {
            if let usage { events.append(.finished(reason: .stop, usage: usage)) }
            return events
        }

        if let delta = Self.fields(choice["delta"]) {
            events.append(contentsOf: Self.deltaEvents(delta))
        }
        if let reason = choice["finish_reason"]?.stringValue {
            events.append(.finished(reason: FinishReason(rawValue: reason), usage: usage))
        } else if let usage {
            // A provider that puts usage on the same chunk as the last delta.
            events.append(.finished(reason: .stop, usage: usage))
        }
        return events
    }

    /// Decode a complete, non-streamed `application/json` body. Some models and
    /// some gateway fallbacks answer this way even when `stream: true` was asked
    /// for, so the client must be able to degrade to it without an error.
    public func decodeComplete(_ data: Data) throws -> [StreamEvent] {
        let root = try Self.object(from: data, context: "response body")
        try Self.throwIfError(root)

        var events = startedEvents(root)
        let usage = root["usage"].flatMap(Self.usage)
        let choice = Self.fields(Self.list(root["choices"])?.first)
        let message = Self.fields(choice?["message"])

        if let reasoning = message.flatMap(Self.reasoning), !reasoning.isEmpty {
            events.append(.reasoningDelta(reasoning))
        }
        if let text = message.flatMap({ Self.text(fromContent: $0["content"]) }), !text.isEmpty {
            events.append(.textDelta(text))
        }
        for call in Self.toolCallEvents(message?["tool_calls"]) {
            events.append(call)
        }
        let reason = choice?["finish_reason"]?.stringValue.map(FinishReason.init(rawValue:)) ?? .stop
        events.append(.finished(reason: reason, usage: usage))
        return events
    }

    /// `.started` is emitted by every chunk that identifies the response;
    /// `GatewayClient` forwards only the first.
    private func startedEvents(_ root: [String: JSONValue]) -> [StreamEvent] {
        let id = root["id"]?.stringValue
        let model = root["model"]?.stringValue
        guard id != nil || model != nil else { return [] }
        return [.started(responseID: id, model: model)]
    }

    private static func deltaEvents(_ delta: [String: JSONValue]) -> [StreamEvent] {
        var events: [StreamEvent] = []
        // `delta` is legitimately `{}` on the role-only opening chunk and
        // `content: null` on reasoning-only chunks — both emit nothing.
        if let reasoning = reasoning(delta), !reasoning.isEmpty {
            events.append(.reasoningDelta(reasoning))
        }
        if let text = text(fromContent: delta["content"]), !text.isEmpty {
            events.append(.textDelta(text))
        }
        events.append(contentsOf: toolCallEvents(delta["tool_calls"]))
        return events
    }

    /// DeepSeek spells it `reasoning_content`; xAI and others spell it `reasoning`.
    private static func reasoning(_ container: [String: JSONValue]) -> String? {
        container["reasoning_content"]?.stringValue ?? container["reasoning"]?.stringValue
    }

    /// `content` is a string on every streaming provider, but a parts array on
    /// some non-streamed replies.
    private static func text(fromContent value: JSONValue?) -> String? {
        switch value {
        case .string(let text):
            return text
        case .array(let parts):
            return parts.compactMap { fields($0)?["text"]?.stringValue }.joined()
        default:
            return nil
        }
    }

    private static func toolCallEvents(_ value: JSONValue?) -> [StreamEvent] {
        guard let calls = list(value) else { return [] }
        return calls.compactMap { element in
            guard let call = fields(element) else { return nil }
            // Fragments join on the element's own `index`, NOT its array position:
            // parallel calls interleave and a chunk may carry only call #2.
            let index = call["index"]?.intValue ?? 0
            let function = fields(call["function"])
            return .toolCallDelta(
                index: index,
                id: call["id"]?.stringValue,
                name: function?["name"]?.stringValue,
                argumentsFragment: function?["arguments"]?.stringValue ?? "")
        }
    }

    private static func usage(_ value: JSONValue) -> Usage? {
        guard let object = fields(value) else { return nil }
        let prompt = object["prompt_tokens"]?.intValue ?? 0
        let completion = object["completion_tokens"]?.intValue ?? 0
        let total = object["total_tokens"]?.intValue ?? (prompt + completion)
        return Usage(promptTokens: prompt, completionTokens: completion, totalTokens: total)
    }


    // Local accessors instead of a shared `JSONValue` extension: this file must not
    // add members to a type other slices of the package also extend.
    private static func fields(_ value: JSONValue?) -> [String: JSONValue]? {
        if case .object(let object) = value { return object }
        return nil
    }

    private static func list(_ value: JSONValue?) -> [JSONValue]? {
        if case .array(let array) = value { return array }
        return nil
    }

    private static func object(from data: Data, context: String) throws -> [String: JSONValue] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = fields(value)
        else {
            throw GatewayError.protocolError("Undecodable \(context)")
        }
        return object
    }

    /// `{"error":{"message":…,"type":…}}` and the bare `{"error":"…"}` form both
    /// arrive with HTTP 200 inside a stream. `"error": null` is not an error.
    private static func throwIfError(_ root: [String: JSONValue]) throws {
        guard let error = root["error"] else { return }
        switch error {
        case .object(let fields):
            let message = fields["message"]?.stringValue
                ?? fields["detail"]?.stringValue
                ?? "The provider reported an error."
            let code = fields["code"]?.stringValue
                ?? fields["code"]?.intValue.map(String.init)
                ?? fields["type"]?.stringValue
            throw GatewayError.inStreamError(code: code, message: message)
        case .string(let message):
            throw GatewayError.inStreamError(code: nil, message: message)
        case .null:
            return
        default:
            throw GatewayError.inStreamError(code: nil, message: "The provider reported an error.")
        }
    }
}
