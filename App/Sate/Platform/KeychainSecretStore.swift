import Foundation
import Security

/// Keychain-backed store for secrets (Cloudflare API token and Search API token).
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is deliberate (R2.11 / R1.3): the
/// tokens never leave the device and never ride an iCloud Keychain sync or an
/// encrypted backup, so a restore onto a new device requires re-entering them.
///
/// A struct with no stored state, so it is trivially `Sendable` and safe to hand
/// to any isolation domain. Tokens are never logged, never interpolated into
/// errors, and never copied into a `NetworkTrace`.
struct KeychainSecretStore: SecretStore {
    static let service = "com.dhison.sate"
    static let cloudflareAccount = "cloudflare-token"
    static let searchAccount = "google-token"

    enum Failure: Error, Equatable {
        case keychain(OSStatus)
    }

    init() {}

    func token() throws -> String? {
        try get(account: Self.cloudflareAccount)
    }

    func setToken(_ token: String?) throws {
        try set(token, account: Self.cloudflareAccount)
    }

    func searchToken() throws -> String? {
        try get(account: Self.searchAccount)
    }

    func setSearchToken(_ token: String?) throws {
        try set(token, account: Self.searchAccount)
    }

    // MARK: - Internals

    private func query(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    private func get(account: String) throws -> String? {
        var lookup = query(for: account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    private func set(_ token: String?, account: String) throws {
        let baseQuery = query(for: account)
        guard let token, !token.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Failure.keychain(status)
            }
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updated = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess {
            return
        }
        guard updated == errSecItemNotFound else { throw Failure.keychain(updated) }

        var insert = baseQuery
        insert.merge(attributes) { _, new in new }
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }
}
