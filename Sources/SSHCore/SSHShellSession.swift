import Foundation

/// A live interactive shell on top of an existing `SSHConnection`.
/// Bytes flow in both directions: remote output arrives via the
/// `output` async stream, local input is sent with `write(_:)`.
///
/// Created by `SSHConnection.openShell(...)`. The session stays alive
/// until the remote closes the channel or the caller invokes `close()`.
public actor SSHShellSession {

    /// Bytes from the remote (stdout and stderr merged), in arrival
    /// order. The stream finishes when the channel closes cleanly, or
    /// throws if it drops unexpectedly.
    public nonisolated let output: AsyncThrowingStream<Data, Error>

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let writer: @Sendable (Data) async throws -> Void
    private let closer: @Sendable () async -> Void
    private let resizer: (@Sendable (Int, Int) async throws -> Void)?

    private var isClosed = false

    init(
        output: AsyncThrowingStream<Data, Error>,
        continuation: AsyncThrowingStream<Data, Error>.Continuation,
        writer: @escaping @Sendable (Data) async throws -> Void,
        closer: @escaping @Sendable () async -> Void,
        resizer: (@Sendable (Int, Int) async throws -> Void)? = nil
    ) {
        self.output = output
        self.continuation = continuation
        self.writer = writer
        self.closer = closer
        self.resizer = resizer
    }

    public func write(_ data: Data) async throws {
        guard !isClosed else { throw SSHError.alreadyDisconnected }
        try await writer(data)
    }

    /// Tell the remote the PTY geometry has changed. No-op if the
    /// session was opened without a PTY.
    public func resize(cols: Int, rows: Int) async throws {
        guard !isClosed else { throw SSHError.alreadyDisconnected }
        try await resizer?(cols, rows)
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        continuation.finish()
        await closer()
    }
}
