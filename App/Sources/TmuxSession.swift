import Foundation
import Observation
import TmuxCC

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
/// Step B scope: tracks session identity, window list, active window,
/// attach state. Per-pane buffers and selection routing arrive in
/// step B'.
@Observable
final class TmuxSession {
    var sessionID: Int?
    var sessionName: String?
    var windows: [TmuxWindow] = []
    var activeWindowID: Int?
    var isAttached: Bool = false

    /// Last `responseLine` we saw bracketed by `%begin`/`%error` —
    /// useful for surfacing tmux's own error text to the user
    /// (e.g. "duplicate session: …").
    var lastResponseLine: String?

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

        case .responseLine(let line):
            lastResponseLine = line

        case .begin, .end, .responseError,
             .output, .sessionsChanged, .sessionWindowChanged,
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
