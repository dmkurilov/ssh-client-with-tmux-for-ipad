#if canImport(UIKit)
import Foundation
import SSHCore
import TmuxCC
import TerminalKit

/// `SessionBackend` implementation backed by a real tmux server
/// over SSH. Wraps the existing `TmuxSession` (events + drivers)
/// and an `SSHShellSession` (the control channel). Translates
/// `SessionBackend` verbs into tmux commands written to the
/// shell, and mirrors `TmuxSession`'s observable state into a
/// `SessionState` that the new chrome (`DemoSessionView`-style)
/// reads.
///
/// Lifecycle:
/// 1. Caller creates the backend with a fresh `TmuxSession`.
/// 2. Caller does the SSH connect + `tmux -CC attach` + parser
///    pump. After each `parser.feed(...)` event is handed to
///    `tmuxSession.handle(...)`, the caller also calls
///    `backend.didHandle(event)`. That triggers `syncState()`,
///    which mirrors tmux state into the observable `SessionState`.
/// 3. Caller sets `attachShell(_:)` once the SSH shell is open
///    so the backend can write tmux commands.
/// 4. On teardown the caller calls `disconnect()`; the backend
///    drops its references but doesn't close the shell — the
///    connection-managing view owns that.
@MainActor
final class TmuxSessionBackend: SessionBackend {
    let state = SessionState()
    let tmux: TmuxSession

    /// `SSHShellSession` is an actor. `weak` references to actors
    /// historically have edge cases, and the backend is owned by
    /// the view at the same scope as the shell — there's no retain
    /// cycle to worry about — so a strong optional is simpler and
    /// safer.
    private var shell: SSHShellSession?
    private var paneBackends: [Int: TmuxPaneBackend] = [:]

    /// Pane-title polling task. Runs `list-panes -aF "#{pane_id}\t
    /// #{pane_current_command}"` every few seconds and writes the
    /// result into `state.paneTitles`. tmux doesn't push a
    /// "pane current command changed" event, and asking on every
    /// `%output` would be needlessly chatty, so polling is the
    /// pragmatic choice. Cancelled in `disconnect()`.
    private var paneTitlePollTask: Task<Void, Never>?
    private static let paneTitlePollInterval: UInt64 = 2_500_000_000 // 2.5s

    /// Caller hook for "active pane reported a new render size."
    /// `TmuxBackendSessionView` wires this to its debounced
    /// `scheduleResize` to forward the size to tmux as a PTY
    /// resize on the SSH channel. We filter to the active pane
    /// here so background-pane size events don't shrink the
    /// session unnecessarily.
    var onActivePaneResize: ((Int, Int) -> Void)?

    init(tmux: TmuxSession) {
        self.tmux = tmux
    }

    /// Called by the connection-managing view once the SSH shell
    /// has been opened (after `tmux -CC attach`). Pane backends
    /// created before this point pick up the new shell via the
    /// closure capture.
    func attachShell(_ shell: SSHShellSession?) {
        self.shell = shell
        if shell != nil {
            startPaneTitlePolling()
        }
    }

    private func startPaneTitlePolling() {
        paneTitlePollTask?.cancel()
        paneTitlePollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollPaneTitles()
                try? await Task.sleep(nanoseconds: Self.paneTitlePollInterval)
            }
        }
    }

    /// Fetch `pane_current_command` for every pane the tmux server
    /// knows about and write the result into `state.paneTitles`.
    /// Called from the background poll task on a 2.5s cadence.
    /// Best-effort — failures (transient SSH stalls, mid-attach
    /// states, etc.) are silently skipped; the next tick retries.
    private func pollPaneTitles() async {
        guard let shell, tmux.isAttached else { return }
        // The literal `T` prefix is critical: tmux's `pane_id` is
        // formatted as `%0`, `%1`, … and `TmuxCCParser.parseLine`
        // treats any line starting with `%` as a protocol keyword
        // (so `%0\tbash` would land in `.unknown(_)` instead of
        // `.responseLine(_)`, and `runCommand` would never see it).
        // Prefixing with a non-`%` token sidesteps that without
        // touching the parser. The token is stripped below.
        let format = "T\t#{pane_id}\t#{pane_current_command}"
        do {
            let lines = try await tmux.runCommand(
                "list-panes -aF \"\(format)\"\n",
                write: { try await shell.write($0) }
            )
            var newTitles: [Int: String] = [:]
            for line in lines {
                let parts = line.split(
                    separator: "\t",
                    maxSplits: 2,
                    omittingEmptySubsequences: false
                )
                guard parts.count == 3, parts[0] == "T" else { continue }
                let raw = String(parts[1])
                guard raw.hasPrefix("%"), let pid = Int(raw.dropFirst()) else { continue }
                let cmd = String(parts[2])
                newTitles[pid] = cmd
            }
            if newTitles != state.paneTitles {
                state.paneTitles = newTitles
            }
        } catch {
            // Best-effort: a single failed poll isn't worth surfacing.
        }
    }

    /// Called after `tmuxSession.handle(event)` processes one
    /// `TmuxEvent`. Mirrors tmux's @Observable state into our
    /// `SessionState` and reconciles per-pane backends.
    func didHandle(_ event: TmuxEvent) {
        syncState()
    }

    func syncState() {
        state.sessionID = tmux.sessionID
        state.sessionName = tmux.sessionName
        state.activeWindowID = tmux.activeWindowID
        state.isAttached = tmux.isAttached

        // Rebuild WindowInfo array. Mapping is structural —
        // `TmuxLayout` (cols×rows trees) → `PaneNode` (orientation
        // tree) loses the proportional sizing information, but the
        // chrome only needs the topology + active-pane id.
        state.windows = tmux.windows.map { win in
            WindowInfo(
                id: win.id,
                name: win.name,
                layout: layout(for: win),
                activePaneID: win.activePaneID
            )
        }

        // Reconcile pane backends: create for new ids, drop for
        // panes tmux removed.
        let valid = Set(tmux.paneIDs)
        for paneID in tmux.paneIDs where paneBackends[paneID] == nil {
            guard let driver = tmux.driver(for: paneID) else { continue }
            paneBackends[paneID] = TmuxPaneBackend(
                paneID: paneID,
                driver: driver,
                owner: self
            )
        }
        paneBackends = paneBackends.filter { valid.contains($0.key) }
    }

    // MARK: - SessionBackend

    func pane(_ id: Int) -> PaneBackend? {
        paneBackends[id]
    }

    func disconnect() async {
        FileLogger.shared.log("TmuxBackend.disconnect")
        paneTitlePollTask?.cancel()
        paneTitlePollTask = nil
        paneBackends.removeAll()
        shell = nil
        // Caller owns the SSH lifecycle; we just clear state.
        state.windows = []
        state.activeWindowID = nil
        state.isAttached = false
        state.paneTitles = [:]
    }

    func splitPane(direction: SplitDirection, target: Int) async {
        let flag = direction == .horizontal ? "-h" : "-v"
        await write("split-window \(flag) -t %\(target)\n")
    }

    func killPane(_ paneID: Int) async {
        await write("kill-pane -t %\(paneID)\n")
    }

    func selectPane(_ paneID: Int) async {
        // Optimistic local update so the UI flips immediately —
        // `%window-pane-changed` from tmux confirms (or corrects)
        // it on its own schedule.
        if let wid = tmux.activeWindowID {
            tmux.setActivePane(paneID, in: wid)
            syncState()
        }
        await write("select-pane -t %\(paneID)\n")
    }

    func newWindow() async {
        await write("new-window\n")
    }

    func selectWindow(_ windowID: Int) async {
        await write("select-window -t :@\(windowID)\n")
    }

    func killWindow(_ windowID: Int) async {
        await write("kill-window -t :@\(windowID)\n")
    }

    func renameWindow(_ windowID: Int, name: String) async {
        await write("rename-window -t :@\(windowID) \(shellEscape(name))\n")
    }

    func renameSession(_ newName: String) async {
        guard let sid = tmux.sessionID else { return }
        await write("rename-session -t $\(sid) \(shellEscape(newName))\n")
    }

    func toggleZoom(paneID: Int) async {
        await write("resize-pane -Z -t %\(paneID)\n")
    }

    func movePane(paneID: Int, toWindow windowID: Int) async {
        // `move-pane`'s `-t` expects a pane (it's a split-relative
        // operation). For "move pane to a different window," the
        // right primitive is `join-pane` with `:@<window-id>` as
        // the target — tmux joins the source pane into that window
        // (splitting whatever pane is currently active there).
        await write("join-pane -s %\(paneID) -t :@\(windowID)\n")
    }

    func movePane(paneID: Int, toPane targetID: Int, edge: PaneDropEdge) async {
        // tmux `join-pane` flag mapping:
        //   -h  → horizontal split (panes side-by-side)
        //   -v  → vertical split   (panes stacked)
        //   -b  → place source *before* target (left / above)
        //   absent → place source *after* target (right / below)
        let directionFlag: String
        let beforeFlag: String
        switch edge {
        case .top:    directionFlag = "-v"; beforeFlag = " -b"
        case .bottom: directionFlag = "-v"; beforeFlag = ""
        case .left:   directionFlag = "-h"; beforeFlag = " -b"
        case .right:  directionFlag = "-h"; beforeFlag = ""
        }
        await write("join-pane -s %\(paneID) -t %\(targetID) \(directionFlag)\(beforeFlag)\n")
    }

    func paneTitle(_ paneID: Int) -> String? {
        // Polled from tmux's `pane_current_command` (see
        // `pollPaneTitles`). Falls back to `%<id>` when the cache
        // hasn't been populated yet (first 0–2.5s after attach,
        // brand-new panes between polls).
        if let cached = state.paneTitles[paneID], !cached.isEmpty {
            return cached
        }
        return "%\(paneID)"
    }

    // MARK: - Internals

    /// Convert a window's `TmuxLayout?` (topology + cell sizes)
    /// into a `PaneNode` (topology only). When tmux hasn't yet
    /// pushed `%layout-change`, fall back to a flat horizontal
    /// split over the window's known pane ids.
    private func layout(for win: TmuxWindow) -> PaneNode {
        if let layout = win.layout {
            return convert(layout)
        }
        // Fallback: tmux hasn't sent layout yet (e.g. mid-attach).
        // Use a synthetic flat layout over what we know.
        let ids = win.activePaneID.map { [$0] } ?? []
        if ids.count == 1 { return .leaf(paneID: ids[0]) }
        if ids.isEmpty {
            // Picked an arbitrary placeholder leaf; the next
            // `%layout-change` will overwrite this.
            return .leaf(paneID: -1)
        }
        return .split(direction: .horizontal, children: ids.map { .leaf(paneID: $0) })
    }

    private func convert(_ layout: TmuxLayout) -> PaneNode {
        switch layout.node {
        case .leaf(let paneID):
            return .leaf(paneID: paneID)
        case .horizontal(let kids):
            return .split(direction: .horizontal, children: kids.map(convert))
        case .vertical(let kids):
            return .split(direction: .vertical, children: kids.map(convert))
        }
    }

    /// Write a tmux command line on the SSH control channel.
    /// Idempotent if no shell — silently drops, useful during
    /// connection setup races.
    private func write(_ cmd: String) async {
        guard let shell else {
            FileLogger.shared.log("TmuxBackend.write skipped (no shell): \(cmd.trimmingCharacters(in: .newlines))")
            return
        }
        FileLogger.shared.log("TmuxBackend.write: \(cmd.trimmingCharacters(in: .newlines))")
        try? await shell.write(Data(cmd.utf8))
    }

    /// Encode `data` as `send-keys -H` hex, send to a specific
    /// pane id. Mirrors `TmuxSessionView.sendInput`.
    fileprivate func sendKeysToPane(_ paneID: Int, data: Data) async {
        guard let shell, !data.isEmpty else { return }
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        let cmd = "send-keys -H -t %\(paneID) \(hex)\n"
        try? await shell.write(Data(cmd.utf8))
    }

    /// Forward a per-pane resize event up to the
    /// `onActivePaneResize` hook *if* this is the currently
    /// active pane. Background-pane size events are noise — the
    /// active pane is the only one that should drive PTY resize.
    fileprivate func paneResized(paneID: Int, cols: Int, rows: Int) {
        guard let activePID = state.activePaneID, activePID == paneID else { return }
        onActivePaneResize?(cols, rows)
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Per-pane I/O for the tmux backend. `driver` is the per-pane
/// SwiftTerm driver (shared with `TmuxSession`'s drivers map);
/// `sendKeys` and `onResize` are closures handed in by the parent
/// backend so we don't have to retain a reference to the SSH shell
/// (the parent owns it).
@MainActor
final class TmuxPaneBackend: PaneBackend {
    let paneID: Int
    let driver: TerminalDriver
    private weak var owner: TmuxSessionBackend?

    init(paneID: Int, driver: TerminalDriver, owner: TmuxSessionBackend) {
        self.paneID = paneID
        self.driver = driver
        self.owner = owner
    }

    func send(_ data: Data) async {
        await owner?.sendKeysToPane(paneID, data: data)
    }

    func resize(cols: Int, rows: Int) async {
        owner?.paneResized(paneID: paneID, cols: cols, rows: rows)
    }
}
#endif
