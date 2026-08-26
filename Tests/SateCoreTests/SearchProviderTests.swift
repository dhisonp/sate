import Foundation
@testable import SateCore
import Testing

@Suite("SearchProvider")
struct SearchProviderTests {
    @Test("SearchResult model initializes and provides stable id")
    func searchResultModel() {
        let result = SearchResult(
            title: "Swift",
            url: "https://swift.org",
            snippet: "A powerful open language",
            publishedAt: Date(timeIntervalSince1970: 1700000000),
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
}
