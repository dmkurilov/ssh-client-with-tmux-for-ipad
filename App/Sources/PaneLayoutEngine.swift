#if canImport(UIKit)
import Foundation
import CoreGraphics
import TerminalKit

/// Per-pane chrome that the engine must subtract before doing any
/// cell math. All values in points. Sourced from `SessionView`
/// — the actual values it uses to render the pane control panel,
/// borders, and inner margins — so the engine and the renderer
/// agree on the chrome budget pixel-for-pixel.
struct LayoutChrome: Equatable {
    /// Height of the per-pane "× title …" control panel at the top
    /// of every leaf pane.
    let controlPanelPt: CGFloat
    /// Visible thickness of a divider between adjacent siblings.
    /// **This is purely visual**: tmux's logical model always
    /// reserves a full 1-cell border between panes, but we don't
    /// need 9pt of empty space to show "these are two panes". 1pt
    /// is enough to read, and gives each pane (cellWidth − 1)pt of
    /// extra usable space per border — almost exactly one extra
    /// cell of content per split.
    let borderPt: CGFloat
    /// Inner margin on each side of every pane. Used by the engine
    /// to subtract padding around the cell grid. 0 by default
    /// because we don't currently pad inside panes.
    let marginPt: CGFloat

    static let `default` = LayoutChrome(controlPanelPt: 28, borderPt: 1, marginPt: 0)
}

/// One draggable boundary between two adjacent panes (or pane
/// subtrees) in the engine output. Walks the cell tree to find
/// these — at each split, one divider between each pair of
/// consecutive children. The `referencePaneID` is *any* leaf in
/// the subtree on the side that owns the edge, suitable for
/// `resize-pane -t %X -L|R|U|D N` targeting.
struct EngineDivider: Equatable {
    enum Axis: Equatable {
        /// Vertical line drawn between horizontally-stacked siblings;
        /// drag left/right to move the boundary.
        case vertical
        /// Horizontal line drawn between vertically-stacked siblings;
        /// drag up/down to move the boundary.
        case horizontal
    }

    let axis: Axis
    /// 8pt-thick hit-test rect centered on the visual divider line.
    /// Wider than the 1pt visible separator to make the handle easy
    /// to grab without precise touch placement.
    let hitRect: CGRect
    /// Any leaf pane id on the "before" side of the divider (left
    /// for vertical, top for horizontal). Used as the
    /// `resize-pane -t` target — pushing this pane's far edge in
    /// the drag direction is exactly what the user is doing.
    let beforePaneID: Int
    /// Any leaf pane id on the "after" side — mirror of
    /// `beforePaneID`. Carried so drag-toward-the-other-direction
    /// can target either side.
    let afterPaneID: Int
}

/// What the engine returns: per-leaf decisions, draggable dividers,
/// and the window-wide cell dimensions (which include tmux's logical
/// 1-cell borders, so they're suitable to pass straight to
/// `resize-window`).
struct EngineOutput: Equatable {
    let layouts: [PaneFinalLayout]
    let dividers: [EngineDivider]
    let windowCellCols: Int
    let windowCellRows: Int
}

/// One pane's final layout decision: how many cells it gets, where
/// on screen the SwiftTermView should mount, and whether it's
/// hidden because we couldn't fit it.
struct PaneFinalLayout: Equatable {
    let paneID: Int
    /// Cell counts the renderer will tell tmux this pane should be.
    /// For hidden panes these are the *minimum* (5×2) — the pane
    /// still exists in tmux at its minimum size but isn't drawn.
    let cellCols: Int
    let cellRows: Int
    /// Pixel rectangle (in the pane-area coordinate space) where
    /// the inner `SwiftTermView` lives. Already cell-aligned —
    /// `width == cellCols × cellW`, `height == cellRows × cellH`.
    let innerRect: CGRect
    /// Pixel rectangle for the *outer* paneCell view (control
    /// panel + margins + cells area + bottom margin). The control
    /// panel is at `outerRect.minY`, the cells start at
    /// `outerRect.minY + controlPanelPt + marginPt`.
    let outerRect: CGRect
    /// `true` means the pane fit below our minimums — we shrink
    /// it to (5,2) in tmux and skip mounting a SwiftTermView for
    /// it. When other panes close it becomes eligible again.
    let hidden: Bool
}

/// Recursive-descent pane layout engine described in the project
/// docs. Walks the cell tree tmux gave us, apportions each split's
/// available pixel area by tmux's cell proportions, subtracts
/// chrome at each level, and produces one pixel-aligned rectangle
/// per pane.
///
/// Rounding rule: `round()` for the first N−1 children of a split,
/// `floor()` of the remaining pixels for the last one. This keeps
/// the sum equal to the available area (no drift, no over-fill)
/// while distributing the rounding error fairly.
enum PaneLayoutEngine {
    /// Minimum cell counts a pane must have to be considered fit.
    /// Panes below either are marked hidden.
    static let minCols = 5
    static let minRows = 2

    /// Run the engine. `tree` is the tmux-authored cell tree;
    /// `area` is the pixel rectangle the layout must fill (origin
    /// `.zero`, size = the SwiftUI pane area). Returns one entry
    /// per leaf pane, in tree-traversal order.
    static func layout(
        tree: LayoutCellNode,
        area: CGSize,
        cellMetrics: CellMetrics,
        chrome: LayoutChrome = .default
    ) -> EngineOutput {
        let rootRect = CGRect(origin: .zero, size: area)
        // Flatten same-axis nested splits before apportioning so
        // each leaf's CP (control panel) is counted exactly once.
        // Without this, `layoutVertical` subtracts N*CP at every
        // split level, and 6 levels of binary nesting eats roughly
        // 6 phantom CPs (~168pt) of "ghost chrome" that shows up
        // as empty space at the bottom of the column.
        let flatTree = tree.flattenedSameAxisSplits()
        var out: [PaneFinalLayout] = []
        var dividers: [EngineDivider] = []
        let dims = recurse(
            flatTree,
            in: rootRect,
            cellMetrics: cellMetrics,
            chrome: chrome,
            leaves: &out,
            dividers: &dividers
        )
        return EngineOutput(
            layouts: enforceMinimums(out),
            dividers: dividers,
            windowCellCols: dims.cols,
            windowCellRows: dims.rows
        )
    }

    // MARK: - Recursion

    /// Returns the *tmux-cell* dimensions occupied by this subtree:
    /// for a leaf, the leaf's (cellCols, cellRows); for a split,
    /// the sum across the split's axis (including tmux's logical
    /// 1-cell border between siblings) and the max across the
    /// orthogonal axis. The window-wide tmux dimensions are the
    /// root's return value — what we pass to `resize-window`.
    @discardableResult
    private static func recurse(
        _ node: LayoutCellNode,
        in rect: CGRect,
        cellMetrics: CellMetrics,
        chrome: LayoutChrome,
        leaves: inout [PaneFinalLayout],
        dividers: inout [EngineDivider]
    ) -> (cols: Int, rows: Int) {
        switch node.kind {
        case .leaf(let paneID):
            return layoutLeaf(paneID: paneID, rect: rect, cellMetrics: cellMetrics, chrome: chrome, into: &leaves)

        case .horizontal(let kids):
            return layoutHorizontal(kids: kids, rect: rect, cellMetrics: cellMetrics, chrome: chrome, leaves: &leaves, dividers: &dividers)

        case .vertical(let kids):
            return layoutVertical(kids: kids, rect: rect, cellMetrics: cellMetrics, chrome: chrome, leaves: &leaves, dividers: &dividers)
        }
    }

    private static func layoutLeaf(
        paneID: Int,
        rect: CGRect,
        cellMetrics: CellMetrics,
        chrome: LayoutChrome,
        into out: inout [PaneFinalLayout]
    ) -> (cols: Int, rows: Int) {
        // Cells area is the leaf's rect minus its own chrome:
        // top: control panel + margin; sides + bottom: margin each.
        let innerW = max(0, rect.width  - 2 * chrome.marginPt)
        let innerH = max(0, rect.height - chrome.controlPanelPt - 2 * chrome.marginPt)
        let cols = max(0, Int((innerW / cellMetrics.cellWidth).rounded(.down)))
        let rows = max(0, Int((innerH / cellMetrics.cellHeight).rounded(.down)))
        let innerOrigin = CGPoint(
            x: rect.minX + chrome.marginPt,
            y: rect.minY + chrome.controlPanelPt + chrome.marginPt
        )
        let innerRect = CGRect(
            origin: innerOrigin,
            size: CGSize(
                width:  CGFloat(cols) * cellMetrics.cellWidth,
                height: CGFloat(rows) * cellMetrics.cellHeight
            )
        )
        out.append(PaneFinalLayout(
            paneID: paneID,
            cellCols: cols, cellRows: rows,
            innerRect: innerRect, outerRect: rect,
            hidden: false
        ))
        return (cols, rows)
    }

    private static func layoutHorizontal(
        kids: [LayoutCellNode],
        rect: CGRect,
        cellMetrics: CellMetrics,
        chrome: LayoutChrome,
        leaves: inout [PaneFinalLayout],
        dividers: inout [EngineDivider]
    ) -> (cols: Int, rows: Int) {
        let n = kids.count
        guard n > 0 else { return (0, 0) }
        // Chrome between children: (N-1) *visual* borders (chrome.borderPt,
        // typically 1pt) + 2N margins. Tmux's *logical* border is still
        // 1 cell — we account for that in the return value below, not
        // here. The mismatch on purpose: tmux's window cell count includes
        // its border cells, but our visible pixels only consume `borderPt`
        // per border, so the engine apportions more pane content cells.
        let chromeW = CGFloat(n - 1) * chrome.borderPt + CGFloat(2 * n) * chrome.marginPt
        let availableW = max(0, rect.width - chromeW)
        let weightCols = kids.reduce(0) { $0 + $1.cols }
        guard weightCols > 0 else { return (0, 0) }

        // Apportion cell counts per child.
        var assignedCells: [Int] = []
        assignedCells.reserveCapacity(n)
        var cellsAssignedSoFar = 0
        for (i, kid) in kids.enumerated() {
            let cells: Int
            if i == n - 1 {
                // Last child: take whatever pixel remains (floor).
                let remainingPt = availableW - CGFloat(cellsAssignedSoFar) * cellMetrics.cellWidth
                cells = max(0, Int((remainingPt / cellMetrics.cellWidth).rounded(.down)))
            } else {
                let rate = Double(kid.cols) / Double(weightCols)
                let pt = Double(availableW) * rate
                cells = max(0, Int((pt / Double(cellMetrics.cellWidth)).rounded()))
                cellsAssignedSoFar += cells
            }
            assignedCells.append(cells)
        }

        // Recurse into children at their computed x positions.
        var x = rect.minX
        var totalCols = 0
        var maxRows = 0
        var prevKidLastLeaf: Int? = nil
        for (i, kid) in kids.enumerated() {
            let cells = assignedCells[i]
            let kidOuterW = CGFloat(cells) * cellMetrics.cellWidth + 2 * chrome.marginPt
            let kidRect = CGRect(x: x, y: rect.minY, width: kidOuterW, height: rect.height)
            let kidDims = recurse(kid, in: kidRect, cellMetrics: cellMetrics, chrome: chrome, leaves: &leaves, dividers: &dividers)
            totalCols += kidDims.cols
            maxRows = max(maxRows, kidDims.rows)
            // Divider between this kid and the previous one — using
            // the leaves we just appended to pick reference pane ids.
            if i > 0, let before = prevKidLastLeaf, let after = kid.paneIDs.first {
                let borderCenterX = x - chrome.borderPt / 2
                dividers.append(EngineDivider(
                    axis: .vertical,
                    hitRect: CGRect(
                        x: borderCenterX - 4,
                        y: rect.minY,
                        width: 8 + chrome.borderPt,
                        height: rect.height
                    ),
                    beforePaneID: before,
                    afterPaneID: after
                ))
            }
            prevKidLastLeaf = kid.paneIDs.last
            x += kidOuterW + (i < n - 1 ? chrome.borderPt : 0)
        }
        // tmux's logical border between siblings is 1 cell (always),
        // even though we render it as `borderPt`. So the window-cell
        // count for this subtree is (sum of pane cells) + (N-1).
        return (totalCols + (n - 1), maxRows)
    }

    private static func layoutVertical(
        kids: [LayoutCellNode],
        rect: CGRect,
        cellMetrics: CellMetrics,
        chrome: LayoutChrome,
        leaves: inout [PaneFinalLayout],
        dividers: inout [EngineDivider]
    ) -> (cols: Int, rows: Int) {
        let n = kids.count
        guard n > 0 else { return (0, 0) }
        // (N-1) visual borders + 2N margins + N control panels.
        // tmux's *logical* row-border is 1 cell — see the return
        // value below.
        let chromeH = CGFloat(n - 1) * chrome.borderPt
                    + CGFloat(2 * n) * chrome.marginPt
                    + CGFloat(n) * chrome.controlPanelPt
        let availableH = max(0, rect.height - chromeH)
        let weightRows = kids.reduce(0) { $0 + $1.rows }
        guard weightRows > 0 else { return (0, 0) }

        var assignedCells: [Int] = []
        assignedCells.reserveCapacity(n)
        var cellsAssignedSoFar = 0
        for (i, kid) in kids.enumerated() {
            let cells: Int
            if i == n - 1 {
                let remainingPt = availableH - CGFloat(cellsAssignedSoFar) * cellMetrics.cellHeight
                cells = max(0, Int((remainingPt / cellMetrics.cellHeight).rounded(.down)))
            } else {
                let rate = Double(kid.rows) / Double(weightRows)
                let pt = Double(availableH) * rate
                cells = max(0, Int((pt / Double(cellMetrics.cellHeight)).rounded()))
                cellsAssignedSoFar += cells
            }
            assignedCells.append(cells)
        }

        var y = rect.minY
        var maxCols = 0
        var totalRows = 0
        var prevKidLastLeaf: Int? = nil
        for (i, kid) in kids.enumerated() {
            let cells = assignedCells[i]
            let kidOuterH = CGFloat(cells) * cellMetrics.cellHeight
                          + chrome.controlPanelPt
                          + 2 * chrome.marginPt
            let kidRect = CGRect(x: rect.minX, y: y, width: rect.width, height: kidOuterH)
            let kidDims = recurse(kid, in: kidRect, cellMetrics: cellMetrics, chrome: chrome, leaves: &leaves, dividers: &dividers)
            maxCols = max(maxCols, kidDims.cols)
            totalRows += kidDims.rows
            if i > 0, let before = prevKidLastLeaf, let after = kid.paneIDs.first {
                let borderCenterY = y - chrome.borderPt / 2
                dividers.append(EngineDivider(
                    axis: .horizontal,
                    hitRect: CGRect(
                        x: rect.minX,
                        y: borderCenterY - 4,
                        width: rect.width,
                        height: 8 + chrome.borderPt
                    ),
                    beforePaneID: before,
                    afterPaneID: after
                ))
            }
            prevKidLastLeaf = kid.paneIDs.last
            y += kidOuterH + (i < n - 1 ? chrome.borderPt : 0)
        }
        // tmux's logical between-rows border is 1 cell each.
        return (maxCols, totalRows + (n - 1))
    }

    // MARK: - Minimum-cell enforcement (no redistribution yet)

    /// Mark any pane whose apportioned cell count fell below the
    /// minimum as hidden. The cell counts themselves are *not*
    /// clamped — we send the engine's natural output to tmux and
    /// let tmux's own minimums apply. The hidden flag is a
    /// rendering-only decision: `SessionView` skips mounting a
    /// SwiftTermView for hidden panes, but the per-pane driver keeps
    /// buffering bytes so the pane comes back instantly when room
    /// opens up.
    private static func enforceMinimums(_ layouts: [PaneFinalLayout]) -> [PaneFinalLayout] {
        layouts.map { p in
            if p.cellCols < minCols || p.cellRows < minRows {
                return PaneFinalLayout(
                    paneID: p.paneID,
                    cellCols: p.cellCols,
                    cellRows: p.cellRows,
                    innerRect: p.innerRect,
                    outerRect: p.outerRect,
                    hidden: true
                )
            }
            return p
        }
    }
}
#endif
