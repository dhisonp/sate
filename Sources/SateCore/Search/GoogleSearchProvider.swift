import Foundation

/// Google Custom Search API provider (`www.googleapis.com/customsearch/v1`).
///
/// Uses `key` and `cx` (Search Engine ID) as query parameters.
/// Note: The `searchToken` from the `SecretStore` is used as the Google API Key.
/// A hardcoded `cx` is used for now, but in a real scenario, this should be configurable.
public struct GoogleSearchProvider: SearchProvider, Sendable {
    public static let endpoint = URL(string: "https://www.googleapis.com/customsearch/v1")!
    public static let defaultTimeout: TimeInterval = 8.0
    public static let maxSnippetCharacters = 2048

    /// The Search Engine ID (cx).
    /// In a real production app, this would be a setting.
    public static let searchEngineId = "012345678901234567890" // Placeholder

    private let apiKey: String
    private let cx: String
    private let session: URLSession

    public init(apiKey: String, cx: String = Self.searchEngineId, session: URLSession? = nil) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cx = cx
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.defaultTimeout
            configuration.timeoutIntervalForResource = Self.defaultTimeout
            self.session = URLSession(configuration: configuration)
        }
    }

    public func search(_ query: String, limit: Int = 5) async throws -> [SearchResult] {
        guard !apiKey.isEmpty else {
            throw SearchError.missingToken
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        let clampedLimit = min(max(limit, 1), 10)
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmedQuery),
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "cx", value: cx),
            URLQueryItem(name: "num", value: String(clampedLimit)),
        ]

        guard let requestURL = components?.url else {
            throw SearchError.invalidResponse
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw SearchError.timeout
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SearchError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearchError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return try parseResults(data: data)
        case 400:
            throw SearchError.invalidResponse
        case 401, 403:
            throw SearchError.unauthorized("Google Search API key is invalid or unauthorized.")
        case 429:
            throw SearchError.rateLimited("Google Search rate limit exceeded.")
        default:
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw SearchError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private func parseResults(data: Data) throws -> [SearchResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchError.invalidResponse
        }

        guard let items = root["items"] as? [[String: Any]] else {
            return []
        }

        return items.compactMap { dict -> SearchResult? in
            guard let title = dict["title"] as? String,
                  let urlString = dict["link"] as? String,
                  !urlString.isEmpty
            else {
                return nil
            }

            let snippet = (dict["snippet"] as? String) ?? ""
            var finalSnippet = snippet
            if finalSnippet.count > Self.maxSnippetCharacters {
                finalSnippet = String(finalSnippet.prefix(Self.maxSnippetCharacters)) + "…"
            }

            let publishedAt = parseDate(from: dict["pagemap"] as? [String: Any])
            let siteName = parseSiteName(dict: dict)

            return SearchResult(
                title: title,
                url: urlString,
                snippet: finalSnippet,
                publishedAt: publishedAt,
                siteName: siteName
            )
        }
    }

    private func parseDate(from pagemap: [String: Any]?) -> Date? {
        guard let pagemap = pagemap else { return nil }

        // Google Custom Search results often put dates in various places within 'pagemap'
        // e.g., metatags -> article:published_time
        let metatags = pagemap["metatags"] as? [[String: Any]]
        let dateString = metatags?.first?["article:published_time"] as? String
            ?? metatags?.first?["date"] as? String
            ?? metatags?.first?["published_time"] as? String

        guard let dateStr = dateString, !dateStr.isEmpty else { return nil }

        // Try several formats
        let formats = [
            ISO8601DateFormatter(),
            {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withFullDate]
                return f
            }(),
            {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return f
            }(),
        ]

        for formatter in formats {
            if let date = formatter.date(from: dateStr) {
                return date
            }
        }
        return nil
    }

    private func parseSiteName(dict: [String: Any]) -> String? {
        let pagemap = dict["pagemap"] as? [String: Any]

        if let cseImage = pagemap?["cse_image"] as? [[String: Any]],
           let firstImage = cseImage.first,
           let urlString = firstImage["url"] as? String
        {
            return urlString.replacingOccurrences(of: "www.", with: "")
        }

        let metatags = pagemap?["metatags"] as? [[String: Any]]
        if let siteName = metatags?.first?["og:site_name"] as? String {
            return siteName
        }

        if let urlString = dict["link"] as? String, let url = URL(string: urlString), let host = url.host() {
            return host.replacingOccurrences(of: "www.", with: "")
        }

        return nil
    }
}
