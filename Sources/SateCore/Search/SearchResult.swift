import Foundation

public struct SearchResult: Codable, Hashable, Sendable, Identifiable {
    public var id: String {
        url
    }

    public var title: String
    public var url: String
    public var snippet: String
    public var publishedAt: Date?
    public var siteName: String?

    public init(
        title: String,
        url: String,
        snippet: String,
        publishedAt: Date? = nil,
        siteName: String? = nil
    ) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.publishedAt = publishedAt
        self.siteName = siteName
    }
}

public protocol SearchProvider: Sendable {
    func search(_ query: String, limit: Int) async throws -> [SearchResult]
}

public enum SearchProviderType: String, Codable, Sendable, CaseIterable {
    case tavily

    public var displayName: String {
        switch self {
        case .tavily: return "Tavily"
        }
    }
}

public enum SearchError: Error, Sendable, Hashable, LocalizedError {
    case missingToken
    case unauthorized(String)
    case rateLimited(String)
    case httpError(statusCode: Int, message: String)
    case timeout
    case networkError(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Search API key is not configured."
        case let .unauthorized(msg):
            return msg
        case let .rateLimited(msg):
            return msg
        case let .httpError(code, msg):
            return "Search error (HTTP \(code)): \(msg)"
        case .timeout:
            return "Search request timed out."
        case let .networkError(msg):
            return "Search network error: \(msg)"
        case .invalidResponse:
            return "Invalid search response."
        }
    }
}
