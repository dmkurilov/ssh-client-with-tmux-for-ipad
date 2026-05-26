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

    func remove(_ id: UUID, inUseBy hostIDs: [UUID] = []) throws {
        // Block deletion of keys that any host still references. The
        // UI already gates the Remove button on this, but the guard
        // here is the source-of-truth check — anything calling
        // `remove` directly (tests, future code) gets the same
        // safety.
        guard hostIDs.isEmpty else {
            throw KeyStoreError.inUse(hostIDs: hostIDs)
        }
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
        guard let idx = keys.firstIndex(where: { $0.id == id }) else {
            throw KeyStoreError.notFound(id)
        }
        let data = try await KeychainKeyStore.shared.read(
            account: id.uuidString,
            prompt: prompt
        )
        // Touch lastUsedAt + backfill fingerprint and OpenSSH public
        // key text if absent (old entries imported before these
        // fields existed, or before `publicKeyOpenSSH` was cached).
        // All best-effort: if persist fails, the in-memory bump
        // still helps the current session and the next launch will
        // re-attempt the backfill.
        keys[idx].lastUsedAt = Date()
        if keys[idx].fingerprintSHA256 == nil,
           let fp = try? Self.computeFingerprint(format: keys[idx].format, data: data)
        {
            keys[idx].fingerprintSHA256 = fp
        }
        if keys[idx].publicKeyOpenSSH == nil,
           let pub = try? Self.computePublicKeyText(format: keys[idx].format, data: data)
        {
            keys[idx].publicKeyOpenSSH = pub
        }
        try? persist()
        return (keys[idx], data)
    }

    /// Import an SSH key from a file the user picked via Files. The
    /// caller supplies a (possibly user-edited) display name; the
    /// fingerprint is computed from the file bytes so it lines up
    /// with `ssh-keygen -lf`. Returns the stored metadata so the
    /// caller can surface "imported as <name>" / "fingerprint = X".
    @discardableResult
    func importFromFile(name: String, fileBytes: Data) throws -> KeyMetadata {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = trimmed.isEmpty ? "imported-key" : trimmed
        // For now only the OpenSSH PEM format is supported via Files
        // import — that's what `ssh-keygen` writes by default and
        // what people typically have in `~/.ssh/`. Reject anything
        // else with a clear error so we don't store unusable bytes.
        let text = String(decoding: fileBytes, as: UTF8.self)
        guard text.contains("-----BEGIN OPENSSH PRIVATE KEY-----") else {
            throw KeyStoreError.unsupportedFormat
        }
        let fp = try SSHKeyFingerprint.fromOpenSSHPEM(fileBytes)
        // Reject duplicates: same fingerprint already present means
        // the user already imported this key (possibly under a
        // different name). Surface so they don't get two entries
        // racing for `Used by:` columns.
        if keys.contains(where: { $0.fingerprintSHA256 == fp }) {
            throw KeyStoreError.alreadyImported(fingerprint: fp)
        }
        // Cache the OpenSSH public-key text (no comment — UI appends
        // the user-chosen name when copying). Lets "Copy public key"
        // work without a FaceID prompt to unlock the private bytes.
        let pubText = try? SSHKeyFingerprint.openSSHPublicKeyText(fromOpenSSHPEM: fileBytes)
        let meta = KeyMetadata(
            name: cleanName,
            format: .openSSHPEM,
            publicKeyOpenSSH: pubText,
            fingerprintSHA256: fp
        )
        return try add(meta, data: fileBytes)
    }

    /// Compute fingerprint for arbitrary key bytes + format. Used by
    /// the backfill path in `load` (older metadata didn't carry it)
    /// and by `importFromFile`.
    static func computeFingerprint(format: KeyFormat, data: Data) throws -> String {
        switch format {
        case .openSSHPEM:
            return try SSHKeyFingerprint.fromOpenSSHPEM(data)
        case .ed25519Raw:
            return try SSHKeyFingerprint.fromEd25519Seed(data)
        }
    }

    /// Compute OpenSSH-format public key text — `"<keytype>
    /// <base64>"` — for arbitrary key bytes + format. UI appends a
    /// comment (the user-chosen key name) before copying.
    static func computePublicKeyText(format: KeyFormat, data: Data) throws -> String {
        switch format {
        case .openSSHPEM:
            return try SSHKeyFingerprint.openSSHPublicKeyText(fromOpenSSHPEM: data)
        case .ed25519Raw:
            return try SSHKeyFingerprint.openSSHPublicKeyText(fromEd25519Seed: data)
        }
    }

    /// Convert a loaded (metadata, data) pair into the `Credentials`
    /// case that `SSHConnection` expects.
    static func credentials(for meta: KeyMetadata, data: Data) -> Credentials {
        switch meta.format {
        case .ed25519Raw: return .ed25519Raw(data)
        case .openSSHPEM: return .privateKey(data)
        }
    }

    // MARK: - Disk persistence

    enum KeyStoreError: LocalizedError, Equatable {
        case notFound(UUID)
        case inUse(hostIDs: [UUID])
        case unsupportedFormat
        case alreadyImported(fingerprint: String)

        var errorDescription: String? {
            switch self {
            case .notFound(let id):
                return "Key not found: \(id.uuidString)."
            case .inUse(let hosts):
                let count = hosts.count
                return "This key is used by \(count) host\(count == 1 ? "" : "s"). Remove the host(s) first, or point them at a different key."
            case .unsupportedFormat:
                return "Only OpenSSH private keys (-----BEGIN OPENSSH PRIVATE KEY-----) are supported."
            case .alreadyImported(let fp):
                return "A key with this fingerprint is already imported (\(fp))."
            }
        }
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

