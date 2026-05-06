import Foundation
import Observation

/// One window's worth of state as the UI sees it. Identifiers map
/// onto tmux's `@<id>` and `%<id>` for the real backend; the fake
/// uses synthetic small ints with the same shape.
/// Recursive split tree describing a window's pane layout. Each
/// leaf is a single pane; each split groups children with a
/// direction. `splitting(target:direction:newID:)` is the canonical
/// way to add a pane: it replaces the matched leaf with a 2-child
/// split, leaving siblings untouched. That gives the iTerm2-style
/// "split this pane into two halves" behaviour.
indirect enum PaneNode: Equatable {
    case leaf(paneID: Int)
    case split(direction: SplitDirection, children: [PaneNode])

    /// Flat list of every pane id in this subtree, in render order.
    var allPaneIDs: [Int] {
        switch self {
        case .leaf(let pid): return [pid]
        case .split(_, let kids): return kids.flatMap { $0.allPaneIDs }
        }
    }

    /// Replace the leaf for `target` with a 2-child split containing
    /// the original target plus a new leaf for `newID`. No-op if
    /// `target` isn't in the tree.
    func splitting(target: Int, direction: SplitDirection, newID: Int) -> PaneNode {
        switch self {
        case .leaf(let pid):
            if pid == target {
                return .split(
                    direction: direction,
                    children: [.leaf(paneID: target), .leaf(paneID: newID)]
                )
            }
            return self
        case .split(let dir, let kids):
            return .split(
                direction: dir,
                children: kids.map {
                    $0.splitting(target: target, direction: direction, newID: newID)
                }
            )
        }
    }

    /// Remove a pane. Returns the pruned tree, or `nil` when the
    /// removal would leave the tree empty (caller drops the window).
    /// Splits with one remaining child collapse to that child so
    /// trees don't grow degenerate over time.
    func removingPane(_ id: Int) -> PaneNode? {
        switch self {
        case .leaf(let pid):
            return pid == id ? nil : self
        case .split(let dir, let kids):
            let pruned = kids.compactMap { $0.removingPane(id) }
            if pruned.isEmpty { return nil }
            if pruned.count == 1 { return pruned[0] }
            return .split(direction: dir, children: pruned)
        }
    }
}

struct WindowInfo: Identifiable, Equatable {
    let id: Int
    var name: String?
    var layout: PaneNode
    var activePaneID: Int?

    /// Flat list of pane ids in this window's tree. Read-only —
    /// mutate via `layout`.
    var paneIDs: [Int] { layout.allPaneIDs }

    init(id: Int, name: String? = nil, layout: PaneNode, activePaneID: Int? = nil) {
        self.id = id
        self.name = name
        self.layout = layout
        self.activePaneID = activePaneID
    }
}

/// Direction for `splitPane`. Mirrors tmux's flag vocabulary:
/// `.horizontal` = tmux `-h` = vertical *divider* between panes
/// (panes laid out **side by side**); `.vertical` = tmux `-v` =
/// horizontal *divider* (panes **stacked**). The case name refers
/// to the orientation of the *split motion*, which is opposite to
/// the iTerm2 menu vocabulary ("Split Vertically" = side-by-side,
/// = our `.horizontal`). User-facing labels in `DemoSessionView`
/// follow iTerm2.
enum SplitDirection: Equatable {
    /// Side by side, vertical divider. tmux `-h`.
    case horizontal
    /// Stacked, horizontal divider. tmux `-v`.
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
    /// When non-nil, this single pane should fill the tab area —
    /// other panes in the same window stay alive but aren't drawn.
    /// Mirrors tmux's `resize-pane -Z` zoom flag.
    var zoomedPaneID: Int?

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
