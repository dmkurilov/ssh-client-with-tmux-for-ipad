import Foundation

/// User-facing description of a stored SSH key. The actual private
/// material lives in Keychain under `id.uuidString`; metadata is
/// kept in plaintext JSON in the app's Documents folder so we can
/// list keys without unlocking them.
struct KeyMetadata: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var format: KeyFormat
    /// Optional OpenSSH-format public key text (`ssh-ed25519 AAAA…`),
    /// stored so the user can copy it into `authorized_keys`. Always
    /// available for in-app generated keys; optional for pasted ones.
    var publicKeyOpenSSH: String?
    let createdAt: Date
    /// Most recent successful `KeyStore.load` for this key, used by
    /// the Keys list to show "Last used …". Nil = never used since
    /// import. Bumped + persisted on every load.
    var lastUsedAt: Date?
    /// `ssh-keygen -lf`-style SHA256 fingerprint:
    /// `SHA256:<base64-no-padding>`. Computed once at import/generate
    /// from the embedded OpenSSH public key bytes, so the value is
    /// what the user would see in their terminal (and in a server's
    /// `authorized_keys` log). Nil only for keys imported on older
    /// builds — those backfill on first load.
    var fingerprintSHA256: String?

    init(
        id: UUID = UUID(),
        name: String,
        format: KeyFormat,
        publicKeyOpenSSH: String? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        fingerprintSHA256: String? = nil
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.fingerprintSHA256 = fingerprintSHA256
    }
}

/// How the bytes in Keychain are encoded. Affects which
/// `Credentials` case we hand to `SSHConnection.connect`.
enum KeyFormat: String, Codable, Hashable {
    /// 32-byte raw Curve25519 seed. Used for keys generated in-app.
    case ed25519Raw
    /// OpenSSH PEM text bytes. Used for pasted keys and the
    /// migrated smoke-test key.
    case openSSHPEM
}
