import Foundation
import Crypto

/// `ssh-keygen -lf`-style SHA256 fingerprint helpers. Given the
/// bytes of an OpenSSH PEM private key or a raw Ed25519 seed,
/// produces a string of the form `SHA256:<base64-no-padding>` — the
/// exact format `ssh-keygen -lf` prints and OpenSSH servers log in
/// `auth.log` when accepting public-key auth. Storing this lets the
/// app's Keys list show a value the user can cross-check against
/// their terminal.
public enum SSHKeyFingerprint {
    /// OpenSSH PEM private key text → fingerprint of the embedded
    /// public-key blob. The PEM wraps the OpenSSH key-v1 wire
    /// format; the public key sits as a length-prefixed string
    /// right after `openssh-key-v1\0` + ciphername/kdfname/kdfopts +
    /// numkeys, and that *whole* blob (with its `ssh-<type>` header
    /// and key material) is what `ssh-keygen` hashes.
    public static func fromOpenSSHPEM(_ pemBytes: Data) throws -> String {
        let text = String(decoding: pemBytes, as: UTF8.self)
        let blob = try extractPublicKeyBlob(fromPEM: text)
        return format(sha256Of: blob)
    }

    /// 32-byte Ed25519 seed → fingerprint of the derived public key,
    /// wrapped in SSH wire format (`string("ssh-ed25519") +
    /// string(pubkey)`).
    public static func fromEd25519Seed(_ seed: Data) throws -> String {
        let blob = try ed25519PublicKeyBlob(fromSeed: seed)
        return format(sha256Of: blob)
    }

    /// OpenSSH-format public-key text — `"<keytype> <base64>"` —
    /// extracted from an OpenSSH PEM private key. Pair with a
    /// user-chosen comment when displaying ("`<keytype> <base64>
    /// <comment>`"). Suitable for pasting into a server's
    /// `authorized_keys`.
    public static func openSSHPublicKeyText(fromOpenSSHPEM pemBytes: Data) throws -> String {
        let text = String(decoding: pemBytes, as: UTF8.self)
        let blob = try extractPublicKeyBlob(fromPEM: text)
        let keytype = try readKeyType(fromBlob: blob)
        return "\(keytype) \(blob.base64EncodedString())"
    }

    /// Same, but for in-app generated Ed25519 keys (32-byte seed).
    public static func openSSHPublicKeyText(fromEd25519Seed seed: Data) throws -> String {
        let blob = try ed25519PublicKeyBlob(fromSeed: seed)
        return "ssh-ed25519 \(blob.base64EncodedString())"
    }

    // MARK: - Internals

    private static func ed25519PublicKeyBlob(fromSeed seed: Data) throws -> Data {
        guard seed.count == 32 else { throw FingerprintError.invalidSeed }
        let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let pub = Data(priv.publicKey.rawRepresentation)
        var blob = Data()
        appendString(&blob, Data("ssh-ed25519".utf8))
        appendString(&blob, pub)
        return blob
    }

    private static func readKeyType(fromBlob blob: Data) throws -> String {
        var reader = WireReader(data: blob, offset: 0)
        let typeBytes = try reader.readString()
        guard let s = String(data: typeBytes, encoding: .utf8) else {
            throw FingerprintError.invalidMagic
        }
        return s
    }

    private static func format(sha256Of bytes: Data) -> String {
        let hash = SHA256.hash(data: bytes)
        // OpenSSH strips trailing `=` padding from the base64 output.
        let b64 = Data(hash).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "SHA256:\(b64)"
    }

    private static func appendString(_ buf: inout Data, _ data: Data) {
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { buf.append(contentsOf: $0) }
        buf.append(data)
    }

    private static func extractPublicKeyBlob(fromPEM text: String) throws -> Data {
        guard let begin = text.range(of: "-----BEGIN OPENSSH PRIVATE KEY-----"),
              let end = text.range(of: "-----END OPENSSH PRIVATE KEY-----"),
              begin.upperBound <= end.lowerBound
        else {
            throw FingerprintError.notOpenSSHPEM
        }
        let body = text[begin.upperBound..<end.lowerBound]
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let data = Data(base64Encoded: body) else {
            throw FingerprintError.invalidBase64
        }
        return try parseV1PublicKeyBlob(data)
    }

    private static func parseV1PublicKeyBlob(_ data: Data) throws -> Data {
        // Magic: "openssh-key-v1" + NUL.
        let magic = Data("openssh-key-v1\0".utf8)
        guard data.count >= magic.count,
              data.prefix(magic.count) == magic
        else {
            throw FingerprintError.invalidMagic
        }
        var reader = WireReader(data: data, offset: magic.count)
        _ = try reader.readString()      // ciphername
        _ = try reader.readString()      // kdfname
        _ = try reader.readString()      // kdfoptions
        let numKeys = try reader.readUInt32()
        guard numKeys >= 1 else { throw FingerprintError.noPublicKey }
        return try reader.readString()   // public key blob — what we hash
    }

    private struct WireReader {
        let data: Data
        var offset: Int

        mutating func readUInt32() throws -> UInt32 {
            guard offset + 4 <= data.count else {
                throw FingerprintError.unexpectedEnd
            }
            // Decode big-endian byte-by-byte. Simpler than going
            // through `withUnsafeMutableBytes` + `Data.copyBytes`
            // (which returns the byte count and trips the unused-
            // result diagnostic) and dodges any alignment concern
            // on the underlying buffer. `data.startIndex` is added
            // so this works if the caller hands us a slice — `Data`
            // indices aren't always zero-based.
            let base = data.startIndex
            let b0 = UInt32(data[base + offset])
            let b1 = UInt32(data[base + offset + 1])
            let b2 = UInt32(data[base + offset + 2])
            let b3 = UInt32(data[base + offset + 3])
            offset += 4
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }

        mutating func readString() throws -> Data {
            let len = Int(try readUInt32())
            guard offset + len <= data.count else {
                throw FingerprintError.unexpectedEnd
            }
            let base = data.startIndex
            let slice = data[(base + offset)..<(base + offset + len)]
            offset += len
            return Data(slice)
        }
    }

    public enum FingerprintError: Error, LocalizedError, Equatable {
        case notOpenSSHPEM
        case invalidBase64
        case invalidMagic
        case unexpectedEnd
        case noPublicKey
        case invalidSeed

        public var errorDescription: String? {
            switch self {
            case .notOpenSSHPEM:
                return "Not an OpenSSH private key (missing BEGIN/END markers)."
            case .invalidBase64:
                return "OpenSSH key body is not valid base64."
            case .invalidMagic:
                return "OpenSSH key is missing the 'openssh-key-v1' magic header."
            case .unexpectedEnd:
                return "OpenSSH key payload ended unexpectedly during parse."
            case .noPublicKey:
                return "OpenSSH key has no public-key section."
            case .invalidSeed:
                return "Ed25519 seed must be exactly 32 bytes."
            }
        }
    }
}
