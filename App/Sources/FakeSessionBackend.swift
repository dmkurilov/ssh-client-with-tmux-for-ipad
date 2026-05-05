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
    /// The first pane is active.
    init(echoDelay: Duration = .seconds(1), paneCount: Int = 2) {
        self.echoDelay = echoDelay
        self.nextPaneID = 1
        self.nextWindowID = 1
        FileLogger.shared.log("FakeSession init delay=\(echoDelay) paneCount=\(paneCount)")
        let initialPaneIDs = (0..<paneCount).map { _ in newPaneID() }
        for pid in initialPaneIDs {
            panes[pid] = EchoPaneBackend(id: pid, echoDelay: echoDelay)
        }
        let win = WindowInfo(
            id: newWindowID(),
            name: "demo",
            paneIDs: initialPaneIDs,
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
        // Insert just after the target so the layout reflects the
        // intended adjacency. Direction is logged but not yet used
        // to model a split tree — the demo view lays panes out
        // horizontally regardless. Real `TmuxSessionBackend` will
        // honour the direction.
        if let idx = win.paneIDs.firstIndex(of: target) {
            win.paneIDs.insert(newPID, at: idx + 1)
        } else {
            win.paneIDs.append(newPID)
        }
        win.activePaneID = newPID
        state.windows[widx] = win
        FileLogger.shared.log("FakeSession.splitPane \(direction) target=%\(target) → new=%\(newPID)")
    }

    func killPane(_ paneID: Int) async {
        FileLogger.shared.log("FakeSession.killPane %\(paneID)")
        panes.removeValue(forKey: paneID)
        for i in state.windows.indices {
            state.windows[i].paneIDs.removeAll { $0 == paneID }
            if state.windows[i].activePaneID == paneID {
                state.windows[i].activePaneID = state.windows[i].paneIDs.first
            }
        }
        // A window with no panes is gone in tmux too — drop it.
        state.windows.removeAll { $0.paneIDs.isEmpty }
        if !state.windows.contains(where: { $0.id == state.activeWindowID }) {
            state.activeWindowID = state.windows.first?.id
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
        let win = WindowInfo(id: wid, name: nil, paneIDs: [pid], activePaneID: pid)
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
