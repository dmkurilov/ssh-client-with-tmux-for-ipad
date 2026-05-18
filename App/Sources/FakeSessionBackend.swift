#if canImport(UIKit)
import Foundation

/// In-memory `SessionBackend` whose panes are `EchoPaneBackend`s.
/// Used by the demo entry in Settings, by SwiftUI previews, and by
/// snapshot tests. Bytes never leave the device — the "remote" is
/// a 1s timer.
///
/// State mutations happen synchronously on the main actor; views
/// see them via the `@Observable` `SessionState`. Every public
/// command is logged at `FileLogger` level so a debug.log of a
/// demo session is enough to replay user actions, matching the
/// project's debug-log policy.
@MainActor
final class FakeSessionBackend: SessionBackend {
    let state = SessionState()
    private var panes: [Int: EchoPaneBackend] = [:]
    private var nextPaneID: Int
    private var nextWindowID: Int
    private let echoDelay: Duration

    /// Build a fake with one window of `paneCount` echo panes.
    /// The first pane is active. Initial panes are arranged
    /// side-by-side at the root.
    init(echoDelay: Duration = .seconds(1), paneCount: Int = 2) {
        self.echoDelay = echoDelay
        self.nextPaneID = 1
        self.nextWindowID = 1
        FileLogger.shared.log("FakeSession init delay=\(echoDelay) paneCount=\(paneCount)")
        let initialPaneIDs = (0..<max(paneCount, 1)).map { _ in newPaneID() }
        for pid in initialPaneIDs {
            panes[pid] = EchoPaneBackend(id: pid, echoDelay: echoDelay)
        }
        let layout: PaneNode
        if initialPaneIDs.count == 1 {
            layout = .leaf(paneID: initialPaneIDs[0])
        } else {
            layout = .split(
                direction: .horizontal,
                children: initialPaneIDs.map { .leaf(paneID: $0) }
            )
        }
        let win = WindowInfo(
            id: newWindowID(),
            name: "demo",
            layout: layout,
            cellTree: LayoutCellNode.defaultTree(from: layout),
            activePaneID: initialPaneIDs.first
        )
        state.sessionName = "demo"
        state.sessionID = 0
        state.windows = [win]
        state.activeWindowID = win.id
        state.isAttached = true
    }

    func pane(_ id: Int) -> PaneBackend? {
        panes[id]
    }

    func disconnect() async {
        FileLogger.shared.log("FakeSession.disconnect")
        panes.removeAll()
        state.windows = []
        state.activeWindowID = nil
        state.isAttached = false
    }

    // MARK: - Commands

    func splitPane(direction: SplitDirection, target: Int) async {
        guard let widx = state.windows.firstIndex(where: { $0.paneIDs.contains(target) }) else {
            FileLogger.shared.log("FakeSession.splitPane target=%\(target) — no window")
            return
        }
        let newPID = newPaneID()
        panes[newPID] = EchoPaneBackend(id: newPID, echoDelay: echoDelay)
        var win = state.windows[widx]
        // The leaf for `target` becomes a 2-child split containing
        // the original target plus the new pane — leaves siblings
        // alone. iTerm2-style nesting falls out of repeated splits.
        win.layout = win.layout.splitting(target: target, direction: direction, newID: newPID)
        // Mutate cellTree by splitting *just* the target leaf, so
        // sibling cell counts are preserved. Falls back to a fresh
        // defaultTree only if cellTree is somehow missing.
        if let tree = win.cellTree {
            win.cellTree = tree.splittingPane(target: target, direction: direction, newID: newPID)
        } else {
            win.cellTree = LayoutCellNode.defaultTree(from: win.layout)
        }
        win.activePaneID = newPID
        state.windows[widx] = win
        FileLogger.shared.log("FakeSession.splitPane \(direction) target=%\(target) → new=%\(newPID)")
    }

    func killPane(_ paneID: Int) async {
        FileLogger.shared.log("FakeSession.killPane %\(paneID)")
        panes.removeValue(forKey: paneID)
        // Walk windows in reverse so removing one doesn't shift
        // earlier indices we haven't visited yet.
        for i in state.windows.indices.reversed() where state.windows[i].paneIDs.contains(paneID) {
            var w = state.windows[i]
            if let pruned = w.layout.removingPane(paneID) {
                w.layout = pruned
                w.cellTree = w.cellTree?.removingPane(paneID)
                    ?? LayoutCellNode.defaultTree(from: pruned)
                if w.activePaneID == paneID {
                    w.activePaneID = pruned.allPaneIDs.first
                }
                state.windows[i] = w
            } else {
                state.windows.remove(at: i)
            }
        }
        if !state.windows.contains(where: { $0.id == state.activeWindowID }) {
            state.activeWindowID = state.windows.first?.id
        }
        if state.zoomedPaneID == paneID {
            state.zoomedPaneID = nil
        }
    }

    func selectPane(_ paneID: Int) async {
        FileLogger.shared.log("FakeSession.selectPane %\(paneID)")
        guard let widx = state.windows.firstIndex(where: { $0.paneIDs.contains(paneID) }) else { return }
        state.windows[widx].activePaneID = paneID
        state.activeWindowID = state.windows[widx].id
    }

    func newWindow() async {
        let pid = newPaneID()
        panes[pid] = EchoPaneBackend(id: pid, echoDelay: echoDelay)
        let wid = newWindowID()
        let leaf: PaneNode = .leaf(paneID: pid)
        let win = WindowInfo(
            id: wid,
            name: nil,
            layout: leaf,
            cellTree: LayoutCellNode.defaultTree(from: leaf),
            activePaneID: pid
        )
        state.windows.append(win)
        state.activeWindowID = wid
        FileLogger.shared.log("FakeSession.newWindow → @\(wid) pane=%\(pid)")
    }

    func selectWindow(_ windowID: Int) async {
        guard state.windows.contains(where: { $0.id == windowID }) else { return }
        state.activeWindowID = windowID
        FileLogger.shared.log("FakeSession.selectWindow @\(windowID)")
    }

    func killWindow(_ windowID: Int) async {
        FileLogger.shared.log("FakeSession.killWindow @\(windowID)")
        guard let widx = state.windows.firstIndex(where: { $0.id == windowID }) else { return }
        for pid in state.windows[widx].paneIDs {
            panes.removeValue(forKey: pid)
        }
        state.windows.remove(at: widx)
        if state.activeWindowID == windowID {
            state.activeWindowID = state.windows.first?.id
        }
    }

    func renameWindow(_ windowID: Int, name: String) async {
        FileLogger.shared.log("FakeSession.renameWindow @\(windowID) → \(name)")
        if let idx = state.windows.firstIndex(where: { $0.id == windowID }) {
            state.windows[idx].name = name
        }
    }

    func renameSession(_ newName: String) async {
        FileLogger.shared.log("FakeSession.renameSession → \(newName)")
        state.sessionName = newName
    }

    func resizePane(_ paneID: Int, direction: ResizeDirection, cells: Int) async {
        guard cells != 0 else { return }
        guard let widx = state.windows.firstIndex(where: { $0.paneIDs.contains(paneID) }) else { return }
        var win = state.windows[widx]
        guard let tree = win.cellTree else { return }
        let newTree = tree.resizingPane(paneID, direction: direction, cells: cells)
        win.cellTree = newTree
        state.windows[widx] = win
        FileLogger.shared.log("FakeSession.resizePane %\(paneID) \(direction) \(cells)")
    }

    func applyPaneLayout(_ entries: [(paneID: Int, cols: Int, rows: Int)]) async {
        // Translate absolute (cols, rows) targets into signed deltas
        // and apply each via the cellTree's `resizingPane`. The
        // direction we pick is arbitrary among the four — the walk
        // inside `resizingPane` climbs to the first ancestor split
        // whose axis matches and which has a sibling in the
        // requested direction, so .right / .down do the right thing
        // even for panes at the right/bottom edge.
        for entry in entries {
            guard let widx = state.windows.firstIndex(where: { $0.paneIDs.contains(entry.paneID) }) else { continue }
            var win = state.windows[widx]
            guard let tree = win.cellTree else { continue }
            let current = Self.findLeafSize(in: tree, paneID: entry.paneID)
            let deltaCols = entry.cols - (current?.cols ?? entry.cols)
            let deltaRows = entry.rows - (current?.rows ?? entry.rows)
            var newTree = tree
            if deltaCols != 0 {
                newTree = newTree.resizingPane(entry.paneID, direction: .right, cells: deltaCols)
            }
            if deltaRows != 0 {
                newTree = newTree.resizingPane(entry.paneID, direction: .down, cells: deltaRows)
            }
            win.cellTree = newTree
            state.windows[widx] = win
        }
        FileLogger.shared.log("FakeSession.applyPaneLayout entries=\(entries.count)")
    }

    /// Walk the cell tree to find a leaf's current cell size. Used by
    /// `applyPaneLayout` to compute the signed delta for an absolute
    /// resize target.
    private static func findLeafSize(in tree: LayoutCellNode, paneID: Int) -> (cols: Int, rows: Int)? {
        switch tree.kind {
        case .leaf(let pid):
            return pid == paneID ? (tree.cols, tree.rows) : nil
        case .horizontal(let kids), .vertical(let kids):
            for kid in kids {
                if let found = findLeafSize(in: kid, paneID: paneID) {
                    return found
                }
            }
            return nil
        }
    }

    func paneTitle(_ paneID: Int) -> String? {
        guard panes[paneID] != nil else { return nil }
        return "echo pane %\(paneID) — \(echoDelay) round-trip"
    }

    func toggleZoom(paneID: Int) async {
        // Only zoom panes that exist. Toggling on the same pane
        // un-zooms; toggling on a different pane swaps the zoom
        // target — matches tmux's behaviour where `resize-pane -Z`
        // is per-window-active.
        guard panes[paneID] != nil else { return }
        if state.zoomedPaneID == paneID {
            state.zoomedPaneID = nil
        } else {
            state.zoomedPaneID = paneID
        }
        FileLogger.shared.log(
            "FakeSession.toggleZoom %\(paneID) → \(state.zoomedPaneID.map { "%\($0)" } ?? "off")"
        )
    }

    func movePane(paneID: Int, toWindow windowID: Int) async {
        FileLogger.shared.log("FakeSession.movePane %\(paneID) → @\(windowID)")
        // Validate both endpoints exist and are different.
        guard state.windows.contains(where: { $0.paneIDs.contains(paneID) }),
              state.windows.contains(where: { $0.id == windowID }),
              !(state.windows.first { $0.id == windowID }?.paneIDs.contains(paneID) ?? false)
        else { return }

        // 1. Remove from the source window. If that empties the
        //    window, drop it — tmux does the same.
        for i in state.windows.indices.reversed() where state.windows[i].paneIDs.contains(paneID) {
            var w = state.windows[i]
            if let pruned = w.layout.removingPane(paneID) {
                w.layout = pruned
                w.cellTree = LayoutCellNode.defaultTree(from: pruned)
                if !pruned.allPaneIDs.contains(w.activePaneID ?? -1) {
                    w.activePaneID = pruned.allPaneIDs.first
                }
                state.windows[i] = w
            } else {
                FileLogger.shared.log("FakeSession.movePane: pruned empty window @\(w.id)")
                state.windows.remove(at: i)
            }
            break
        }

        // 2. Re-find the destination — its index may have shifted
        //    if a source window was removed before it.
        guard let dstIdx = state.windows.firstIndex(where: { $0.id == windowID }) else { return }
        var dst = state.windows[dstIdx]
        // Append the moved pane on the right at the root. A future
        // version could let the user pick the drop position; for the
        // demo, "drop on tab" = "add to that tab's right edge."
        dst.layout = .split(
            direction: .horizontal,
            children: [dst.layout, .leaf(paneID: paneID)]
        )
        dst.cellTree = LayoutCellNode.defaultTree(from: dst.layout)
        dst.activePaneID = paneID
        state.windows[dstIdx] = dst
        state.activeWindowID = windowID

        // tmux clears the zoom flag on layout-changing operations.
        if state.zoomedPaneID == paneID {
            state.zoomedPaneID = nil
        }
    }

    func movePane(paneID: Int, toPane targetID: Int, edge: PaneDropEdge) async {
        FileLogger.shared.log("FakeSession.movePane %\(paneID) → %\(targetID) edge=\(edge)")
        guard paneID != targetID else { return }
        guard panes[paneID] != nil, panes[targetID] != nil else { return }

        // 1. Remove source from its current window. If it empties
        //    the window, drop the window — same rule as the
        //    tab-target movePane variant.
        for i in state.windows.indices.reversed() where state.windows[i].paneIDs.contains(paneID) {
            var w = state.windows[i]
            if let pruned = w.layout.removingPane(paneID) {
                w.layout = pruned
                w.cellTree = LayoutCellNode.defaultTree(from: pruned)
                if !pruned.allPaneIDs.contains(w.activePaneID ?? -1) {
                    w.activePaneID = pruned.allPaneIDs.first
                }
                state.windows[i] = w
            } else {
                FileLogger.shared.log("FakeSession.movePane: pruned empty window @\(w.id)")
                state.windows.remove(at: i)
            }
            break
        }

        // 2. Find target's window (post-source-removal) and replace
        //    its leaf with a 2-child split holding source+target on
        //    the requested edge.
        guard let dstIdx = state.windows.firstIndex(where: { $0.paneIDs.contains(targetID) })
        else { return }
        var dst = state.windows[dstIdx]
        let direction: SplitDirection = (edge == .top || edge == .bottom) ? .vertical : .horizontal
        let sourceFirst = (edge == .top || edge == .left)
        let children: [PaneNode] = sourceFirst
            ? [.leaf(paneID: paneID), .leaf(paneID: targetID)]
            : [.leaf(paneID: targetID), .leaf(paneID: paneID)]
        let replacement: PaneNode = .split(direction: direction, children: children)
        dst.layout = dst.layout.replacingLeaf(target: targetID, with: replacement)
        dst.cellTree = LayoutCellNode.defaultTree(from: dst.layout)
        dst.activePaneID = paneID
        state.windows[dstIdx] = dst
        state.activeWindowID = dst.id

        // tmux clears the zoom flag on layout-changing operations.
        if state.zoomedPaneID == paneID || state.zoomedPaneID == targetID {
            state.zoomedPaneID = nil
        }
    }

    // MARK: - ID minting

    private func newPaneID() -> Int {
        defer { nextPaneID += 1 }
        return nextPaneID
    }

    private func newWindowID() -> Int {
        defer { nextWindowID += 1 }
        return nextWindowID
    }
}
#endif
