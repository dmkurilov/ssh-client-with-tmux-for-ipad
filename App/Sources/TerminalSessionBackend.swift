import Foundation
import TerminalKit

/// One pane's I/O channel. The backend is responsible for pumping
/// bytes from "the server" into `driver` (which `SwiftTermView`
/// renders) and shipping caller-supplied bytes the other direction
/// via `send`.
///
/// The driver is owned by the pane and lives for the pane's
/// lifetime. The view binds to it; replays are handled by the
/// driver's own buffer when the view mounts late.
@MainActor
protocol PaneBackend: AnyObject {
    var driver: TerminalDriver { get }

    /// Caller-side input — typed bytes from the user, or paste.
    /// Implementations log every call (per the project's debug-log
    /// policy) and route to the wire (or echo loop, or test sink).
    func send(_ data: Data) async

    /// Notify the backend of a render-time size change. tmux backends
    /// translate to `resize-pane`; SSH backends translate to a PTY
    /// resize on the SSH channel; fake backends just log it.
    func resize(cols: Int, rows: Int) async
}

/// What a view needs to drive a terminal session — tmux, raw SSH,
/// or a fake. Conforming types own a `SessionState` (read by views
/// via `@Observable`) and implement the command verbs that
/// state-mutating UI actions trigger.
///
/// Convenience verbs take "the active pane / window" implicitly
/// when applicable; explicit verbs take the target id.
@MainActor
protocol SessionBackend: AnyObject {
    /// The shared, observable state. Views read this; backends
    /// mutate it.
    var state: SessionState { get }

    /// Per-pane I/O. Nil if the pane id isn't known to this backend.
    func pane(_ id: Int) -> PaneBackend?

    /// Tear-down hook called when the screen is going away. Cancel
    /// in-flight work, close streams, etc.
    func disconnect() async

    // MARK: - State-mutating commands. SSH-mode backends may no-op
    //         for the ones that don't apply (split, kill, etc.).

    func splitPane(direction: SplitDirection, target: Int) async
    func killPane(_ paneID: Int) async
    func selectPane(_ paneID: Int) async
    func newWindow() async
    func selectWindow(_ windowID: Int) async
    func killWindow(_ windowID: Int) async
    func renameWindow(_ windowID: Int, name: String) async
    func renameSession(_ newName: String) async

    /// Toggle zoom on a pane (tmux `resize-pane -Z`). When zoomed,
    /// only this pane renders; the others stay alive but hidden.
    /// SSH mode is a no-op.
    func toggleZoom(paneID: Int) async

    /// Move a pane between windows. Drag-to-tab in the UI calls
    /// this. Drop on `+` (new tab) is a separate verb the view
    /// composes from `newWindow()` + `movePane(...)` once the new
    /// window's id arrives.
    func movePane(paneID: Int, toWindow windowID: Int) async

    /// Display title for a pane — typically the foreground command
    /// plus whatever extra status the backend chooses to surface
    /// (e.g. tmux's `pane_title` and `pane_current_command`, or an
    /// `mc [user@host]: ~/path` synthesis). Returns `nil` if the
    /// backend has nothing useful to offer; the view falls back to
    /// `%<id>`.
    func paneTitle(_ paneID: Int) -> String?
}

/// No-op default implementations so backends only override what
/// they actually support. SSH mode in particular wants to inherit
/// most of these as no-ops.
extension SessionBackend {
    func splitPane(direction: SplitDirection, target: Int) async {}
    func killPane(_ paneID: Int) async {}
    func selectPane(_ paneID: Int) async {}
    func newWindow() async {}
    func selectWindow(_ windowID: Int) async {}
    func killWindow(_ windowID: Int) async {}
    func renameWindow(_ windowID: Int, name: String) async {}
    func renameSession(_ newName: String) async {}
    func toggleZoom(paneID: Int) async {}
    func movePane(paneID: Int, toWindow windowID: Int) async {}
    func paneTitle(_ paneID: Int) -> String? { nil }
}
