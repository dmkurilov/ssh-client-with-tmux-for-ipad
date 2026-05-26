import Foundation
import Crypto

/// A single host pattern in a known_hosts entry.
///
/// `plain` covers both `"example.com"` and `"[example.com]:2222"`.
/// `hashed` is OpenSSH's `|1|salt|hash` form (HMAC-SHA1 of the
/// hostname with `salt` as key).
public enum HostPattern: Sendable, Equatable {
    /// `host` is the bare hostname; `port` is `nil` for entries that
    /// match any port (the `host` form), or the explicit port for
    /// `[host]:port` entries.
    case plain(host: String, port: Int?)

    /// `salt` and `hash` are the raw bytes (base64 already decoded).
    /// A candidate hostname matches when
    /// `HMAC-SHA1(salt, hostname) == hash`.
    case hashed(salt: Data, hash: Data)

    public func matches(host: String, port: Int) -> Bool {
        switch self {
        case .plain(let h, let p):
            guard h == host else { return false }
            if let p, p != port { return false }
            return true

        case .hashed(let salt, let hash):
            let key = SymmetricKey(data: salt)
            let mac = HMAC<Insecure.SHA1>.authenticationCode(
                for: Data(host.utf8),
                using: key
            )
            return Data(mac) == hash
        }
    }

    /// Generate a hashed pattern for `host` with a fresh random salt.
    /// The result is suitable for storing in a known_hosts file's
    /// hashed form. Uses Swift's cross-platform RNG so this works on
    /// Linux for tests too.
    public static func hashed(host: String, saltLength: Int = 20) -> HostPattern {
        let salt = Data((0..<saltLength).map { _ in UInt8.random(in: 0...255) })
        let key = SymmetricKey(data: salt)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(host.utf8),
            using: key
        )
        return .hashed(salt: salt, hash: Data(mac))
    }
}
