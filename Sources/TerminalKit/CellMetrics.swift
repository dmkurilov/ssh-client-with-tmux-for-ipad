#if canImport(UIKit)
import UIKit
import SwiftTerm

/// Measure the on-screen size of one terminal cell for a given
/// monospace `UIFont`. The result drives our "tmux is the source of
/// truth on grid size" architecture: we pick a font once per tab,
/// measure the cell, and from then on the tab's window grid is
/// `floor(paneAreaPoints / cellSize)`. tmux gets that grid via
/// `refresh-client -C` + `resize-window`, and every pane is rendered
/// at exactly `paneCols × cellW` × `paneRows × cellH` points — no
/// derive-cells-from-arbitrary-frame anywhere in the pipeline.
public struct CellMetrics: Equatable, @unchecked Sendable {
    public let cellWidth: CGFloat
    public let cellHeight: CGFloat
    public let font: UIFont

    /// Caller-installed logger hook. The App wires this to its
    /// `FileLogger.shared` so the one-shot measurement diagnostic
    /// lands in the same `debug.log` as the `sizeChanged` lines that
    /// will (or won't) report a `MISMATCH` afterwards.
    public static var log: ((String) -> Void)?

    public init(cellWidth: CGFloat, cellHeight: CGFloat, font: UIFont) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.font = font
    }

    /// Default font choice — monospace, regular weight, 14 pt. Matches
    /// what SwiftTerm uses out of the box, which keeps the round-trip
    /// "we measured, SwiftTerm reports back" sanity check stable.
    public static var defaultFont: UIFont {
        UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    }

    /// Measure the cell size *exactly the way SwiftTerm does*, by
    /// creating a throwaway `SwiftTerm.TerminalView` with the desired
    /// font and asking it for its optimal frame size — which is
    /// `cols × internalCellWidth` by `rows × internalCellHeight`. We
    /// divide back out by the view's current cols/rows to get the
    /// per-cell size SwiftTerm will actually render at.
    ///
    /// This sidesteps the trap we hit before: our own `"M".size(...)`
    /// + `font.ascender + |descender| + leading` measurement was 0.34
    /// pt narrower and 0.63 pt shorter than what SwiftTerm uses
    /// internally (it goes through Core Text's max-advance + its own
    /// line-stacking), producing the persistent `sizeChanged
    /// MISMATCH expected=X actual=X-3` we saw on every layout pass.
    @MainActor
    public static func measure(font: UIFont) -> CellMetrics {
        let probe = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        probe.font = font
        let optimal = probe.getOptimalFrameSize()
        let terminal = probe.getTerminal()
        let cols = max(terminal.cols, 1)
        let rows = max(terminal.rows, 1)
        let cellW = optimal.width / CGFloat(cols)
        let cellH = optimal.height / CGFloat(rows)
        // Emit once per measurement so the next debug.log shows the
        // numbers we'll be sending tmux. If SwiftTerm's `sizeChanged`
        // still reports a different grid after this, the fault is
        // somewhere other than the cell measurement.
        Self.log?("CellMetrics.measure font=\(font.fontName)@\(font.pointSize)pt → cellW=\(cellW)pt cellH=\(cellH)pt (probed cols=\(cols) rows=\(rows) optimal=\(optimal.width)x\(optimal.height)pt)")
        return CellMetrics(cellWidth: cellW, cellHeight: cellH, font: font)
    }

    /// Convenience for the default font.
    @MainActor
    public static func defaultMetrics() -> CellMetrics {
        measure(font: defaultFont)
    }

    /// Map a pixel area (in points) to a cell rectangle, flooring on
    /// both axes so we never claim a fractional cell. Caller passes
    /// the area available *inside* the chrome (after toolbar / tab
    /// strip / soft keyboard), not the raw screen.
    public func gridFitting(_ size: CGSize) -> (cols: Int, rows: Int) {
        let cols = max(0, Int((size.width / cellWidth).rounded(.down)))
        let rows = max(0, Int((size.height / cellHeight).rounded(.down)))
        return (cols, rows)
    }

    /// Inverse: how many points does an `(cols × rows)` grid occupy
    /// at this cell size. Used to build the `.frame(width:height:)`
    /// for each pane's `SwiftTermView`.
    public func points(cols: Int, rows: Int) -> CGSize {
        CGSize(
            width:  CGFloat(cols) * cellWidth,
            height: CGFloat(rows) * cellHeight
        )
    }
}
#endif
