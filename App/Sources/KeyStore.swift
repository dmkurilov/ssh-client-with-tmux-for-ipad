import Foundation
import Observation
import SSHCore

/// Observable store of SSH key metadata. Persists the metadata list
/// as JSON in the app's Documents folder; private-key material lives
/// in Keychain via `KeychainKeyStore`.
///
/// On first launch with a bundled smoke-test private key (legacy
/// dev workflow), the file is auto-imported into Keychain and
/// surfaced as a key named "smoke-test" so the existing host can
/// keep connecting without manual setup.
@MainActor
@Observable
final class KeyStore {
    private(set) var keys: [KeyMetadata]

    init() {
        self.keys = (try? Self.load()) ?? []
        importSmokeTestIfNeeded()
    }

    // MARK: - Mutation

    /// Resolve a host's preferred key id to one that actually
    /// exists. If `preferred` points to a key that's been deleted
    /// (or is `nil`), fall back to the first available key. Returns
    /// `nil` only when the store is empty.
    ///
    /// The host-detail UI already does this fallback when displaying
    /// the "Key" row — without the same logic in `loadCredentials`,
    /// the chrome shows a working default while every connection
    /// attempt fails with "key not found in keychain".
    func resolveKeyID(preferred: UUID?) -> UUID? {
        if let id = preferred, keys.contains(where: { $0.id == id }) {
            return id
        }
        return keys.first?.id
    }

    @discardableResult
    func add(_ key: KeyMetadata, data: Data) throws -> KeyMetadata {
        // Save private bytes to Keychain first — we'll roll this back
        // if metadata persistence fails so we don't leak an orphaned
        // Keychain entry that no metadata record points to.
        try KeychainKeyStore.shared.save(account: key.id.uuidString, data: data)
        keys.append(key)
        do {
            try persist()
        } catch {
            // Roll back both the in-memory append and the Keychain
            // entry we just wrote. Best-effort on the Keychain
            // delete — if it fails we still propagate the original
            // persist error to the caller, just with a tiny orphan
            // entry left behind in the worst case.
            keys.removeAll(where: { $0.id == key.id })
            try? KeychainKeyStore.shared.delete(account: key.id.uuidString)
            throw error
        }
        return key
    }

    func remove(_ id: UUID) throws {
        guard let idx = keys.firstIndex(where: { $0.id == id }) else { return }
        // Persist metadata removal *before* touching the Keychain.
        // Reversing the original order (Keychain → persist) prevents
        // the worst case where the Keychain entry is gone but
        // metadata still references it — `load()` would then throw
        // forever. With the new order, a persist failure leaves
        // everything intact; a post-persist Keychain-delete failure
        // leaves an orphan in the Keychain (harmless, the metadata
        // says the key is gone).
        let removed = keys.remove(at: idx)
        do {
            try persist()
        } catch {
            keys.insert(removed, at: idx)
            throw error
        }
        try KeychainKeyStore.shared.delete(account: id.uuidString)
    }

    /// Rename an existing key. Identifier and Keychain entry are
    /// untouched — only the user-facing label changes.
    func rename(_ id: UUID, to newName: String) throws {
        guard let idx = keys.firstIndex(where: { $0.id == id }) else { return }
        let oldName = keys[idx].name
        keys[idx].name = newName
        do {
            try persist()
        } catch {
            keys[idx].name = oldName
            throw error
        }
    }

    // MARK: - Reading

    /// Fetch the private key bytes for `id`. Triggers FaceID unless
    /// the cache is warm. Returns the metadata + bytes so the caller
    /// can choose the right `Credentials` case based on `format`.
    func load(_ id: UUID, prompt: String) async throws -> (KeyMetadata, Data) {
        guard let meta = keys.first(where: { $0.id == id }) else {
            throw KeyStoreError.notFound(id)
        }
        let data = try await KeychainKeyStore.shared.read(
            account: id.uuidString,
            prompt: prompt
        )
        return (meta, data)
    }

    /// Convert a loaded (metadata, data) pair into the `Credentials`
    /// case that `SSHConnection` expects.
    static func credentials(for meta: KeyMetadata, data: Data) -> Credentials {
        switch meta.format {
        case .ed25519Raw: return .ed25519Raw(data)
        case .openSSHPEM: return .privateKey(data)
        }
    }

    // MARK: - Smoke-test migration

    /// On first launch, if the bundle ships a smoke-test private key
    /// and the keystore is empty, import that key so existing hosts
    /// don't need any manual setup. The bundled file remains as a
    /// dev-time override — we only re-import when keystore is empty.
    private func importSmokeTestIfNeeded() {
        guard keys.isEmpty,
              let pem = SmokeTestConfig.privateKeyData
        else { return }
        let meta = KeyMetadata(
            name: "smoke-test",
            format: .openSSHPEM,
            publicKeyOpenSSH: nil
        )
        do {
            try KeychainKeyStore.shared.save(
                account: meta.id.uuidString,
                data: pem
            )
            keys.append(meta)
            try persist()
        } catch {
            // Non-fatal — user can paste/generate manually.
        }
    }

    // MARK: - Disk persistence

    enum KeyStoreError: Error {
        case notFound(UUID)
    }

    private static var fileURL: URL {
        let docs = try! FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return docs.appendingPathComponent("keys.json")
    }

    private static func load() throws -> [KeyMetadata] {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([KeyMetadata].self, from: data)
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(keys)
        try data.write(to: Self.fileURL, options: .atomic)
    }
}

