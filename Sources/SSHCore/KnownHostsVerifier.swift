import Foundation
import Crypto
import SSHKnownHosts

/// `HostKeyVerifier` backed by a `known_hosts` file on disk and an
/// async `prompter` closure for unknown / mismatched entries. The
/// caller (the app) provides the prompter — typically a SwiftUI
/// sheet that asks the user to trust or reject.
///
/// On accept of an unknown host, a fresh plain entry is appended.
/// On accept of a mismatch, the conflicting entry (same host
/// pattern + keytype) is replaced.
/// On reject of either, `verify` returns `false` and the connection
/// fails up the stack with `SSHError.hostKeyRejected`.
public final class KnownHostsVerifier: HostKeyVerifier, @unchecked Sendable {
    public typealias Prompter = @Sendable (KnownHostsPrompt) async -> KnownHostsDecision

    public let knownHostsURL: URL
    public let prompter: Prompter

    public init(knownHostsURL: URL, prompter: @escaping Prompter) {
        self.knownHostsURL = knownHostsURL
        self.prompter = prompter
    }

    public func verify(
        host: String,
        port: Int,
        keyType: String,
        keyData: Data
    ) async -> Bool {
        let known = (try? KnownHosts.load(url: knownHostsURL)) ?? KnownHosts()

        switch known.match(host: host, port: port, keyType: keyType, keyData: keyData) {
        case .match:
            return true

        case .revoked:
            return false

        case .unknown:
            let prompt = KnownHostsPrompt.unknown(
                host: host,
                port: port,
                keyType: keyType,
                fingerprint: Self.fingerprint(keyData)
            )
            guard await prompter(prompt) == .accept else { return false }
            let updated = known.adding(
                host: host,
                port: port,
                keyType: keyType,
                keyData: keyData
            )
            try? updated.write(to: knownHostsURL)
            return true

        case .mismatch(let existing):
            let prompt = KnownHostsPrompt.mismatch(
                host: host,
                port: port,
                keyType: keyType,
                newFingerprint: Self.fingerprint(keyData),
                existingFingerprint: Self.fingerprint(existing.keyData)
            )
            guard await prompter(prompt) == .accept else { return false }
            // Drop any existing entry for this (host, port, keyType)
            // and append the new one.
            let surviving = known.entries.filter { entry in
                !(entry.matches(host: host, port: port) && entry.keyType == keyType)
            }
            let updated = KnownHosts(entries: surviving)
                .adding(host: host, port: port, keyType: keyType, keyData: keyData)
            try? updated.write(to: knownHostsURL)
            return true
        }
    }

    /// `SHA256:<base64-without-padding>` — the same form `ssh-keygen
    /// -lf` prints, so the fingerprint shown on the iPad matches what
    /// the user sees on a regular ssh login.
    public static func fingerprint(_ keyData: Data) -> String {
        let digest = SHA256.hash(data: keyData)
        let b64 = Data(digest).base64EncodedString()
        let trimmed = b64.replacingOccurrences(of: "=", with: "")
        return "SHA256:\(trimmed)"
    }
}
