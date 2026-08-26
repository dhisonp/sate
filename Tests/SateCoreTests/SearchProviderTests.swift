import Foundation
@testable import SateCore
import Testing

final class StubSearchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    func install(_ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func respond(to request: URLRequest) throws -> (HTTPURLResponse, Data)? {
        lock.lock()
        defer { lock.unlock() }
        return try handler?(request)
    }
}

final class StubSearchURLProtocol: URLProtocol {
    static let box = StubSearchBox()

    static func install(_ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        box.install(handler)
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let (response, data) = try Self.box.respond(to: request) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func bodyData() -> Data? {
        if let httpBody {
            return httpBody
        }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }
}

@Suite("SearchProvider", .serialized)
struct SearchProviderTests {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubSearchURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test("SearchResult model initializes and provides stable id")
    func searchResultModel() {
        let result = SearchResult(
            title: "Swift",
            url: "https://swift.org",
            snippet: "A powerful open language",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            siteName: "swift.org"
        )
        #expect(result.id == "https://swift.org")
        #expect(result.title == "Swift")
        #expect(result.snippet == "A powerful open language")
        #expect(result.siteName == "swift.org")
    }

    @Test("SearchProviderType displayName reflects provider name")
    func providerType() {
        #expect(SearchProviderType.tavily.displayName == "Tavily")
    }

    @Test("TavilySearchProvider parses normal results correctly")
    func normalResults() async throws {
        let session = makeSession()
        let json = #"""
        {
          "query": "swift",
          "results": [
            {
              "title": "Swift Programming Language",
              "url": "https://www.swift.org/about",
              "content": "Swift is a general-purpose programming language built using a modern approach.",
              "score": 0.99,
              "published_date": "2026-08-25T14:30:00Z"
            },
            {
              "title": "Apple Developer Documentation",
              "url": "https://developer.apple.com/swift",
              "content": "Comprehensive guides and API references for Apple platforms.",
              "score": 0.95,
              "published_date": "2026-08-20T08:00:00.000Z"
            }
          ],
          "response_time": 0.35
        }
        """#

        StubSearchURLProtocol.install { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://api.tavily.com/search")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("tvly-test-key") == true)

            if let bodyData = request.bodyData(),
               let bodyJson = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            {
                #expect(bodyJson["query"] as? String == "swift")
                #expect(bodyJson["api_key"] as? String == "tvly-test-key")
                #expect(bodyJson["max_results"] as? Int == 5)
            }

            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "application/json"]
                  )
            else {
                throw URLError(.badServerResponse)
            }
            return (response, Data(json.utf8))
        }

        let provider = TavilySearchProvider(apiKey: "tvly-test-key", session: session)
        let results = try await provider.search("swift", limit: 5)

        #expect(results.count == 2)
        #expect(results[0].title == "Swift Programming Language")
        #expect(results[0].url == "https://www.swift.org/about")
        #expect(results[0].snippet.contains("general-purpose"))
        #expect(results[0].siteName == "swift.org")
        #expect(results[0].publishedAt != nil)

        #expect(results[1].title == "Apple Developer Documentation")
        #expect(results[1].url == "https://developer.apple.com/swift")
        #expect(results[1].siteName == "developer.apple.com")
        #expect(results[1].publishedAt != nil)
    }

    @Test("TavilySearchProvider snippet is capped at 2048 characters")
    func snippetCapping() async throws {
        let session = makeSession()
        let longContent = String(repeating: "a", count: 3000)
        let json = #"""
        {
          "query": "long snippet",
          "results": [
            {
              "title": "Long Page",
              "url": "https://example.com/long",
              "content": "\#(longContent)"
            }
          ]
        }
        """#

        StubSearchURLProtocol.install { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "application/json"]
                  )
            else {
                throw URLError(.badServerResponse)
            }
            return (response, Data(json.utf8))
        }

        let provider = TavilySearchProvider(apiKey: "tvly-test-key", session: session)
        let results = try await provider.search("long snippet", limit: 5)

        #expect(results.count == 1)
        #expect(results[0].snippet.count == 2048)
    }

    @Test("Empty results return empty array without error")
    func emptyResults() async throws {
        let session = makeSession()
        StubSearchURLProtocol.install { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "application/json"]
                  )
            else {
                throw URLError(.badServerResponse)
            }
            return (response, Data(#"{"query":"none","results":[]}"#.utf8))
        }

        let provider = TavilySearchProvider(apiKey: "tvly-test-key", session: session)
        let results = try await provider.search("nonexistent query", limit: 5)
        #expect(results.isEmpty)
    }

    @Test("429 rate limit throws SearchError.rateLimited")
    func rateLimited() async throws {
        let session = makeSession()
        StubSearchURLProtocol.install { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 429,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "application/json"]
                  )
            else {
                throw URLError(.badServerResponse)
            }
            return (response, Data(#"{"detail":"Rate limit exceeded"}"#.utf8))
        }

        let provider = TavilySearchProvider(apiKey: "tvly-test-key", session: session)
        await #expect(throws: SearchError.self) {
            _ = try await provider.search("query", limit: 5)
        }
    }

    @Test("401 and 403 unauthorized throw SearchError.unauthorized")
    func unauthorized() async throws {
        let session = makeSession()
        StubSearchURLProtocol.install { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 401,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "application/json"]
                  )
            else {
                throw URLError(.badServerResponse)
            }
            return (response, Data(#"{"detail":"Unauthorized"}"#.utf8))
        }

        let provider = TavilySearchProvider(apiKey: "bad-token", session: session)
        await #expect(throws: SearchError.self) {
            _ = try await provider.search("query", limit: 5)
        }
    }

    @Test("Timeout maps to SearchError.timeout")
    func timeoutError() async throws {
        let session = makeSession()
        StubSearchURLProtocol.install { _ in
            throw URLError(.timedOut)
        }

        let provider = TavilySearchProvider(apiKey: "tvly-test-key", session: session)
        await #expect(throws: SearchError.timeout) {
            _ = try await provider.search("query", limit: 5)
        }
    }

    @Test("Missing token throws SearchError.missingToken immediately")
    func missingToken() async throws {
        let provider = TavilySearchProvider(apiKey: "")
        await #expect(throws: SearchError.missingToken) {
            _ = try await provider.search("query", limit: 5)
        }
    }

    @Test("Invalid response throws SearchError.invalidResponse")
    func invalidResponse() async throws {
        let session = makeSession()
        StubSearchURLProtocol.install { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "application/json"]
                  )
            else {
                throw URLError(.badServerResponse)
            }
            return (response, Data("not-json".utf8))
        }

        let provider = TavilySearchProvider(apiKey: "tvly-test-key", session: session)
        await #expect(throws: SearchError.invalidResponse) {
            _ = try await provider.search("query", limit: 5)
        }
    }
}
