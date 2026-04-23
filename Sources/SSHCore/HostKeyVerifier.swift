import Foundation

/// Asked during connection to decide whether the server's host key is
/// acceptable. The app implements this with a TOFU prompt + persistence
/// to a `known_hosts` store; SSHCore stays out of that policy.
public protocol HostKeyVerifier: Sendable {
    func verify(host: String, port: Int, keyType: String, keyData: Data) async -> Bool
}

/// Trusts everything. Use **only** for development against your own
/// server — bypasses the entire MITM defense. Replace with a real
/// TOFU verifier before any production use.
public struct AcceptAllHostKeyVerifier: HostKeyVerifier {
    public init() {}

    public func verify(host: String, port: Int, keyType: String, keyData: Data) async -> Bool {
        true
    }
}
