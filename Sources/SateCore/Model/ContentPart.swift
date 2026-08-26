import Foundation

/// Message content is an array of parts even though v1 is text-only, so images
/// and files slot in later without a persistence migration.
public enum ContentPart: Codable, Hashable, Sendable {
    case text(String)

    private enum CodingKeys: String, CodingKey {
        case type, text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? "text"
        switch type {
        case "text":
            self = try .text(container.decodeIfPresent(String.self, forKey: .text) ?? "")
        default:
            // Forward compatibility: an unknown part degrades to empty text rather
            // than failing the whole conversation load.
            self = .text("")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        }
    }

    public var textValue: String {
        switch self {
        case let .text(value): return value
        }
    }
}
