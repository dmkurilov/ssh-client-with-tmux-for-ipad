#if canImport(UIKit)
import Foundation
import SSHCore

/// `SessionBackend` for a pure SSH connection — no tmux, no
/// multiplexing. The state has exactly one synthetic window with
/// exactly one synthetic pane; `mode = .single` tells `SessionView`
/// to hide the tab strip, the pane control bar, and the split-/tab-
/// related keyboard shortcuts.
///
/// All multiplexing verbs (`splitPane`, `newWindow`, `selectPane`,
/// `killWindow`, etc.) inherit the protocol's default no-op
/// implementations — they have no meaning when there's nothing to
/// split.
///
/// Lifecycle: the wrapping view (`SSHBackendSessionView`) owns the
/// `SSHConnection` and `SSHShellSession`. It hands the shell to
/// `init` and is responsible for tearing down both after calling
/// `disconnect()`. Reconnect means: build a new backend with a
/// fresh shell.
@MainActor
final class SSHSessionBackend: SessionBackend {
    let state = SessionState()
    private let paneBackend: SSHPaneBackend

    /// Synthetic ids. The view never shows them — `.single` mode
    /// hides every UI element that would.
    private static let syntheticPaneID = 1
    private static let syntheticWindowID = 1

    init(host: String, user: String, shell: SSHShellSession) {
        FileLogger.shared.log("SSHSession init host=\(host) user=\(user)")
        self.paneBackend = SSHPaneBackend(id: Self.syntheticPaneID, shell: shell)

        state.mode = .single
        state.sessionName = "\(user)@\(host)"
        state.sessionID = 0
        let win = WindowInfo(
            id: Self.syntheticWindowID,
            name: nil,
            layout: .leaf(paneID: Self.syntheticPaneID),
            cellTree: nil,
            activePaneID: Self.syntheticPaneID
        )
        state.windows = [win]
        state.activeWindowID = win.id
        state.isAttached = true
    }

    func pane(_ id: Int) -> PaneBackend? {
        id == Self.syntheticPaneID ? paneBackend : nil
    }

    func disconnect() async {
        FileLogger.shared.log("SSHSession.disconnect")
        paneBackend.close()
        state.windows = []
        state.activeWindowID = nil
        state.isAttached = false
    }

    /// Forward grid changes from the layout engine (which, in
    /// `.single` mode, just computes "the full pane area in
    /// cells") to the SSH PTY. Without this the remote shell
    /// keeps its initial PTY size even after the user rotates the
    /// device or toggles fullscreen.
    func applyGrid(cols: Int, rows: Int) async {
        FileLogger.shared.log("SSHSession.applyGrid \(cols)x\(rows)")
        await paneBackend.resize(cols: cols, rows: rows)
    }

    /// Wrap-around for `SessionView`'s `applyWindowLayout` path. In
    /// `.single` mode there's only one pane, so we forward the
    /// engine's cell sizing to the PTY exactly like `applyGrid`.
    func applyWindowLayout(
        windowID: Int,
        cellCols: Int,
        cellRows: Int,
        panes: [(paneID: Int, cols: Int, rows: Int)]
    ) async {
        guard windowID == Self.syntheticWindowID,
              let entry = panes.first
        else { return }
        FileLogger.shared.log("SSHSession.applyWindowLayout \(cellCols)x\(cellRows)")
        await paneBackend.resize(cols: entry.cols, rows: entry.rows)
    }

    /// Wrapper-view hook: the SSH output stream closed cleanly
    /// (remote ended the channel). The wrapping view uses this to
    /// flip its status message so foreground-reconnect knows the
    /// session is gone. Forwarded straight to the pane.
    func onStreamEnded(_ handler: @escaping @MainActor () -> Void) {
        paneBackend.onStreamEnded = handler
    }

    /// Wrapper-view hook for pump errors (network drop, channel
    /// reset). Same purpose as `onStreamEnded`; the error is
    /// surfaced so the view can display it.
    func onStreamError(_ handler: @escaping @MainActor (Error) -> Void) {
        paneBackend.onStreamError = handler
    }
}
#endif
