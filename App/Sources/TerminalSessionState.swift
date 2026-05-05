import Foundation
import Observation

/// One window's worth of state as the UI sees it. Identifiers map
/// onto tmux's `@<id>` and `%<id>` for the real backend; the fake
/// uses synthetic small ints with the same shape.
struct WindowInfo: Identifiable, Equatable {
    let id: Int
    var name: String?
    var paneIDs: [Int]
    var activePaneID: Int?

    init(id: Int, name: String? = nil, paneIDs: [Int] = [], activePaneID: Int? = nil) {
        self.id = id
        self.name = name
        self.paneIDs = paneIDs
        self.activePaneID = activePaneID
    }
}

/// Direction for `splitPane`. tmux speaks `-h` (horizontal split,
/// panes side by side) and `-v` (vertical split, panes stacked);
/// we mirror that vocabulary here.
enum SplitDirection {
    /// Side by side. tmux `-h`.
    case horizontal
    /// Stacked. tmux `-v`.
    case vertical
}

/// Observable model the views read from. Each `SessionBackend`
/// owns one `SessionState` and mutates it as protocol notifications
/// or fake events arrive. Views observe via the `@Observable` macro.
///
/// The state shape is intentionally tmux-flavoured (windows, panes,
/// activeWindowID). SSH mode collapses to one synthetic window with
/// one synthetic pane; that's the cost of having a single shared
/// view layer.
@MainActor
@Observable
final class SessionState {
    var sessionName: String?
    var sessionID: Int?
    var windows: [WindowInfo] = []
    var activeWindowID: Int?
    /// `true` once the underlying transport has handed us at least
    /// one window. Views gate "session ready" UI on this.
    var isAttached: Bool = false

    /// Convenience: the currently-active window, or `nil` if none.
    var activeWindow: WindowInfo? {
        guard let id = activeWindowID else { return nil }
        return windows.first { $0.id == id }
    }

    /// Convenience: the currently-active pane id, or `nil` if no
    /// active window or that window has no panes.
    var activePaneID: Int? {
        activeWindow?.activePaneID ?? activeWindow?.paneIDs.first
    }
}
