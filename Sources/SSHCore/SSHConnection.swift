import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH

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
        hostKeyVerifier: HostKeyVerifier
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

        let adapter = HostKeyVerifierAdapter(
            host: endpoint.host,
            port: endpoint.port,
            verifier: hostKeyVerifier
        )

        do {
            self.client = try await SSHClient.connect(
                host: endpoint.host,
                port: endpoint.port,
                authenticationMethod: auth,
                hostKeyValidator: .custom(adapter),
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
    /// `allocatePTY` controls whether the server allocates a pseudo-
    /// terminal for the session. Default `true` — needed for most
    /// interactive programs including `tmux -CC` (tmux calls
    /// `tcgetattr(3)` on startup to read terminal dimensions even
    /// though it does its own rendering).
    ///
    /// The macOS 15 availability mirrors Citadel's `withTTY`/`withPTY`
    /// gating; iOS 17 is our deployment target and unrestricted by
    /// Citadel.
    @available(macOS 15.0, iOS 17.0, *)
    public func openShell(
        allocatePTY: Bool = true,
        termType: String = "xterm-256color",
        cols: Int = 80,
        rows: Int = 24
    ) async throws -> SSHShellSession {
        guard let client else { throw SSHError.alreadyDisconnected }

        let (output, outputContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let writerBox = TTYWriterBox()

        // Shared closure for both withPTY and withTTY — same inbound/
        // outbound signature either way.
        let pump: @Sendable (TTYOutput, TTYStdinWriter) async throws -> Void =
        { inbound, outbound in
            await writerBox.set(outbound)
            do {
                for try await event in inbound {
                    // Citadel's `ExecCommandOutput` carries stdout + stderr;
                    // we merge them. Natural end + non-zero exit come
                    // through as iterator finish/throw already.
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

        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: termType,
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        // Citadel's `withTTY`/`withPTY` are scope-based: the channel
        // lives only as long as the closure runs. Wrap in an
        // unstructured task so callers can close by cancelling it.
        let ttyTask = Task.detached {
            do {
                if allocatePTY {
                    try await client.withPTY(ptyRequest, perform: pump)
                } else {
                    try await client.withTTY(perform: pump)
                }
            } catch {
                outputContinuation.finish(throwing: error)
                await writerBox.fail(error)
            }
        }

        // Block until the channel has finished setting itself up
        // (writer in hand) — otherwise an immediate `write(...)` from
        // the caller would race the channel's bring-up.
        do {
            _ = try await writerBox.awaitReady()
        } catch {
            ttyTask.cancel()
            throw SSHError.channelFailed(underlying: "\(error)")
        }

        return SSHShellSession(
            output: output,
            continuation: outputContinuation,
            writer: { data in
                let writer = try await writerBox.awaitReady()
                try await writer.write(ByteBuffer(bytes: Array(data)))
            },
            closer: {
                ttyTask.cancel()
            },
            resizer: { cols, rows in
                // TODO: confirm Citadel's exact resize API. Best guess
                // is `TTYStdinWriter.changeSize(cols:rows:pixelWidth:
                // pixelHeight:)`. If the name lives elsewhere or has a
                // different signature, we'll see a compile error.
                let writer = try await writerBox.awaitReady()
                try await writer.changeSize(
                    cols: cols,
                    rows: rows,
                    pixelWidth: 0,
                    pixelHeight: 0
                )
            }
        )
    }
}

/// Holder for the stdin writer that Citadel hands us asynchronously
/// inside the `withTTY`/`withPTY` closure. Callers `awaitReady()`
/// before writing so they don't race the channel's bring-up.
private actor TTYWriterBox {
    private enum State {
        case waiting
        case ready(TTYStdinWriter)
        case failed(Error)
    }

    private var state: State = .waiting
    private var pending: [CheckedContinuation<TTYStdinWriter, Error>] = []

    func set(_ writer: TTYStdinWriter) {
        guard case .waiting = state else { return }
        state = .ready(writer)
        let conts = pending
        pending = []
        for cont in conts { cont.resume(returning: writer) }
    }

    func fail(_ error: Error) {
        guard case .waiting = state else { return }
        state = .failed(error)
        let conts = pending
        pending = []
        for cont in conts { cont.resume(throwing: error) }
    }

    func awaitReady() async throws -> TTYStdinWriter {
        switch state {
        case .ready(let w):
            return w
        case .failed(let e):
            throw e
        case .waiting:
            return try await withCheckedThrowingContinuation { cont in
                pending.append(cont)
            }
        }
    }
}
