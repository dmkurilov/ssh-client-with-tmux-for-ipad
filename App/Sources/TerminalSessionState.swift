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

/// One pane's cell rectangle inside a window. `x`, `y`, `cols`,
/// `rows` are in terminal cells (not points). Pixel coords are
/// derived once the renderer knows its `CellMetrics`. This carries
/// what `paneRects` cannot: the *cell weights* tmux assigned to each
/// pane, so panes render at exactly tmux's grid coordinates instead
/// of evenly-divided proportions.
struct PaneCellRect: Equatable {
    let paneID: Int
    let x: Int
    let y: Int
    let cols: Int
    let rows: Int
}

/// Window-wide cell layout: total cell dimensions plus a flat list
/// of every leaf pane's cell rectangle. Filled by the tmux backend
/// from `TmuxLayout`; fake backend leaves it nil and the renderer
/// falls back to proportional sizing.
struct CellLayout: Equatable {
    let cols: Int
    let rows: Int
    let panes: [PaneCellRect]
}

/// Recursive cell-grid tree mirroring `TmuxCC.TmuxLayout` but kept
/// in the App layer so views can consume it without importing
/// `TmuxCC`. The layout engine walks this to apportion pixels
/// proportionally and subtract chrome at each split — flat
/// `CellLayout` doesn't tell us "are these panes side-by-side or
/// stacked," which we need for chrome accounting.
struct LayoutCellNode: Equatable {
    /// Cell counts of this subtree as tmux reports them.
    let cols: Int
    let rows: Int
    let kind: Kind

    indirect enum Kind: Equatable {
        case leaf(paneID: Int)
        /// Children placed left-to-right; widths apportioned.
        case horizontal(children: [LayoutCellNode])
        /// Children stacked top-to-bottom; heights apportioned.
        case vertical(children: [LayoutCellNode])
    }

    /// Flat list of every leaf pane id in render order.
    var paneIDs: [Int] {
        switch kind {
        case .leaf(let pid): return [pid]
        case .horizontal(let kids), .vertical(let kids):
            return kids.flatMap { $0.paneIDs }
        }
    }

    /// Return a copy of the tree where consecutive same-axis splits
    /// are folded into a single N-ary split (vert(A, vert(B, C)) →
    /// vert(A, B, C)). The leaf set and per-leaf cell counts are
    /// preserved; only intermediate split nodes change. Used by
    /// `PaneLayoutEngine.layout` so the per-leaf CP chrome is
    /// counted once per leaf instead of once per nesting level.
    /// Splits across different axes are *not* merged.
    func flattenedSameAxisSplits() -> LayoutCellNode {
        switch kind {
        case .leaf:
            return self
        case .horizontal(let kids):
            let flatKids = kids.map { $0.flattenedSameAxisSplits() }
                .flatMap { kid -> [LayoutCellNode] in
                    if case .horizontal(let inner) = kid.kind { return inner }
                    return [kid]
                }
            return LayoutCellNode(cols: cols, rows: rows, kind: .horizontal(children: flatKids))
        case .vertical(let kids):
            let flatKids = kids.map { $0.flattenedSameAxisSplits() }
                .flatMap { kid -> [LayoutCellNode] in
                    if case .vertical(let inner) = kid.kind { return inner }
                    return [kid]
                }
            return LayoutCellNode(cols: cols, rows: rows, kind: .vertical(children: flatKids))
        }
    }

    /// Write engine-apportioned cell counts back into the tree as
    /// the new weights. After this, `leaf.cols == engine.cellCols`
    /// and `leaf.rows == engine.cellRows`, which means a subsequent
    /// `resizingPane(±N)` translates into exactly ±N cells of
    /// engine output (modulo sibling-floor clamping). Without this
    /// normalization the tree's cols/rows fields are *weights* that
    /// the engine then re-apportions into cells — a +85-weight bump
    /// against a [1, 480] tree produces +23 cells, not +85. Internal
    /// split nodes get their cols/rows recomputed from the new
    /// children to keep "subtree cells == sum of children + tmux's
    /// 1-cell logical borders" along the split axis, max along the
    /// orthogonal axis.
    func normalizingWeights(leafSizes: [Int: (cols: Int, rows: Int)]) -> LayoutCellNode {
        switch kind {
        case .leaf(let pid):
            guard let size = leafSizes[pid] else { return self }
            return LayoutCellNode(cols: size.cols, rows: size.rows, kind: kind)
        case .horizontal(let kids):
            let newKids = kids.map { $0.normalizingWeights(leafSizes: leafSizes) }
            let newCols = newKids.reduce(0) { $0 + $1.cols } + max(0, newKids.count - 1)
            let newRows = newKids.map(\.rows).max() ?? 0
            return LayoutCellNode(cols: newCols, rows: newRows, kind: .horizontal(children: newKids))
        case .vertical(let kids):
            let newKids = kids.map { $0.normalizingWeights(leafSizes: leafSizes) }
            let newCols = newKids.map(\.cols).max() ?? 0
            let newRows = newKids.reduce(0) { $0 + $1.rows } + max(0, newKids.count - 1)
            return LayoutCellNode(cols: newCols, rows: newRows, kind: .vertical(children: newKids))
        }
    }

    /// Build a default cell tree mirroring a topology-only `PaneNode`.
    /// Each leaf gets a small cell budget; splits sum across their
    /// axis (including tmux's logical 1-cell border between siblings)
    /// and use max on the perpendicular axis. Used by
    /// `FakeSessionBackend` to give the demo a real `cellTree` so it
    /// shares the engine-driven render path with the tmux backend.
    static func defaultTree(from node: PaneNode, leafCols: Int = 40, leafRows: Int = 20) -> LayoutCellNode {
        switch node {
        case .leaf(let pid):
            return LayoutCellNode(cols: leafCols, rows: leafRows, kind: .leaf(paneID: pid))
        case .split(let dir, let kids):
            let cellKids = kids.map { defaultTree(from: $0, leafCols: leafCols, leafRows: leafRows) }
            switch dir {
            case .horizontal:
                let cols = cellKids.reduce(0) { $0 + $1.cols } + max(0, cellKids.count - 1)
                let rows = cellKids.map(\.rows).max() ?? 0
                return LayoutCellNode(cols: cols, rows: rows, kind: .horizontal(children: cellKids))
            case .vertical:
                let cols = cellKids.map(\.cols).max() ?? 0
                let rows = cellKids.reduce(0) { $0 + $1.rows } + max(0, cellKids.count - 1)
                return LayoutCellNode(cols: cols, rows: rows, kind: .vertical(children: cellKids))
            }
        }
    }

    /// Replace the leaf for `target` with a 2-child sub-split — the
    /// original leaf plus a new leaf for `newID`. Each child gets
    /// half of the original leaf's cells along the split axis;
    /// siblings of the target are untouched. Used by the fake
    /// backend's `splitPane` so a split doesn't reset every pane's
    /// size (the prior `defaultTree(from:)` rebuild was wiping
    /// custom cell counts on every layout edit).
    func splittingPane(target: Int, direction: SplitDirection, newID: Int) -> LayoutCellNode {
        switch kind {
        case .leaf(let pid):
            guard pid == target else { return self }
            switch direction {
            case .horizontal:
                let firstCols = max(1, cols / 2)
                // Spare 1 cell for tmux's logical border between siblings.
                let secondCols = max(1, cols - firstCols - 1)
                let first = LayoutCellNode(cols: firstCols, rows: rows, kind: .leaf(paneID: target))
                let second = LayoutCellNode(cols: secondCols, rows: rows, kind: .leaf(paneID: newID))
                return LayoutCellNode(cols: cols, rows: rows, kind: .horizontal(children: [first, second]))
            case .vertical:
                let firstRows = max(1, rows / 2)
                let secondRows = max(1, rows - firstRows - 1)
                let first = LayoutCellNode(cols: cols, rows: firstRows, kind: .leaf(paneID: target))
                let second = LayoutCellNode(cols: cols, rows: secondRows, kind: .leaf(paneID: newID))
                return LayoutCellNode(cols: cols, rows: rows, kind: .vertical(children: [first, second]))
            }
        case .horizontal(let kids):
            return LayoutCellNode(
                cols: cols, rows: rows,
                kind: .horizontal(children: kids.map { $0.splittingPane(target: target, direction: direction, newID: newID) })
            )
        case .vertical(let kids):
            return LayoutCellNode(
                cols: cols, rows: rows,
                kind: .vertical(children: kids.map { $0.splittingPane(target: target, direction: direction, newID: newID) })
            )
        }
    }

    /// Remove `paneID` from the tree, returning the pruned tree or
    /// nil if no leaves remain. Splits with one child collapse to
    /// that child so the tree doesn't accumulate degenerate nodes
    /// over many kill / move operations. Mirrors `PaneNode.removingPane`
    /// but preserves the cell counts of surviving leaves.
    func removingPane(_ id: Int) -> LayoutCellNode? {
        switch kind {
        case .leaf(let pid):
            return pid == id ? nil : self
        case .horizontal(let kids):
            let pruned = kids.compactMap { $0.removingPane(id) }
            if pruned.isEmpty { return nil }
            if pruned.count == 1 { return pruned[0] }
            return LayoutCellNode(cols: cols, rows: rows, kind: .horizontal(children: pruned))
        case .vertical(let kids):
            let pruned = kids.compactMap { $0.removingPane(id) }
            if pruned.isEmpty { return nil }
            if pruned.count == 1 { return pruned[0] }
            return LayoutCellNode(cols: cols, rows: rows, kind: .vertical(children: pruned))
        }
    }

    /// Adjust the boundary between the pane containing `paneID` and
    /// its sibling in `direction`, by `cells` cells. Used by the
    /// fake backend's `resizePane` to honor drag gestures. Returns
    /// the modified tree, or the original if no resize is possible
    /// (e.g. `paneID` is missing, or there's no sibling in the
    /// requested direction at any ancestor).
    ///
    /// The walk is bottom-up: we descend to the leaf, then on the
    /// way back try to apply the resize at each enclosing split.
    /// The *first* matching split (correct axis, has a sibling in
    /// the requested direction) wins — that's typically the
    /// shallowest split that owns the relevant edge. tmux's
    /// `resize-pane -L|R|U|D` behaves the same way.
    func resizingPane(_ paneID: Int, direction: ResizeDirection, cells: Int) -> LayoutCellNode {
        guard cells != 0 else { return self }
        let (result, applied) = Self.resizeWalk(self, paneID: paneID, direction: direction, cells: cells)
        if applied { return result }
        // Pane has no sibling in the requested direction at any
        // level (e.g. bottom-most pane asked to grow .down). Retry
        // the opposite direction so promotes still work for edge
        // panes — the cells then come from the sibling on the
        // *other* side instead.
        let opposite: ResizeDirection
        switch direction {
        case .right: opposite = .left
        case .left:  opposite = .right
        case .down:  opposite = .up
        case .up:    opposite = .down
        }
        let (retry, _) = Self.resizeWalk(self, paneID: paneID, direction: opposite, cells: cells)
        return retry
    }

    private static func resizeWalk(
        _ node: LayoutCellNode,
        paneID: Int,
        direction: ResizeDirection,
        cells: Int
    ) -> (node: LayoutCellNode, applied: Bool) {
        switch node.kind {
        case .leaf:
            return (node, false)

        case .horizontal(let kids):
            return applyOrRecurse(
                node: node,
                kids: kids,
                paneID: paneID,
                direction: direction,
                cells: cells,
                isHorizontal: true
            )

        case .vertical(let kids):
            return applyOrRecurse(
                node: node,
                kids: kids,
                paneID: paneID,
                direction: direction,
                cells: cells,
                isHorizontal: false
            )
        }
    }

    private static func applyOrRecurse(
        node: LayoutCellNode,
        kids: [LayoutCellNode],
        paneID: Int,
        direction: ResizeDirection,
        cells: Int,
        isHorizontal: Bool
    ) -> (node: LayoutCellNode, applied: Bool) {
        guard let idx = kids.firstIndex(where: { $0.paneIDs.contains(paneID) }) else {
            return (node, false)
        }
        // 1. Descend first — the right split might be deeper.
        var newKids = kids
        let (descended, deeperApplied) = resizeWalk(newKids[idx], paneID: paneID, direction: direction, cells: cells)
        newKids[idx] = descended
        let kind: Kind = isHorizontal ? .horizontal(children: newKids) : .vertical(children: newKids)
        if deeperApplied {
            return (LayoutCellNode(cols: node.cols, rows: node.rows, kind: kind), true)
        }
        // 2. Deeper didn't apply. Try at this level if axis matches.
        let axisMatches = isHorizontal
            ? (direction == .left || direction == .right)
            : (direction == .up || direction == .down)
        guard axisMatches else {
            return (LayoutCellNode(cols: node.cols, rows: node.rows, kind: kind), false)
        }
        let siblingIdx: Int?
        switch direction {
        case .right, .down: siblingIdx = (idx + 1 < kids.count) ? idx + 1 : nil
        case .left, .up:    siblingIdx = (idx > 0) ? idx - 1 : nil
        }
        guard let siblingIdx else {
            return (LayoutCellNode(cols: node.cols, rows: node.rows, kind: kind), false)
        }
        // 3. We can apply. Adjust the matching pair.
        if isHorizontal {
            newKids[idx] = bump(newKids[idx], deltaCols: cells)
            newKids[siblingIdx] = bump(newKids[siblingIdx], deltaCols: -cells)
        } else {
            newKids[idx] = bump(newKids[idx], deltaRows: cells)
            newKids[siblingIdx] = bump(newKids[siblingIdx], deltaRows: -cells)
        }
        let appliedKind: Kind = isHorizontal ? .horizontal(children: newKids) : .vertical(children: newKids)
        return (LayoutCellNode(cols: node.cols, rows: node.rows, kind: appliedKind), true)
    }

    private static func bump(_ node: LayoutCellNode, deltaCols: Int = 0, deltaRows: Int = 0) -> LayoutCellNode {
        // Floor at 1 cell so we don't produce zero-size subtrees.
        // Engine's hidden-flag logic handles "below min" rendering.
        return LayoutCellNode(
            cols: max(1, node.cols + deltaCols),
            rows: max(1, node.rows + deltaRows),
            kind: node.kind
        )
    }
}

struct WindowInfo: Identifiable, Equatable {
    let id: Int
    var name: String?
    var layout: PaneNode
    /// tmux-authored per-pane cell coordinates. `nil` when the
    /// backend doesn't have cell-level info (fake backend, or before
    /// the first `%layout-change`). When present the renderer sizes
    /// each pane at exactly `cols × cellW` × `rows × cellH` points
    /// — which is the whole point of the "tmux owns the grid"
    /// architecture.
    var cellLayout: CellLayout?
    /// Recursive form of `cellLayout` — same data, kept as a tree so
    /// the layout engine can walk splits and subtract chrome at
    /// each level. Nil under the same conditions as `cellLayout`.
    var cellTree: LayoutCellNode?
    var activePaneID: Int?

    /// Flat list of pane ids in this window's tree. Read-only —
    /// mutate via `layout`.
    var paneIDs: [Int] { layout.allPaneIDs }

    init(
        id: Int,
        name: String? = nil,
        layout: PaneNode,
        cellLayout: CellLayout? = nil,
        cellTree: LayoutCellNode? = nil,
        activePaneID: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.layout = layout
        self.cellLayout = cellLayout
        self.cellTree = cellTree
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
