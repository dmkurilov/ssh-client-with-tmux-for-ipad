import Foundation
import Crypto

/// Output of in-app SSH key generation: the raw private seed (which
/// the App stores in Keychain) plus a copyable OpenSSH public key
/// string the user pastes into a remote `authorized_keys` file.
public struct GeneratedEd25519Key: Sendable {
    /// 32-byte Curve25519 seed. Pair with `Credentials.ed25519Raw`.
    public let rawPrivateKey: Data
    /// `ssh-ed25519 <base64> <comment>` — exactly what `ssh-keygen -y`
    /// would emit.
    public let openSSHPublicKey: String

    public init(rawPrivateKey: Data, openSSHPublicKey: String) {
        self.rawPrivateKey = rawPrivateKey
        self.openSSHPublicKey = openSSHPublicKey
    }
}

public enum SSHKeyGenerator {

    /// Generate a fresh Ed25519 keypair. The App calls this from the
    /// "Generate" path of its key form, hands the raw bytes to
    /// Keychain, and shows the OpenSSH public key for the user to
    /// copy into the server's `authorized_keys`.
    public static func generateEd25519(comment: String) -> GeneratedEd25519Key {
        let pk = Curve25519.Signing.PrivateKey()
        return GeneratedEd25519Key(
            rawPrivateKey: Data(pk.rawRepresentation),
            openSSHPublicKey: encodeOpenSSHPublicKey(pk.publicKey, comment: comment)
        )
    }

    /// Format an Ed25519 public key as `ssh-ed25519 <base64> <comment>`.
    /// The base64 payload is the SSH wire format: two length-prefixed
    /// strings (`"ssh-ed25519"` then the 32-byte public key).
    private static func encodeOpenSSHPublicKey(
        _ key: Curve25519.Signing.PublicKey,
        comment: String
    ) -> String {
        var blob = Data()
        appendLengthPrefixed(&blob, "ssh-ed25519".data(using: .utf8) ?? Data())
        appendLengthPrefixed(&blob, key.rawRepresentation)
        return "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
    }

    private static func appendLengthPrefixed(_ out: inout Data, _ payload: Data) {
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
    }
}
