import Foundation

/// Authentication uses a single API key stored in the Keychain.
/// Requests are sent as POST to `https://api.tavily.com/search` with an 8.0s timeout.
public final class TavilySearchProvider: SearchProvider, Sendable {
    public static let defaultEndpoint = URL(string: "https://api.tavily.com/search")!

    nonisolated(unsafe) private static let iso8601Formatter = ISO8601DateFormatter()
    nonisolated(unsafe) private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let apiKey: String
    private let session: URLSession
    private let endpoint: URL

    public init(
        apiKey: String,
        session: URLSession? = nil,
        endpoint: URL = TavilySearchProvider.defaultEndpoint
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8.0
            configuration.timeoutIntervalForResource = 8.0
            self.session = URLSession(configuration: configuration)
        }
        self.endpoint = endpoint
    }

    public func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        guard !apiKey.isEmpty else {
            throw SearchError.missingToken
        }

        let request = try makeRequest(query: query, limit: limit)
        let (data, response) = try await perform(request)
        return try handleResponse(data: data, response: response)
    }

    private func makeRequest(query: String, limit: Int) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let payload = TavilyRequest(
            apiKey: apiKey,
            query: query,
            searchDepth: "basic",
            includeAnswer: false,
            includeImages: false,
            maxResults: limit
        )

        do {
            request.httpBody = try JSONEncoder().encode(payload)
            return request
        } catch {
            throw SearchError.networkError("Failed to encode search request: \(error.localizedDescription)")
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError {
            if urlError.code == .timedOut {
                throw SearchError.timeout
            }
            if urlError.code == .cancelled {
                throw CancellationError()
            }
            throw SearchError.networkError(urlError.localizedDescription)
        } catch {
            throw SearchError.networkError(error.localizedDescription)
        }
    }

    private func handleResponse(data: Data, response: URLResponse) throws -> [SearchResult] {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearchError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200 ... 299:
            return try Self.decodeResults(from: data)
        case 401, 403:
            throw SearchError.unauthorized("Tavily API key is invalid or unauthorized.")
        case 429:
            throw SearchError.rateLimited("Tavily rate limit exceeded.")
        default:
            let message = Self.extractErrorMessage(from: data, statusCode: httpResponse.statusCode)
            throw SearchError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private static func decodeResults(from data: Data) throws -> [SearchResult] {
        let response: TavilyResponse
        do {
            response = try JSONDecoder().decode(TavilyResponse.self, from: data)
        } catch {
            throw SearchError.invalidResponse
        }

        guard let items = response.results else { return [] }
        return items.compactMap { item in
            guard let url = item.url, !url.isEmpty else { return nil }
            let title = (item.title?.isEmpty == false) ? (item.title ?? url) : url
            let snippet = String((item.content ?? "").prefix(2048))
            let publishedAt = item.publishedDate.flatMap { parseDate($0) }
            let siteName = extractSiteName(from: url)
            return SearchResult(
                title: title,
                url: url,
                snippet: snippet,
                publishedAt: publishedAt,
                siteName: siteName
            )
        }
    }

    private static func extractErrorMessage(from data: Data, statusCode: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = json["detail"] as? String {
                return detail
            }
            if let detailObj = json["detail"] as? [String: Any], let msg = detailObj["error"] as? String {
                return msg
            }
            if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                return msg
            }
            if let msg = json["message"] as? String {
                return msg
            }
        }
        return HTTPURLResponse.localizedString(forStatusCode: statusCode)
    }

    private static func parseDate(_ dateString: String) -> Date? {
        if let date = iso8601Formatter.date(from: dateString) {
            return date
        }
        return iso8601FractionalFormatter.date(from: dateString)
    }

    private static func extractSiteName(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host() ?? url.host,
              !host.isEmpty
        else {
            return nil
        }
        if host.lowercased().hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }
}

private struct TavilyRequest: Encodable {
    let apiKey: String
    let query: String
    let searchDepth: String
    let includeAnswer: Bool
    let includeImages: Bool
    let maxResults: Int

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case query
        case searchDepth = "search_depth"
        case includeAnswer = "include_answer"
        case includeImages = "include_images"
        case maxResults = "max_results"
    }
}

private struct TavilyResponse: Decodable {
    let results: [TavilyItem]?
}

private struct TavilyItem: Decodable {
    let title: String?
    let url: String?
    let content: String?
    let score: Double?
    let publishedDate: String?

    enum CodingKeys: String, CodingKey {
        case title
        case url
        case content
        case score
        case publishedDate = "published_date"
    }
}
