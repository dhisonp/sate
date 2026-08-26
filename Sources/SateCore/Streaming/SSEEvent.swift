import Foundation

/// One dispatched Server-Sent Event, after framing but before any JSON decoding.
/// `SSEParser` knows nothing about chat completions; `ChatCompletionsCodec`
/// knows nothing about bytes.
public struct SSEEvent: Hashable, Sendable {
    /// The `event:` field, absent for the default `message` type.
    public var name: String?
    /// Multiple `data:` lines joined with "\n", per the SSE specification.
    public var data: String
    public var id: String?

    public init(name: String? = nil, data: String, id: String? = nil) {
        self.name = name
        self.data = data
        self.id = id
    }

    /// OpenAI-style terminator. Tolerates trailing whitespace.
    public var isTerminator: Bool {
        data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]"
    }
}
