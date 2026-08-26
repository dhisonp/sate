import Foundation

public enum MessageRole: String, Codable, Hashable, Sendable {
    case system, user, assistant, tool
}

/// Why a generation stopped. `unknown` preserves the raw provider string instead
/// of failing, because the OpenAI-compat layer passes provider values through.
public enum FinishReason: Hashable, Sendable {
    case stop
    case length
    case toolCalls
    case contentFilter
    /// The stream ended without any `finish_reason` — treat as interrupted.
    case truncated
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "stop", "end_turn", "stop_sequence": self = .stop
        case "length", "max_tokens": self = .length
        case "tool_calls", "tool_use", "function_call": self = .toolCalls
        case "content_filter", "refusal": self = .contentFilter
        // Round-trips our own persisted value: a recovered interrupted message
        // must decode back to .truncated, not .unknown("truncated").
        case "truncated": self = .truncated
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .stop: return "stop"
        case .length: return "length"
        case .toolCalls: return "tool_calls"
        case .contentFilter: return "content_filter"
        case .truncated: return "truncated"
        case let .unknown(value): return value
        }
    }

    /// Only `.stop` is a clean completion; everything else marks the message.
    public var isClean: Bool {
        self == .stop
    }
}

extension FinishReason: Codable {
    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A committed turn in a conversation. The in-flight assistant response is NOT a
/// `Message` — it lives in the app layer's `Draft` until it is committed.
public struct Message: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var parentID: UUID?
    public var role: MessageRole
    public var content: [ContentPart]
    public var timestamp: Date

    /// Reasoning text is kept for display but is never replayed to the model:
    /// most OpenAI-compatible backends reject or ignore `reasoning_content` in
    /// history, and it inflates token estimates.
    public var reasoning: String?
    public var model: String?
    public var finishReason: FinishReason?
    public var usage: Usage?
    /// True when the turn did not end with a clean `stop` (cancelled, dropped
    /// connection, background expiry, crash recovery).
    public var interrupted: Bool
    public var logID: String?
    /// Tool calls requested by an assistant turn (R2.3).
    public var toolCalls: [ToolCall]?
    /// The tool_call_id answered by a tool role turn.
    public var toolCallID: String?
    /// Search sources associated with this turn for citation rendering (R4.3).
    public var sources: [SearchResult]?

    public init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        role: MessageRole,
        content: [ContentPart],
        timestamp: Date = Date(),
        reasoning: String? = nil,
        model: String? = nil,
        finishReason: FinishReason? = nil,
        usage: Usage? = nil,
        interrupted: Bool = false,
        logID: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallID: String? = nil,
        sources: [SearchResult]? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.reasoning = reasoning
        self.model = model
        self.finishReason = finishReason
        self.usage = usage
        self.interrupted = interrupted
        self.logID = logID
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.sources = sources
    }

    public var text: String {
        content.map(\.textValue).joined()
    }

    public static func user(_ text: String, parentID: UUID? = nil) -> Message {
        Message(parentID: parentID, role: .user, content: [.text(text)])
    }

    public static func tool(_ text: String, toolCallID: String, parentID: UUID? = nil, sources: [SearchResult]? = nil) -> Message {
        Message(parentID: parentID, role: .tool, content: [.text(text)], toolCallID: toolCallID, sources: sources)
    }
}
