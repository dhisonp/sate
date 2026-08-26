import Foundation
@testable import SateCore
import Testing

@Suite("SecretStore")
struct SecretStoreTests {
    @Test("InMemorySecretStore starts empty by default")
    func startsEmpty() throws {
        let store = InMemorySecretStore()
        #expect(try store.token() == nil)
        #expect(try store.searchToken() == nil)
    }

    @Test("InMemorySecretStore initializes with provided tokens")
    func initializesWithTokens() throws {
        let store = InMemorySecretStore(token: "cf-token", searchToken: "google-token")
        #expect(try store.token() == "cf-token")
        #expect(try store.searchToken() == "google-token")
    }

    @Test("InMemorySecretStore sets, updates, and clears tokens")
    func tokenLifecycle() throws {
        let store = InMemorySecretStore()

        try store.setToken("token-1")
        #expect(try store.token() == "token-1")

        try store.setToken("token-2")
        #expect(try store.token() == "token-2")

        try store.setToken(nil)
        #expect(try store.token() == nil)
    }

    @Test("InMemorySecretStore sets, updates, and clears search tokens")
    func searchTokenLifecycle() throws {
        let store = InMemorySecretStore()

        try store.setSearchToken("search-1")
        #expect(try store.searchToken() == "search-1")

        try store.setSearchToken("search-2")
        #expect(try store.searchToken() == "search-2")

        try store.setSearchToken(nil)
        #expect(try store.searchToken() == nil)
    }

    @Test("Concurrent reads and writes to InMemorySecretStore are thread-safe")
    func concurrentAccess() async throws {
        let store = InMemorySecretStore()

        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 50 {
                group.addTask {
                    try? store.setToken("token-\(index)")
                    _ = try? store.token()
                    try? store.setSearchToken("search-\(index)")
                    _ = try? store.searchToken()
                }
            }
        }

        _ = try store.token()
        _ = try store.searchToken()
    }

    @Test("Failing SecretStore propagates thrown errors")
    func failingStoreThrows() {
        struct FailingStore: SecretStore {
            enum Error: Swift.Error {
                case failed
            }

            func token() throws -> String? {
                throw Error.failed
            }

            func setToken(_: String?) throws {
                throw Error.failed
            }

            func searchToken() throws -> String? {
                throw Error.failed
            }

            func setSearchToken(_: String?) throws {
                throw Error.failed
            }
        }

        let store = FailingStore()
        #expect(throws: FailingStore.Error.self) {
            try store.token()
        }
        #expect(throws: FailingStore.Error.self) {
            try store.setToken("token")
        }
        #expect(throws: FailingStore.Error.self) {
            try store.searchToken()
        }
        #expect(throws: FailingStore.Error.self) {
            try store.setSearchToken("search")
        }
    }
}
