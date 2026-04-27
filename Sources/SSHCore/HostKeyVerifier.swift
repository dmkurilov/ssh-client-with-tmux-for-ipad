import Foundation

/// Asked during connection to decide whether the server's host key is
/// acceptable. The app implements this with a TOFU prompt + persistence
/// to a `known_hosts` store; SSHCore stays out of that policy.
public protocol HostKeyVerifier: Sendable {
    func verify(host: String, port: Int, keyType: String, keyData: Data) async -> Bool
}

/// What `KnownHostsVerifier` asks the user to decide when the
/// presented host key isn't a clean match.
public enum KnownHostsPrompt: Sendable, Equatable {
    /// First-time connection — no entry yet. Accept = TOFU.
    case unknown(
        host: String,
        port: Int,
        keyType: String,
        fingerprint: String
    )

    /// We already have an entry for this host with this keytype, but
    /// the bytes differ. Treat as a strong warning — possible MITM.
    case mismatch(
        host: String,
        port: Int,
        keyType: String,
        newFingerprint: String,
        existingFingerprint: String
    )
}

public enum KnownHostsDecision: Sendable, Equatable {
    case accept
    case reject
}

#if DEBUG
/// Trusts everything. Available **only in debug builds** so it can't
/// accidentally ship. For real connections use `KnownHostsVerifier`
/// with a UI-driven prompter, or another verifier with teeth.
public struct AcceptAllHostKeyVerifier: HostKeyVerifier {
    public init() {}

    public func verify(host: String, port: Int, keyType: String, keyData: Data) async -> Bool {
        true
    }
}
#endif
