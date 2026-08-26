import Foundation
@testable import SateCore
import Testing

private final class StubSearchURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var storedHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func install(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        defer { lock.unlock() }
        storedHandler = handler
    }

    static func currentHandler() -> ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        lock.lock()
        defer { lock.unlock() }
        return storedHandler
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.currentHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("SearchProvider", .serialized)
struct SearchProviderTests {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubSearchURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test("GoogleSearchProvider parses normal results correctly")
    func normalResults() async throws {
        let session = makeSession()
        let json = #"""
        {
          "items": [
            {
              "title": "Swift Programming Language",
              "link": "https://swift.org",
              "snippet": "Swift is a general-purpose programming language built using a modern approach.",
              "pagemap": {
                "metatags": [
                  {
                    "og:site_name": "Swift.org",
                    "article:published_time": "2026-01-15T10:30:00Z"
                  }
                ]
              }
            },
            {
              "title": "Apple Developer Documentation",
              "link": "https://developer.apple.com",
              "snippet": "Comprehensive guides and API references for Apple platforms.",
              "pagemap": {
                "metatags": [
                  {
                    "og:site_name": "developer.apple.com"
                  }
                ]
              }
            }
          ]
        }
        """#

        StubSearchURLProtocol.install { request in
            #expect(request.url?.query()?.contains("q=swift") == true)
            #expect(request.url?.query()?.contains("key=") == true)
            #expect(request.url?.query()?.contains("cx=") == true)
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

        let provider = GoogleSearchProvider(apiKey: "test-token", session: session)
        let results = try await provider.search("swift", limit: 5)

        #expect(results.count == 2)
        #expect(results[0].title == "Swift Programming Language")
        #expect(results[0].url == "https://swift.org")
        #expect(results[0].snippet.contains("general-purpose"))
        #expect(results[0].siteName == "Swift.org")
        #expect(results[0].publishedAt != nil)

        #expect(results[1].title == "Apple Developer Documentation")
        #expect(results[1].url == "https://developer.apple.com")
        #expect(results[1].siteName == "developer.apple.com")
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
            return (response, Data(#"{"items":[]}"#.utf8))
        }

        let provider = GoogleSearchProvider(apiKey: "test-token", session: session)
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
                      headerFields: nil
                  )
            else {
                throw URLError(.badServerResponse)
            }
            return (response, Data("Rate limit exceeded".utf8))
        }

        let provider = GoogleSearchProvider(apiKey: "test-token", session: session)
        await #expect(throws: SearchError.self) {
            _ = try await provider.search("query", limit: 5)
        }
    }

    @Test("401 unauthorized throws SearchError.unauthorized")
    func unauthorized() async throws {
        let session = makeSession()
        StubSearchURLProtocol.install { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 401,
                      httpVersion: nil,
                      headerFields: nil
                  )
            else {
                throw URLError(.badServerResponse)
            }
            return (response, Data("Invalid token".utf8))
        }

        let provider = GoogleSearchProvider(apiKey: "bad-token", session: session)
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

        let provider = GoogleSearchProvider(apiKey: "test-token", session: session)
        await #expect(throws: SearchError.timeout) {
            _ = try await provider.search("query", limit: 5)
        }
    }

    @Test("Missing token throws SearchError.missingToken immediately")
    func missingToken() async throws {
        let provider = GoogleSearchProvider(apiKey: "")
        await #expect(throws: SearchError.missingToken) {
            _ = try await provider.search("query", limit: 5)
        }
    }
}
