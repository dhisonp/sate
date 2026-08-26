import Foundation

/// API tokens live behind this, never in `SateSettings` and never
/// in any persisted or logged blob. The real implementation is Keychain-backed and
/// lives in the app target (Security.framework is not a concern of the core
/// package); this module ships only the contract and a test double.
public protocol SecretStore: Sendable {
    func token() throws -> String?
    func setToken(_ token: String?) throws

    func searchToken() throws -> String?
    func setSearchToken(_ token: String?) throws
}

/// Non-persisting store for tests, previews and simulator runs.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    // A lock rather than an actor because `SecretStore` is synchronous: the
    // Keychain implementation blocks too, and making the protocol async would
    // push `await` into every request-building path for a microsecond of work.
    private let lock = NSLock()
    private var storage: String?
    private var searchStorage: String?

    public init(token: String? = nil, searchToken: String? = nil) {
        storage = token
        searchStorage = searchToken
    }

    public func token() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func setToken(_ token: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        storage = token
    }

    public func searchToken() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return searchStorage
    }

    public func setSearchToken(_ token: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        searchStorage = token
    }
}
