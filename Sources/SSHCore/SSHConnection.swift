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

    /// Open an interactive shell on the existing connection.
    ///
    /// `allocatePTY` is accepted for API stability but **not wired
    /// yet** — the current implementation always opens without a PTY
    /// via Citadel's `withTTY`. A follow-up commit will use
    /// `withPTY(...)` and a `PseudoTerminalRequest` to honor this flag
    /// properly, plus wire `resize(cols:rows:)` through the underlying
    /// channel.
    public func openShell(
        allocatePTY: Bool = true,
        termType: String = "xterm-256color",
        cols: Int = 80,
        rows: Int = 24
    ) async throws -> SSHShellSession {
        guard let client else { throw SSHError.alreadyDisconnected }
        _ = (allocatePTY, termType, cols, rows)  // TODO: wire withPTY

        let (output, outputContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let writerBox = TTYWriterBox()

        // Citadel's `withTTY` is scope-based: the channel lives only as
        // long as the closure runs. Wrap it in an unstructured task so
        // callers can close the session by cancelling the task.
        let ttyTask = Task.detached {
            do {
                try await client.withTTY { inbound, outbound in
                    await writerBox.set(outbound)
                    do {
                        for try await event in inbound {
                            // Citadel's `ExecCommandOutput` is stdout+stderr;
                            // we merge them into one byte stream. Natural
                            // end and non-zero exit come through as
                            // iterator finish/throw already.
                            switch event {
                            case .stdout(let buffer), .stderr(let buffer):
                                outputContinuation.yield(Data(buffer.readableBytesView))
                            }
                        }
                        outputContinuation.finish()
                    } catch {
                        outputContinuation.finish(throwing: error)
                    }
                }
            } catch {
                outputContinuation.finish(throwing: error)
            }
        }

        return SSHShellSession(
            output: output,
            continuation: outputContinuation,
            writer: { data in
                guard let writer = await writerBox.get() else {
                    throw SSHError.channelFailed(
                        underlying: "shell stdin writer not yet available"
                    )
                }
                try await writer.write(ByteBuffer(bytes: Array(data)))
            },
            closer: {
                ttyTask.cancel()
            },
            resizer: nil  // TODO: wire with withPTY
        )
    }
}

/// Thread-safe holder for the stdin writer, which Citadel hands us
/// asynchronously inside the `withTTY` closure.
private actor TTYWriterBox {
    private var writer: TTYStdinWriter?
    func set(_ w: TTYStdinWriter) { self.writer = w }
    func get() -> TTYStdinWriter? { writer }
}
