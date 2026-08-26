import Foundation
import Security

/// The Cloudflare API token, and nothing else, in the Keychain.
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is deliberate (R2.11): the
/// token never leaves the device and never rides an iCloud Keychain sync or an
/// encrypted backup, so a restore onto a new device requires re-entering it.
/// That is the intended trade for an account-wide credential.
///
/// A struct with no stored state, so it is trivially `Sendable` and safe to hand
/// to any isolation domain. The token is never logged, never interpolated into
/// an error, and never copied into a `NetworkTrace`.
struct KeychainSecretStore: SecretStore {
    static let service = "com.dhison.sate"
    static let account = "cloudflare-token"

    enum Failure: Error, Equatable {
        case keychain(OSStatus)
    }

    init() {}

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
    }

    func token() throws -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        // "Nothing stored yet" is the normal first-launch state, not a failure.
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    func setToken(_ token: String?) throws {
        guard let token, !token.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Failure.keychain(status)
            }
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        // Update first: `SecItemAdd` on an existing item fails with
        // `errSecDuplicateItem`, and deleting-then-adding would leave a window
        // where a rotation that fails halfway has removed the working token.
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure.keychain(updated) }

        var insert = query
        insert.merge(attributes) { _, new in new }
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }
}
