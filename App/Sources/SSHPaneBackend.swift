#if canImport(UIKit)
import Foundation
import SSHCore
import TerminalKit

/// `PaneBackend` for a single SSH shell. Bytes come in from the
/// remote PTY (via `SSHShellSession.output`) and drive
/// `TerminalDriver` directly — there's no tmux protocol parsing,
/// no multiplexing, just a raw byte stream. User input goes the
/// other direction via `shell.write`.
///
/// Pump is owned by this object so the pane's lifecycle controls
/// the read loop. `close()` cancels the pump; the underlying
/// `SSHShellSession` is owned by the wrapping view and torn down
/// alongside.
@MainActor
final class SSHPaneBackend: PaneBackend {
    let id: Int
    let driver: TerminalDriver

    private let shell: SSHShellSession
    private var pumpTask: Task<Void, Never>?
    /// Fires once when the SSH output stream finishes cleanly (remote
    /// closed the channel). The wrapping view uses this to flip its
    /// status message to "stream ended" so the foreground-reconnect
    /// path knows there's no live session anymore.
    var onStreamEnded: (@MainActor () -> Void)?
    /// Fires once when the pump throws (network drop, channel
    /// reset, etc.). Same purpose as `onStreamEnded` but carries the
    /// underlying error for surfacing in the UI.
    var onStreamError: (@MainActor (Error) -> Void)?

    init(id: Int, shell: SSHShellSession) {
        self.id = id
        self.driver = TerminalDriver()
        self.shell = shell
        FileLogger.shared.log("SSHPane[%\(id)] created")
        startPump()
    }

    private func startPump() {
        // `Task { }` (not `.detached`) inherits the enclosing
        // `@MainActor` context. The `for try await` suspends
        // between chunks, so the main thread is free for other
        // work between byte arrivals — and `driver.feed` runs on
        // the same actor it's isolated to without an extra hop.
        // This avoids the Swift 6 capture-across-actor warning we
        // hit with `Task.detached { [weak self] ... self?.driver }`.
        let id = self.id
        let stream = shell.output
        pumpTask = Task { [weak self] in
            do {
                for try await data in stream {
                    if Task.isCancelled { return }
                    self?.driver.feed(data)
                }
                FileLogger.shared.log("SSHPane[%\(id)] stream ended")
                self?.onStreamEnded?()
            } catch {
                FileLogger.shared.log("SSHPane[%\(id)] pump error: \(error)")
                self?.onStreamError?(error)
            }
        }
    }

    func send(_ data: Data) async {
        FileLogger.shared.log("SSHPane[%\(id)].send \(data.count)B")
        do {
            try await shell.write(data)
        } catch {
            FileLogger.shared.log("SSHPane[%\(id)].send error: \(error)")
        }
    }

    func resize(cols: Int, rows: Int) async {
        FileLogger.shared.log("SSHPane[%\(id)].resize \(cols)x\(rows)")
        do {
            try await shell.resize(cols: cols, rows: rows)
        } catch {
            FileLogger.shared.log("SSHPane[%\(id)].resize error: \(error)")
        }
    }

    /// Cancel the read loop. Caller owns the `SSHShellSession` and
    /// is responsible for closing it.
    func close() {
        FileLogger.shared.log("SSHPane[%\(id)].close")
        pumpTask?.cancel()
        pumpTask = nil
    }
}
#endif
