import Foundation
import Observation
import TmuxCC
import TerminalKit

/// One tmux window as we know about it from the `-CC` event stream.
struct TmuxWindow: Identifiable, Hashable {
    let id: Int
    var name: String?
    var activePaneID: Int?
    var layoutFlags: String?
}

/// Observable model derived from a `[TmuxEvent]` stream. Feed it
/// events with `handle(_:)`; SwiftUI views observe its properties via
/// the Observation framework.
///
/// Per-pane `TerminalDriver`s are kept in a non-observed dict; new
/// `paneID`s are appended to the observed `paneIDs` array so the
/// view can react and SwiftUI gets a stable identity per pane.
///
/// `@MainActor` because `TerminalDriver` is — pane writes go straight
/// into a `SwiftTerm.TerminalView` on the main thread.
@MainActor
@Observable
final class TmuxSession {
    var sessionID: Int?
    var sessionName: String?
    var windows: [TmuxWindow] = []
    var activeWindowID: Int?
    var isAttached: Bool = false
    var lastResponseLine: String?

    /// Pane IDs in first-seen order. Observed so SwiftUI's `ForEach`
    /// can mount/unmount per-pane views.
    var paneIDs: [Int] = []

    /// Per-pane terminal drivers. Stable handles — fed bytes in
    /// place, never replaced.
    @ObservationIgnored
    private var drivers: [Int: TerminalDriver] = [:]

    /// Returns the driver for `paneID`, or `nil` if we haven't seen
    /// any output from that pane yet.
    func driver(for paneID: Int) -> TerminalDriver? {
        drivers[paneID]
    }

    func handle(_ event: TmuxEvent) {
        switch event {
        case .dcsBegin:
            isAttached = true

        case .dcsEnd, .exit:
            isAttached = false

        case .windowAdd(let id):
            if !windows.contains(where: { $0.id == id }) {
                windows.append(TmuxWindow(id: id))
            }
            if activeWindowID == nil {
                activeWindowID = id
            }

        case .windowClose(let id):
            windows.removeAll(where: { $0.id == id })
            if activeWindowID == id {
                activeWindowID = windows.first?.id
            }

        case .windowRenamed(let id, let name):
            updateWindow(id) { $0.name = name }

        case .windowPaneChanged(let wid, let pid):
            updateWindow(wid) { $0.activePaneID = pid }

        case .layoutChange(let wid, _, _, let flags):
            updateWindow(wid) { $0.layoutFlags = flags }

        case .sessionChanged(let id, let name):
            sessionID = id
            sessionName = name

        case .sessionRenamed(let id, let name):
            if sessionID == id {
                sessionName = name
            }

        case .sessionWindowChanged(let sid, let wid):
            // The session's focus moved to `wid`. We accept this even
            // before `sessionChanged` arrives — tmux is the source of
            // truth, and matching session IDs would only filter
            // multi-session edge cases we don't model yet.
            _ = sid
            activeWindowID = wid

        case .responseLine(let line):
            lastResponseLine = line

        case .output(let paneID, let data):
            let driver: TerminalDriver
            if let existing = drivers[paneID] {
                driver = existing
            } else {
                driver = TerminalDriver()
                drivers[paneID] = driver
                paneIDs.append(paneID)
            }
            driver.feed(data)

            // Bootstrap heuristic: tmux often doesn't emit
            // `windowPaneChanged` for a pane that's already active
            // when we attach. The first pane to emit output for the
            // active window claims itself as the active pane until
            // tmux says otherwise. Will be replaced by parsing
            // `layoutChange` for proper window→pane mapping.
            if let wid = activeWindowID,
               let idx = windows.firstIndex(where: { $0.id == wid }),
               windows[idx].activePaneID == nil
            {
                var w = windows[idx]
                w.activePaneID = paneID
                windows[idx] = w
            }

        case .begin, .end, .responseError,
             .sessionsChanged,
             .unlinkedWindowAdd, .unlinkedWindowClose, .unlinkedWindowRenamed,
             .paneModeChanged, .clientSessionChanged,
             .subscriptionChanged, .pause, .continuePane,
             .unknown:
            break
        }
    }

    private func updateWindow(_ id: Int, _ mutate: (inout TmuxWindow) -> Void) {
        guard let idx = windows.firstIndex(where: { $0.id == id }) else { return }
        var w = windows[idx]
        mutate(&w)
        windows[idx] = w
    }
}
