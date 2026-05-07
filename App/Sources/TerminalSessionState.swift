import Foundation
import Observation
import CoreGraphics

/// Direction for spatial pane navigation (`⌘⌥+arrow`).
enum PaneNavigationDirection {
    case left, right, up, down
}

/// `Identifiable` wrapper around a `(paneID, frame)` pair for use
/// in the flat treemap-style pane renderer. SwiftUI tracks each
/// `paneCell` by `paneID` (stable across tree rearrangements),
/// which is the whole point — without it, splitting a leaf into a
/// branch destroys the leaf's `TerminalHost` because the parent's
/// shape changed.
struct PaneLayoutEntry: Identifiable, Equatable {
    let id: Int
    let frame: CGRect
}

/// Which edge of the target pane a dropped pane lands against.
/// `top`/`bottom` produce a vertical split (panes stacked); `left`/
/// `right` produce a horizontal split (panes side-by-side). Maps
/// 1:1 to tmux's `join-pane -h/-v [-b]` flags.
enum PaneDropEdge {
    case top, bottom, left, right
}

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

    /// Replace the leaf for `target` with `replacement` (which may
    /// itself be a subtree). No-op if `target` isn't in the tree.
    /// Used by pane-to-pane drag-drop: source is first removed, then
    /// the target leaf is replaced by a 2-child split holding the
    /// target plus the source on the chosen edge.
    func replacingLeaf(target: Int, with replacement: PaneNode) -> PaneNode {
        switch self {
        case .leaf(let pid):
            return pid == target ? replacement : self
        case .split(let dir, let kids):
            return .split(
                direction: dir,
                children: kids.map { $0.replacingLeaf(target: target, with: replacement) }
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

    /// Spatial neighbor of `paneID` in `direction`. Returns `nil` if
    /// the pane sits at the edge in that direction (caller no-ops)
    /// or the id isn't in the tree.
    ///
    /// Scoring follows iTerm2-style layered preference:
    /// 1. Filter candidates that lie *strictly past* the current
    ///    pane's edge in the requested direction.
    /// 2. Prefer candidates that overlap the current pane in the
    ///    perpendicular axis (i.e. for `.right`, share Y range).
    ///    If any do, drop the rest — diagonal picks are noisy.
    /// 3. Among the remaining pool, pick the one with the smallest
    ///    direction-aligned distance (gap between edges along the
    ///    motion axis). Ties break on perpendicular-axis center
    ///    distance — the closer perpendicularly aligned pane wins.
    func neighbor(of paneID: Int, direction: PaneNavigationDirection) -> Int? {
        let rects = paneRects()
        guard let cur = rects.first(where: { $0.id == paneID })?.frame else { return nil }
        let past = rects.filter { entry in
            entry.id != paneID && Self.isPast(entry.frame, current: cur, direction: direction)
        }
        let overlapping = past.filter {
            Self.hasPerpendicularOverlap($0.frame, current: cur, direction: direction)
        }
        let pool = overlapping.isEmpty ? past : overlapping
        return pool.min { lhs, rhs in
            let lhsDir = Self.directionDistance(lhs.frame, current: cur, direction: direction)
            let rhsDir = Self.directionDistance(rhs.frame, current: cur, direction: direction)
            if lhsDir != rhsDir { return lhsDir < rhsDir }
            let lhsPerp = Self.perpendicularCenterDistance(lhs.frame, current: cur, direction: direction)
            let rhsPerp = Self.perpendicularCenterDistance(rhs.frame, current: cur, direction: direction)
            return lhsPerp < rhsPerp
        }?.id
    }

    /// Compute an absolute rectangle for every leaf pane, recursing
    /// through the split tree. Used by spatial pane navigation
    /// (default unit-rect frame) and by the flat treemap-style
    /// pane renderer (frame = the pane area's actual size).
    func paneRects(in frame: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1))
        -> [(id: Int, frame: CGRect)]
    {
        switch self {
        case .leaf(let pid):
            return [(pid, frame)]
        case .split(let dir, let kids):
            let count = CGFloat(kids.count)
            return kids.enumerated().flatMap { (i, kid) -> [(id: Int, frame: CGRect)] in
                let kidFrame: CGRect
                switch dir {
                case .horizontal:
                    let unit = frame.width / count
                    kidFrame = CGRect(
                        x: frame.minX + unit * CGFloat(i),
                        y: frame.minY,
                        width: unit,
                        height: frame.height
                    )
                case .vertical:
                    let unit = frame.height / count
                    kidFrame = CGRect(
                        x: frame.minX,
                        y: frame.minY + unit * CGFloat(i),
                        width: frame.width,
                        height: unit
                    )
                }
                return kid.paneRects(in: kidFrame)
            }
        }
    }

    private static func isPast(
        _ candidate: CGRect,
        current: CGRect,
        direction: PaneNavigationDirection
    ) -> Bool {
        let eps: CGFloat = 1e-6
        switch direction {
        case .right: return candidate.minX >= current.maxX - eps
        case .left:  return candidate.maxX <= current.minX + eps
        case .up:    return candidate.maxY <= current.minY + eps
        case .down:  return candidate.minY >= current.maxY - eps
        }
    }

    private static func hasPerpendicularOverlap(
        _ candidate: CGRect,
        current: CGRect,
        direction: PaneNavigationDirection
    ) -> Bool {
        switch direction {
        case .left, .right:
            return max(candidate.minY, current.minY) < min(candidate.maxY, current.maxY)
        case .up, .down:
            return max(candidate.minX, current.minX) < min(candidate.maxX, current.maxX)
        }
    }

    private static func directionDistance(
        _ candidate: CGRect,
        current: CGRect,
        direction: PaneNavigationDirection
    ) -> CGFloat {
        switch direction {
        case .right: return candidate.minX - current.maxX
        case .left:  return current.minX - candidate.maxX
        case .up:    return current.minY - candidate.maxY
        case .down:  return candidate.minY - current.maxY
        }
    }

    private static func perpendicularCenterDistance(
        _ candidate: CGRect,
        current: CGRect,
        direction: PaneNavigationDirection
    ) -> CGFloat {
        switch direction {
        case .left, .right: return abs(candidate.midY - current.midY)
        case .up, .down:    return abs(candidate.midX - current.midX)
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

    /// Per-pane display title, keyed by `paneID`. The tmux backend
    /// fills this from `pane_current_command` (polled). The fake
    /// backend seeds it once at init. Views read via
    /// `SessionBackend.paneTitle(_:)` which falls back to this
    /// cache; the @Observable wrapper makes title changes reactive.
    var paneTitles: [Int: String] = [:]

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
