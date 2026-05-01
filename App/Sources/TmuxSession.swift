import Foundation
import Observation
import TmuxCC
import TerminalKit

/// One tmux window as we know about it from the `-CC` event stream.
struct TmuxWindow: Identifiable {
    let id: Int
    var name: String?
    var activePaneID: Int?
    var layoutFlags: String?
    var layout: TmuxLayout?
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

    /// Most recent control-mode lines (events + outgoing commands) for
    /// the on-screen debug log. NOT observed — appending used to
    /// trigger a SwiftUI body re-evaluation, which (combined with
    /// any `logDebug` call from inside `updateUIView`) created an
    /// infinite render loop. The overlay reads this snapshot but
    /// doesn't auto-refresh; callers can re-open it to see the
    /// latest tail.
    @ObservationIgnored
    var debugLog: [String] = []
    private static let debugLogCapacity = 30

    /// Append one entry to the debug log, trimming the head when full.
    /// Also mirrors to the on-disk `FileLogger` so we can ship a full
    /// trace home for debugging.
    func logDebug(_ line: String) {
        debugLog.append(line)
        if debugLog.count > Self.debugLogCapacity {
            debugLog.removeFirst(debugLog.count - Self.debugLogCapacity)
        }
        FileLogger.shared.log(line)
    }

    /// State for a single in-flight `runCommand` call.
    ///
    /// We don't try to match `%begin/%end` brackets — that race-loses
    /// against tmux's own bracketed pairs (e.g. for the implicit
    /// attach) and gets worse on slow links. Instead we append a
    /// `display-message -p '<UUID>'` after the user's command, then
    /// collect every `responseLine` until the UUID line appears.
    /// Whatever was buffered before the marker is the answer. tmux's
    /// own bracketed pairs emit no response lines, so they pass
    /// through harmlessly.
    @ObservationIgnored
    private var pending: PendingCommand?

    /// Tail of the in-flight command chain. Each new `runCommand`
    /// awaits the previous task's completion before claiming
    /// `pending`, which serialises commands without exposing a
    /// `.busy` error to callers.
    @ObservationIgnored
    private var lastCommandTask: Task<[String], Error>?

    private struct PendingCommand {
        let marker: String
        let continuation: CheckedContinuation<[String], Error>
        var lines: [String] = []
    }

    enum CommandError: Error {
        case streamClosed
    }

    /// Returns the driver for `paneID`, or `nil` if we haven't seen
    /// any output from that pane yet.
    func driver(for paneID: Int) -> TerminalDriver? {
        drivers[paneID]
    }

    /// Optimistically set the active pane of `windowID` without
    /// waiting for tmux's `%window-pane-changed`. Used when the user
    /// taps an "inactive" pane in the UI; tmux may not always reply
    /// (if it considers the pane already active server-side), so
    /// without this our overlay would keep stealing taps.
    func setActivePane(_ paneID: Int, in windowID: Int) {
        updateWindow(windowID) { $0.activePaneID = paneID }
    }

    /// Find which window currently owns `paneID`. Used to label
    /// transcript filenames so you can tell pane 12 of window @5
    /// from pane 12 of window @9.
    ///
    /// Two paths because layout vs output events race on attach:
    ///   1. `%layout-change` already arrived → walk `layout.paneIDs`.
    ///   2. Layout missing but `%output` set `activePaneID` via the
    ///      bootstrap heuristic in `handle(.output)` → match that.
    /// Returns `nil` only when neither has placed the pane yet.
    func windowID(forPane paneID: Int) -> Int? {
        for w in windows {
            if let layout = w.layout, layout.paneIDs.contains(paneID) {
                return w.id
            }
            if w.activePaneID == paneID {
                return w.id
            }
        }
        return nil
    }

    /// Send a tmux control-mode command and await its response lines.
    /// `command` must end with a newline. Caller supplies the writer
    /// closure (the SSH shell) so this stays free of SSHCore deps.
    ///
    /// We piggy-back a `display-message -p '<UUID>'` so we can detect
    /// the end of *our* response purely by content, immune to phantom
    /// `%begin/%end` pairs and to network latency.
    func runCommand(
        _ command: String,
        write: @escaping (Data) async throws -> Void
    ) async throws -> [String] {
        // Wait for the previous command (if any) to finish before
        // claiming `pending`. Failures of earlier commands don't
        // block subsequent ones.
        let previous = lastCommandTask
        let task = Task<[String], Error> { [weak self] in
            _ = try? await previous?.value
            guard let self else { throw CommandError.streamClosed }
            return try await self.executeCommand(command, write: write)
        }
        lastCommandTask = task
        return try await task.value
    }

    @MainActor
    private func executeCommand(
        _ command: String,
        write: @escaping (Data) async throws -> Void
    ) async throws -> [String] {
        let marker = "TMUX_CMD_MARKER_\(UUID().uuidString)"
        let combined = command + "display-message -p '\(marker)'\n"
        return try await withCheckedThrowingContinuation { cont in
            pending = PendingCommand(marker: marker, continuation: cont)
            Task {
                do {
                    try await write(Data(combined.utf8))
                } catch {
                    if let p = pending {
                        pending = nil
                        p.continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Bootstrap snapshot for a single window pulled out of
    /// `list-windows`. tmux `-CC` does not push `%window-add` for
    /// windows that already existed at attach time, so we have to
    /// enumerate them ourselves.
    struct WindowSnapshot {
        var id: Int
        var name: String?
        var isActive: Bool
        var layout: String?     // raw layout string from `#{window_layout}`
    }

    /// Remove a window from local state immediately, without waiting
    /// for tmux's `%window-close`. We do this when the user kills a
    /// window via the X button or Cmd+Shift+W: if the window was
    /// already gone server-side, no `%window-close` will arrive and
    /// we'd be stuck showing a ghost tab. Also cleans up pane state
    /// for panes that don't belong to any other window.
    func removeWindow(id: Int) {
        guard let idx = windows.firstIndex(where: { $0.id == id }) else { return }
        logDebug("removeWindow @\(id) (active was \(String(describing: activeWindowID)))")
        let removed = windows.remove(at: idx)
        if let layout = removed.layout {
            let stillUsed = Set(windows.flatMap { $0.layout?.paneIDs ?? [] })
            for paneID in layout.paneIDs where !stillUsed.contains(paneID) {
                drivers.removeValue(forKey: paneID)
                paneIDs.removeAll(where: { $0 == paneID })
            }
        }
        if activeWindowID == id {
            activeWindowID = windows.first?.id
        }
    }

    /// Drop window/pane/driver state but keep the SSH-level
    /// `isAttached` + `sessionID`/`sessionName` flags. Used after
    /// `switch-client`, where the control channel stays up but the
    /// active session — and therefore the window/pane set — changes.
    func clearForSessionSwitch() {
        logDebug("clearForSessionSwitch (was active=\(String(describing: activeWindowID)))")
        windows = []
        activeWindowID = nil
        paneIDs = []
        drivers = [:]
    }

    /// Apply a bootstrapped window snapshot to the model. Idempotent
    /// — windows we already know about are updated in place; new ones
    /// are appended in the given order.
    func bootstrap(windows snapshots: [WindowSnapshot]) {
        for snap in snapshots {
            if !windows.contains(where: { $0.id == snap.id }) {
                windows.append(TmuxWindow(id: snap.id, name: snap.name))
            } else {
                updateWindow(snap.id) { $0.name = snap.name ?? $0.name }
            }
            if snap.isActive {
                activeWindowID = snap.id
            }
            if let raw = snap.layout, let parsed = try? TmuxLayout.parse(raw) {
                updateWindow(snap.id) { $0.layout = parsed }
                for paneID in parsed.paneIDs where drivers[paneID] == nil {
                    drivers[paneID] = TerminalDriver()
                    paneIDs.append(paneID)
                }
            }
        }
    }

    /// Wipe all derived state so a fresh `-CC` stream can repopulate
    /// it. Called before reconnecting after the SSH socket dies.
    func reset() {
        logDebug("reset (was active=\(String(describing: activeWindowID)))")
        sessionID = nil
        sessionName = nil
        windows = []
        activeWindowID = nil
        isAttached = false
        lastResponseLine = nil
        paneIDs = []
        drivers = [:]
        if let p = pending {
            pending = nil
            p.continuation.resume(throwing: CommandError.streamClosed)
        }
    }

    func handle(_ event: TmuxEvent) {
        logDebug("evt: \(debugDescription(of: event))")
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

        case .windowClose(let id), .unlinkedWindowClose(let id):
            // tmux fires `%unlinked-window-close` instead of
            // `%window-close` when a window dies but wasn't in the
            // current session's link list at notification time —
            // happens at least when a tab closes while the active
            // window has already shifted away. Treat both the same.
            windows.removeAll(where: { $0.id == id })
            if activeWindowID == id {
                activeWindowID = windows.first?.id
            }

        case .windowRenamed(let id, let name):
            updateWindow(id) { $0.name = name }

        case .windowPaneChanged(let wid, let pid):
            updateWindow(wid) { $0.activePaneID = pid }

        case .layoutChange(let wid, let layoutString, _, let flags):
            let parsed = try? TmuxLayout.parse(layoutString)
            updateWindow(wid) {
                $0.layoutFlags = flags
                $0.layout = parsed
            }
            // Pre-create drivers + register paneIDs for any leaves we
            // haven't seen output from yet, so SwiftUI can mount the
            // SwiftTermView ahead of the first byte arriving.
            if let parsed {
                for paneID in parsed.paneIDs where drivers[paneID] == nil {
                    drivers[paneID] = TerminalDriver()
                    paneIDs.append(paneID)
                }
            }

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

        case .begin, .end, .responseError:
            // Marker-based matching: brackets are noise. Any `%begin`
            // that arrives between us writing the command and tmux
            // finishing the marker query just falls through here.
            break

        case .responseLine(let line):
            if let p = pending {
                if line == p.marker {
                    pending = nil
                    p.continuation.resume(returning: p.lines)
                } else {
                    pending?.lines.append(line)
                }
            } else {
                lastResponseLine = line
            }

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

        case .sessionsChanged,
             .unlinkedWindowAdd, .unlinkedWindowRenamed,
             .paneModeChanged, .clientSessionChanged,
             .subscriptionChanged, .pause, .continuePane,
             .unknown:
            break
        }
    }

    /// Compact event description for the debug log. We don't want to
    /// dump pane payloads (kilobytes per `%output`) into the overlay.
    private func debugDescription(of event: TmuxEvent) -> String {
        switch event {
        case .dcsBegin: return "dcsBegin"
        case .dcsEnd: return "dcsEnd"
        case .begin(_, let n, _): return "begin #\(n)"
        case .end(_, let n, _): return "end #\(n)"
        case .responseError(_, let n, _): return "responseError #\(n)"
        case .responseLine(let line):
            return "responseLine: \(line.prefix(60))"
        case .output(let pid, let data):
            return "output %\(pid) (\(data.count)B)"
        case .sessionChanged(let id, let name): return "sessionChanged $\(id) \(name)"
        case .sessionRenamed(let id, let name): return "sessionRenamed $\(id) \(name)"
        case .sessionsChanged: return "sessionsChanged"
        case .sessionWindowChanged(let s, let w): return "sessionWindowChanged $\(s) @\(w)"
        case .windowAdd(let w): return "windowAdd @\(w)"
        case .windowClose(let w): return "windowClose @\(w)"
        case .windowRenamed(let w, let name): return "windowRenamed @\(w) \(name)"
        case .windowPaneChanged(let w, let p): return "windowPaneChanged @\(w) %\(p)"
        case .layoutChange(let w, let layout, _, _):
            return "layoutChange @\(w) \(layout.prefix(40))"
        case .unlinkedWindowAdd(let w): return "unlinkedWindowAdd @\(w)"
        case .unlinkedWindowClose(let w): return "unlinkedWindowClose @\(w)"
        case .unlinkedWindowRenamed(let w, _): return "unlinkedWindowRenamed @\(w)"
        case .paneModeChanged(let p): return "paneModeChanged %\(p)"
        case .clientSessionChanged(let c, let s, let n): return "clientSessionChanged \(c) $\(s) \(n)"
        case .subscriptionChanged(let raw): return "subscriptionChanged \(raw.prefix(40))"
        case .pause(let p): return "pause %\(p)"
        case .continuePane(let p): return "continuePane %\(p)"
        case .exit(let r): return "exit \(r ?? "")"
        case .unknown(let raw): return "unknown: \(raw.prefix(60))"
        }
    }

    private func updateWindow(_ id: Int, _ mutate: (inout TmuxWindow) -> Void) {
        guard let idx = windows.firstIndex(where: { $0.id == id }) else { return }
        var w = windows[idx]
        mutate(&w)
        windows[idx] = w
    }
}
