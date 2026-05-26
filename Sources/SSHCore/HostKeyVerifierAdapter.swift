import Foundation
import NIOCore
import NIOSSH

/// Bridges our async `HostKeyVerifier` protocol to NIOSSH's
/// callback-based `NIOSSHClientServerAuthenticationDelegate`. Citadel's
/// `SSHHostKeyValidator.custom(_:)` accepts one of these.
///
/// We capture `host`/`port` at construction time because NIOSSH only
/// hands us the public key — our protocol layer also wants the host
/// identity so it can look up `known_hosts` etc.
final class HostKeyVerifierAdapter: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: String
    let port: Int
    let verifier: HostKeyVerifier

    init(host: String, port: Int, verifier: HostKeyVerifier) {
        self.host = host
        self.port = port
        self.verifier = verifier
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        // Serialize the host key to its SSH wire format. Same bytes
        // that would be base64-encoded in a known_hosts entry — a
        // length-prefixed keytype string followed by length-prefixed
        // key data.
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        _ = hostKey.write(to: &buffer)
        let keyData = Data(buffer.readableBytesView)
        let keyType = Self.extractKeyType(from: keyData) ?? "unknown"

        let host = self.host
        let port = self.port
        let verifier = self.verifier

        Task {
            let accepted = await verifier.verify(
                host: host,
                port: port,
                keyType: keyType,
                keyData: keyData
            )
            if accepted {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHError.hostKeyRejected(host: host))
            }
        }
    }

    /// Read the SSH wire-format keytype prefix from the start of
    /// `data`: a 4-byte big-endian length followed by that many UTF-8
    /// bytes (e.g. `"ssh-ed25519"`).
    static func extractKeyType(from data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let len = (Int(data[data.startIndex])     << 24)
                | (Int(data[data.startIndex + 1]) << 16)
                | (Int(data[data.startIndex + 2]) <<  8)
                |  Int(data[data.startIndex + 3])
        guard len > 0, 4 + len <= data.count else { return nil }
        let typeBytes = data[(data.startIndex + 4)..<(data.startIndex + 4 + len)]
        return String(data: typeBytes, encoding: .utf8)
    }
}
