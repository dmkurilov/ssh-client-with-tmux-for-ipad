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

    init(
        id: UUID = UUID(),
        name: String,
        format: KeyFormat,
        publicKeyOpenSSH: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.createdAt = createdAt
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
