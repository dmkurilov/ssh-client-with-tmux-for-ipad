import Foundation
import Security
import LocalAuthentication

/// Thin wrapper over the iOS Keychain for storing SSH private-key
/// material gated by FaceID/TouchID/passcode. Identifiers are opaque
/// strings (we use UUIDs from `KeyMetadata.id`); the Keychain doesn't
/// know or care about user-facing names.
///
/// We keep an in-memory cache of decrypted bytes with a sliding TTL
/// so the user isn't prompted on every connect within a session.
@MainActor
final class KeychainKeyStore {
    static let shared = KeychainKeyStore()

    private static let service = "dev.dmkurilov.ssh-client-with-tmux-for-ipad.keys"
    private static let cacheTTL: TimeInterval = 5 * 60   // 5 minutes idle

    private var cache: [String: (data: Data, expiry: Date)] = [:]

    enum Error: Swift.Error {
        case osStatus(OSStatus, op: String)
        case authFailed(String)
    }

    /// Save raw key bytes under `account`. Reading later requires
    /// biometric / passcode unlock. If an item with the same account
    /// already exists it's replaced.
    func save(account: String, data: Data) throws {
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            nil
        ) else {
            throw Error.osStatus(errSecAllocate, op: "SecAccessControlCreateWithFlags")
        }
        // Remove any existing item under this account first.
        SecItemDelete(deleteQuery(account: account) as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: access,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Error.osStatus(status, op: "SecItemAdd")
        }
        cache[account] = (data, Date().addingTimeInterval(Self.cacheTTL))
    }

    /// Read the bytes for `account`. Triggers FaceID unless cached.
    /// Renews the cache TTL on success.
    ///
    /// `LAContext.localizedReason` carries the prompt string;
    /// Keychain drives the biometric flow itself when it sees the
    /// item's `.userPresence` access control.
    func read(account: String, prompt: String) async throws -> Data {
        if let entry = cache[account], entry.expiry > Date() {
            cache[account] = (entry.data, Date().addingTimeInterval(Self.cacheTTL))
            return entry.data
        }
        let context = LAContext()
        context.localizedReason = prompt
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw Error.osStatus(status, op: "SecItemCopyMatching")
        }
        guard let data = result as? Data else {
            throw Error.authFailed("Keychain returned nil data")
        }
        cache[account] = (data, Date().addingTimeInterval(Self.cacheTTL))
        return data
    }

    func delete(account: String) throws {
        let status = SecItemDelete(deleteQuery(account: account) as CFDictionary)
        cache.removeValue(forKey: account)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error.osStatus(status, op: "SecItemDelete")
        }
    }

    /// Drop the in-memory cache without touching Keychain (e.g.
    /// when the app moves to background and we want to require a
    /// fresh prompt on resume).
    func evictCache() {
        cache.removeAll()
    }

    private func deleteQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }
}
