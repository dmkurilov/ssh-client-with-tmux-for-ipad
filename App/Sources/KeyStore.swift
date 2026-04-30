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

    @discardableResult
    func add(_ key: KeyMetadata, data: Data) throws -> KeyMetadata {
        try KeychainKeyStore.shared.save(account: key.id.uuidString, data: data)
        keys.append(key)
        try persist()
        return key
    }

    func remove(_ id: UUID) throws {
        guard let idx = keys.firstIndex(where: { $0.id == id }) else { return }
        try KeychainKeyStore.shared.delete(account: id.uuidString)
        keys.remove(at: idx)
        try persist()
    }

    /// Rename an existing key. Identifier and Keychain entry are
    /// untouched — only the user-facing label changes.
    func rename(_ id: UUID, to newName: String) throws {
        guard let idx = keys.firstIndex(where: { $0.id == id }) else { return }
        keys[idx].name = newName
        try persist()
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

