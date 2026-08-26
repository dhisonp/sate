import Foundation

/// One line of a conversation's JSONL file.
///
/// The schema is additive-only and `unknown` is a real case: a file written by a
/// newer build must load in an older one with the unrecognised lines skipped,
/// never fatally.
public enum SessionEntry: Sendable {
    /// Always the first line: schema version and conversation metadata.
    case header(ConversationHeader)
    /// A committed turn.
    case message(Message)
    /// Moves the "current branch" pointer. Last one wins on load.
    case leaf(id: UUID, timestamp: Date)
    /// Renames or re-models the conversation after creation.
    case update(title: String?, model: String?, timestamp: Date)
    /// A line this build does not understand — a `type` from a newer schema.
    ///
    /// The body is NOT captured (`raw` decodes as ""): the transcript is
    /// append-only and no code path ever rewrites an existing line, so an
    /// unknown entry is simply skipped on load and left untouched on disk. That
    /// is what preserves it for the build that does understand it.
    case unknown(type: String, raw: String)
}

public struct ConversationHeader: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var conversationID: UUID
    public var title: String
    public var createdAt: Date
    public var model: String

    public init(
        version: Int = ConversationHeader.currentVersion,
        conversationID: UUID = UUID(),
        title: String = "New Conversation",
        createdAt: Date = Date(),
        model: String
    ) {
        self.version = version
        self.conversationID = conversationID
        self.title = title
        self.createdAt = createdAt
        self.model = model
    }
}

extension SessionEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, header, message, id, timestamp, title, model
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        switch type {
        case "header":
            self = .header(try container.decode(ConversationHeader.self, forKey: .header))
        case "message":
            self = .message(try container.decode(Message.self, forKey: .message))
        case "leaf":
            self = .leaf(
                id: try container.decode(UUID.self, forKey: .id),
                timestamp: try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date())
        case "update":
            self = .update(
                title: try container.decodeIfPresent(String.self, forKey: .title),
                model: try container.decodeIfPresent(String.self, forKey: .model),
                timestamp: try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date())
        default:
            self = .unknown(type: type, raw: "")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .header(let header):
            try container.encode("header", forKey: .type)
            try container.encode(header, forKey: .header)
        case .message(let message):
            try container.encode("message", forKey: .type)
            try container.encode(message, forKey: .message)
        case .leaf(let id, let timestamp):
            try container.encode("leaf", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(timestamp, forKey: .timestamp)
        case .update(let title, let model, let timestamp):
            try container.encode("update", forKey: .type)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(model, forKey: .model)
            try container.encode(timestamp, forKey: .timestamp)
        case .unknown(let type, _):
            try container.encode(type, forKey: .type)
        }
    }
}
