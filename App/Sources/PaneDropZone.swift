#if canImport(UIKit)
import SwiftUI
import CoreGraphics

/// SwiftUI overlay that turns a pane into a drop target for
/// pane-to-pane drag-and-drop.
///
/// **Why four strips and not one big drop destination?**
/// SwiftUI's `.dropDestination(isTargeted:)` is binary — it can't
/// tell us *where* in the view the cursor is during hover. To get
/// iTerm2-style live "which half of the target will be split"
/// feedback, we lay out four small drop zones around the edges
/// (top / bottom / left / right). As the user drags toward an
/// edge, that strip's `isTargeted` fires; we render a translucent
/// half-pane overlay matching the strip's edge so the user sees
/// the result before releasing.
///
/// The middle of the pane is intentionally *not* a drop target —
/// strip-only coverage means the SwiftUI views in the middle
/// (the terminal, the tap-to-select shim) keep receiving normal
/// touches without any hit-test tricks. The user has to drag
/// near an edge for the drop to register; the edges are 30% of
/// each axis so the targets are forgiving.
///
/// **Tap-to-select:** strips have `.contentShape(Rectangle())` so
/// drag/drop hit-testing works. To keep the iPad UX of "tap
/// anywhere on a pane to focus it", strips also carry a
/// `.simultaneousGesture(TapGesture())` that calls `onTap` —
/// that fires only on a quick tap (drag is a separate gesture
/// path, so it doesn't interfere). Taps on the dead center fall
/// straight through to the underlying `Color.clear` tap shim in
/// `paneCell`, completing the "tap anywhere" coverage.
///
/// **Drag payload format** matches the existing tab-drop wiring:
/// `"pane:%<id>"` (see DemoSessionView's `paneControlBar`'s
/// `.draggable`). Self-drops are rejected.
struct PaneDropZone: View {
    let targetPaneID: Int
    let onDrop: (Int, PaneDropEdge) -> Void
    let onTap: () -> Void

    @State private var hoverEdge: PaneDropEdge?

    private static let edgeFraction: CGFloat = 0.30

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let edge = hoverEdge {
                    halfHighlight(edge: edge, in: geo.size)
                        .allowsHitTesting(false)
                }

                VStack(spacing: 0) {
                    dropStrip(edge: .top)
                        .frame(height: geo.size.height * Self.edgeFraction)
                    HStack(spacing: 0) {
                        dropStrip(edge: .left)
                            .frame(width: geo.size.width * Self.edgeFraction)
                        // Dead center — Color.clear with no
                        // contentShape, so taps pass through to the
                        // underlying tap-to-select shim or terminal.
                        Color.clear
                            .frame(maxWidth: .infinity)
                        dropStrip(edge: .right)
                            .frame(width: geo.size.width * Self.edgeFraction)
                    }
                    .frame(maxHeight: .infinity)
                    dropStrip(edge: .bottom)
                        .frame(height: geo.size.height * Self.edgeFraction)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func dropStrip(edge: PaneDropEdge) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                FileLogger.shared.log(
                    "Demo: dropZone[%\(targetPaneID)] perform edge=\(edge) items=\(items.count)"
                )
                hoverEdge = nil
                for item in items {
                    guard item.hasPrefix("pane:%"),
                          let pid = Int(item.dropFirst("pane:%".count))
                    else { continue }
                    if pid == targetPaneID {
                        FileLogger.shared.log("Demo: dropZone[%\(targetPaneID)] self-drop ignored")
                        return false
                    }
                    FileLogger.shared.log("Demo: drop pane %\(pid) → %\(targetPaneID) edge=\(edge)")
                    onDrop(pid, edge)
                    return true
                }
                return false
            } isTargeted: { hovering in
                FileLogger.shared.log(
                    "Demo: dropZone[%\(targetPaneID)] edge=\(edge) isTargeted=\(hovering)"
                )
                if hovering {
                    hoverEdge = edge
                } else if hoverEdge == edge {
                    hoverEdge = nil
                }
            }
            // Quick tap on a strip should also count as a tap on
            // the pane (otherwise the edges become "dead" for the
            // tap-to-select gesture). `.simultaneousGesture` keeps
            // the strip's drop interaction intact — drops use a
            // long-press path, taps use a separate quick-tap path.
            .simultaneousGesture(
                TapGesture().onEnded { onTap() }
            )
    }

    @ViewBuilder
    private func halfHighlight(edge: PaneDropEdge, in size: CGSize) -> some View {
        let fill = Color.accentColor.opacity(0.32)
        let stroke = Color.accentColor.opacity(0.85)
        switch edge {
        case .top:
            VStack(spacing: 0) {
                halfRect(fill: fill, stroke: stroke)
                    .frame(height: size.height / 2)
                Spacer(minLength: 0)
            }
        case .bottom:
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                halfRect(fill: fill, stroke: stroke)
                    .frame(height: size.height / 2)
            }
        case .left:
            HStack(spacing: 0) {
                halfRect(fill: fill, stroke: stroke)
                    .frame(width: size.width / 2)
                Spacer(minLength: 0)
            }
        case .right:
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                halfRect(fill: fill, stroke: stroke)
                    .frame(width: size.width / 2)
            }
        }
    }

    private func halfRect(fill: Color, stroke: Color) -> some View {
        Rectangle()
            .fill(fill)
            .overlay(Rectangle().stroke(stroke, lineWidth: 2))
    }
}
#endif
