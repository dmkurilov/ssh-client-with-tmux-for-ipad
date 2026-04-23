import Foundation
import Citadel
import Crypto
import NIOCore

/// One SSH connection to a remote host. Constructed via the static
/// `connect(...)` factory; call `exec(_:)` for one-shot commands and
/// `disconnect()` when done.
///
/// **v1 caveats**:
/// - The `hostKeyVerifier` parameter is accepted for API stability but
///   not yet wired through to Citadel's host-key check — every key is
///   currently accepted. Will be wired in step C, when we add the
///   `SSHKnownHosts` module and the TOFU prompt.
public actor SSHConnection {
    public let endpoint: SSHEndpoint
    private var client: SSHClient?

    public static func connect(
        endpoint: SSHEndpoint,
        credentials: Credentials,
        hostKeyVerifier: HostKeyVerifier = AcceptAllHostKeyVerifier()
    ) async throws -> SSHConnection {
        let connection = SSHConnection(endpoint: endpoint)
        try await connection.openClient(
            credentials: credentials,
            hostKeyVerifier: hostKeyVerifier
        )
        return connection
    }

    private init(endpoint: SSHEndpoint) {
        self.endpoint = endpoint
    }

    private func openClient(
        credentials: Credentials,
        hostKeyVerifier: HostKeyVerifier
    ) async throws {
        let auth: SSHAuthenticationMethod
        switch credentials {
        case .password(let pwd):
            auth = .passwordBased(username: endpoint.user, password: pwd)
        case .privateKey(let keyData):
            let pem = String(decoding: keyData, as: UTF8.self)
            do {
                let pk = try Curve25519.Signing.PrivateKey(sshEd25519: pem)
                auth = .ed25519(username: endpoint.user, privateKey: pk)
            } catch {
                throw SSHError.unsupportedKeyFormat(
                    reason: "OpenSSH ed25519 parse failed: \(error). v1 supports OpenSSH ed25519 keys only."
                )
            }
        }

        // TODO step C: replace `.acceptAnything()` with an adapter that
        // calls into the supplied `hostKeyVerifier` and persists the
        // decision to a `known_hosts` store.
        _ = hostKeyVerifier

        do {
            self.client = try await SSHClient.connect(
                host: endpoint.host,
                port: endpoint.port,
                authenticationMethod: auth,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
        } catch {
            throw SSHError.connectionFailed(underlying: "\(error)")
        }
    }

    public func exec(_ command: String) async throws -> SSHExecResult {
        guard let client else { throw SSHError.alreadyDisconnected }
        do {
            let output: ByteBuffer = try await client.executeCommand(command)
            let stdout = Data(output.readableBytesView)
            return SSHExecResult(stdout: stdout, stderr: Data(), exitCode: 0)
        } catch {
            throw SSHError.execFailed(underlying: "\(error)")
        }
    }

    public func disconnect() async {
        try? await client?.close()
        client = nil
    }
}
