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
/// `SessionState` that the new chrome (`SessionView`-style)
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
            // Tell tmux to think of the client as a generous size,
            // larger than any realistic iPad pane area in cells.
            // This decouples the SSH PTY size (which we set to the
            // active pane's dimensions for terminal-control reasons)
            // from tmux's layout calculations: with a big client,
            // any `resize-pane` we issue afterwards fits without
            // tmux rejecting it for being larger than the client.
            Task { await write("refresh-client -C 240x80\n") }
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
        // Tmux in -CC mode emits `%window-add` for a freshly created
        // window without an accompanying `%layout-change`. That
        // leaves us with the window known by id but `cellTree == nil`
        // — the layout engine has nothing to apportion against, the
        // SwiftUI render keeps painting the previous active tab's
        // panes, and "new tab shows the old tab's content." Pull
        // layouts ourselves whenever a window appears so the
        // missing-event case is patched at the source.
        if case .windowAdd = event {
            Task { [weak self] in
                guard let self, let shell = self.shell else { return }
                await self.refreshActiveWindowLayout(shell: shell)
            }
        }
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
                cellLayout: win.layout.map { self.cellLayout(for: $0) },
                cellTree: win.layout.map { self.cellTree(for: $0) },
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
        // Optimistic local toggle so the UI flips immediately when
        // the user hits ⌘⇧Enter. Without this, `state.zoomedPaneID`
        // would only ever be `nil` for the tmux backend — `SessionView`
        // checks that field to decide whether to render a single
        // fullscreen pane or the engine-driven multi-pane layout, so
        // the visual zoom never landed even though the `resize-pane
        // -Z` round-trip succeeded server-side.
        //
        // tmux is still the source of truth for actual cell sizing
        // (the `%layout-change` reply re-flows the window's
        // `cellTree`); we just don't have a clean signal for the
        // zoom *flag* from `%layout-change` itself, so we mirror
        // FakeSessionBackend's behavior and trust the toggle locally.
        if state.zoomedPaneID == paneID {
            state.zoomedPaneID = nil
        } else {
            state.zoomedPaneID = paneID
        }
        FileLogger.shared.log("TmuxBackend.toggleZoom %\(paneID) → \(state.zoomedPaneID.map { "%\($0)" } ?? "off")")
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

    // MARK: - Grid handshake

    /// Tell tmux the window grid we want and re-capture every pane's
    /// content from tmux's authoritative grid afterwards. This is
    /// the single chokepoint for "view geometry changed" in the new
    /// architecture: instead of `sizeChanged → resize-pane` per pane
    /// (which races bash's pty width), we propose one window size
    /// here, tmux reflows internally, and we read its grid back.
    ///
    /// Sequence on the wire:
    /// 1. `refresh-client -C cols x rows` — sets the client's view
    ///    bounds, so subsequent resize-window can fit.
    /// 2. `resize-window -t @WID -x cols -y rows` for the active
    ///    window — tmux re-flows the layout.
    /// 3. `list-windows -F …` to pull the new layout (per-pane
    ///    cell sizes).
    /// 4. For each pane in the active window: suspend its driver,
    ///    `capture-pane -p -e`, query cursor position, replace the
    ///    SwiftTerm grid with the snapshot, resume.
    ///
    /// Apply per-pane sizes computed by `PaneLayoutEngine`. For
    /// each pane whose current `pane_width × pane_height` (per
    /// tmux's last `%layout-change`) disagrees with the engine's
    /// request, issue `resize-pane -t %X -x C -y R`. After all
    /// resizes, re-fetch the layout and recapture every pane in
    /// the active window. This is the per-pane analogue of
    /// `applyGrid`, but driven by what the chrome can actually
    /// fit — chrome-subtracted apportionment up front, exact
    /// targets to tmux at the end.
    func resizePane(_ paneID: Int, direction: ResizeDirection, cells: Int) async {
        guard cells > 0 else { return }
        let flag: String = {
            switch direction {
            case .left:  return "-L"
            case .right: return "-R"
            case .up:    return "-U"
            case .down:  return "-D"
            }
        }()
        await write("resize-pane -t %\(paneID) \(flag) \(cells)\n")
    }

    func applyWindowLayout(
        windowID: Int,
        cellCols: Int,
        cellRows: Int,
        panes: [(paneID: Int, cols: Int, rows: Int)]
    ) async {
        guard let shell, cellCols > 0, cellRows > 0 else { return }
        FileLogger.shared.log("TmuxBackend.applyWindowLayout @\(windowID) → window=\(cellCols)x\(cellRows) panes=\(panes.count)")
        // 1. Resize the window itself first. Without this, tmux
        // would clamp our per-pane resize requests against the
        // window's saved size — which for non-active windows on
        // attach is whatever the previous client left it at.
        await write("resize-window -t @\(windowID) -x \(cellCols) -y \(cellRows)\n")
        // 2. Per-pane resize, deduping against tmux's *current*
        // sizes (now that the window's been resized, list-windows
        // would still report the pre-resize per-pane sizes until
        // tmux re-flows — but the dedupe still helps for repeated
        // calls with stable inputs).
        var currentSize: [Int: (cols: Int, rows: Int)] = [:]
        for win in tmux.windows {
            if let layout = win.layout {
                collectCurrentSizes(layout, into: &currentSize)
            }
        }
        for entry in panes {
            let current = currentSize[entry.paneID]
            guard current?.cols != entry.cols || current?.rows != entry.rows else {
                continue
            }
            await write("resize-pane -t %\(entry.paneID) -x \(entry.cols) -y \(entry.rows)\n")
        }
        // 3. Read back the new layout so state.windows reflects
        // tmux's actual response.
        await refreshActiveWindowLayout(shell: shell)
        // 4. Recapture each pane so SwiftTerm's grid content lines
        // up with tmux's post-resize grid content.
        for entry in panes {
            await recapturePane(paneID: entry.paneID)
        }
    }

    func applyPaneLayout(_ entries: [(paneID: Int, cols: Int, rows: Int)]) async {
        guard let shell, !entries.isEmpty else { return }
        FileLogger.shared.log("TmuxBackend.applyPaneLayout entries=\(entries.count)")
        // Collect current per-pane sizes across *all* windows so
        // entries belonging to a non-active tab can also dedup the
        // "size already matches" case.
        var currentSize: [Int: (cols: Int, rows: Int)] = [:]
        for win in tmux.windows {
            if let layout = win.layout {
                collectCurrentSizes(layout, into: &currentSize)
            }
        }
        var changed = false
        for entry in entries {
            let current = currentSize[entry.paneID]
            guard current?.cols != entry.cols || current?.rows != entry.rows else {
                continue
            }
            await write("resize-pane -t %\(entry.paneID) -x \(entry.cols) -y \(entry.rows)\n")
            changed = true
        }
        if changed {
            // list-windows refreshes every window's layout, not
            // just the active one — the name is misleading but the
            // body iterates all snapshots. So one call is enough
            // regardless of which window's panes we resized.
            await refreshActiveWindowLayout(shell: shell)
        }
        // Recapture exactly the panes whose sizes we touched. Earlier
        // versions recaptured "every pane in the active window";
        // wrong for entries belonging to a non-active tab.
        for entry in entries {
            await recapturePane(paneID: entry.paneID)
        }
    }

    /// Walk a `TmuxLayout` and record every leaf's `(cols, rows)`.
    /// Used by `applyPaneLayout` to decide which panes actually
    /// need a `resize-pane` command.
    private func collectCurrentSizes(
        _ layout: TmuxLayout,
        into out: inout [Int: (cols: Int, rows: Int)]
    ) {
        switch layout.node {
        case .leaf(let pid):
            out[pid] = (layout.cols, layout.rows)
        case .horizontal(let kids), .vertical(let kids):
            for kid in kids { collectCurrentSizes(kid, into: &out) }
        }
    }

    func applyGrid(cols: Int, rows: Int) async {
        guard cols > 0, rows > 0, let shell else { return }
        FileLogger.shared.log("TmuxBackend.applyGrid request \(cols)x\(rows)")
        await write("refresh-client -C \(cols)x\(rows)\n")
        // First-call race: SessionView may fire `applyGrid`
        // before tmux's `%session-window-changed` has populated
        // `state.activeWindowID`. If so, refresh layout once to
        // learn it, then issue the resize and refresh again.
        if state.activeWindowID == nil {
            await refreshActiveWindowLayout(shell: shell)
        }
        if let activeWid = state.activeWindowID {
            await write("resize-window -t @\(activeWid) -x \(cols) -y \(rows)\n")
            // Pull the post-resize layout so per-pane cell sizes are
            // current. tmux honors what fits; if our request was
            // bigger than the SSH pty allows it'll silently round
            // down — the layout we read back is the authoritative
            // answer.
            await refreshActiveWindowLayout(shell: shell)
        }
        if let activeWid = state.activeWindowID,
           let win = tmux.windows.first(where: { $0.id == activeWid }),
           let layout = win.layout
        {
            for paneID in layout.paneIDs {
                await recapturePane(paneID: paneID)
            }
        }
    }

    /// Re-read `list-windows` to refresh the active window's layout
    /// in `TmuxSession.windows`. Used after we issue a `resize-window`
    /// to learn the new per-pane cell sizes tmux assigned.
    private func refreshActiveWindowLayout(shell: SSHShellSession) async {
        let format = "#{window_id}\t#{window_active}\t#{window_name}\t#{window_layout}"
        do {
            let lines = try await tmux.runCommand(
                "list-windows -F \"\(format)\"\n",
                write: { try await shell.write($0) }
            )
            var snapshots: [TmuxSession.WindowSnapshot] = []
            for line in lines {
                let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count >= 2 else { continue }
                let raw = String(parts[0])
                guard raw.hasPrefix("@"), let wid = Int(raw.dropFirst()) else { continue }
                let isActive = (parts.count > 1) && (parts[1] == "1")
                let name = parts.count > 2 ? String(parts[2]) : nil
                let layout = parts.count > 3 ? String(parts[3]) : nil
                snapshots.append(TmuxSession.WindowSnapshot(id: wid, name: name, isActive: isActive, layout: layout))
            }
            if !snapshots.isEmpty {
                tmux.bootstrap(windows: snapshots)
                syncState()
            }
        } catch {
            FileLogger.shared.log("TmuxBackend.refreshActiveWindowLayout: \(error)")
        }
    }

    /// Re-capture one pane from tmux's grid into SwiftTerm's grid.
    /// Suspends the driver so any `%output` arriving during the
    /// capture round-trip is dropped (those bytes are already in
    /// the snapshot — feeding them again would render the same
    /// content twice). On success, replaces the SwiftTerm grid
    /// content with the captured snapshot + cursor positioning.
    func recapturePane(paneID: Int) async {
        guard let shell, let driver = tmux.driver(for: paneID) else { return }
        FileLogger.shared.log("[%\(paneID)] recapturePane begin")
        driver.suspend()
        do {
            // `capture-pane -p -e` (no `-S`) captures *only* the
            // current visible area, not the scrollback. tmux preserves
            // scrollback at the cell width each line was written at —
            // mixing widths within one session (rotations, splits,
            // earlier geometry bugs) leaves stale lines whose hard
            // wraps disagree with the current grid. Feeding them to
            // SwiftTerm at the current width produced the screen-101
            // visual mess. The user can still browse scrollback via
            // tmux's `copy-mode` (Ctrl-b [) — we just don't replay
            // it client-side.
            let captureLines = try await tmux.runCommand(
                "capture-pane -p -e -t %\(paneID)\n",
                write: { try await shell.write($0) }
            )
            // Cursor position lives on a separate query because
            // capture-pane doesn't transfer it. Best-effort: if it
            // fails, skip cursor positioning rather than dropping
            // the whole snapshot.
            let cursorLines = (try? await tmux.runCommand(
                "display-message -p -t %\(paneID) \"C\t#{cursor_x}\t#{cursor_y}\"\n",
                write: { try await shell.write($0) }
            )) ?? []
            var bytes = Data()
            for (idx, line) in captureLines.enumerated() {
                bytes.append(OutputDecoder.decode(line))
                if idx < captureLines.count - 1 {
                    bytes.append(contentsOf: [0x0D, 0x0A])
                }
            }
            // Position cursor: tmux's coords are 0-based, ANSI's
            // CUP is 1-based. Output: `ESC[<row+1>;<col+1>H`.
            for line in cursorLines {
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, parts[0] == "C",
                      let col = Int(parts[1]), let row = Int(parts[2])
                else { continue }
                let move = "\u{1B}[\(row + 1);\(col + 1)H"
                bytes.append(Data(move.utf8))
                break
            }
            driver.feedSnapshot(bytes)
            driver.resumeDiscardingPending()
            FileLogger.shared.log("[%\(paneID)] recapturePane done snapshot=\(bytes.count)B")
        } catch {
            FileLogger.shared.log("[%\(paneID)] recapturePane FAILED \(error) — flushing buffered live")
            driver.resumeFlushingPending()
        }
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

    /// Flatten a `TmuxLayout` into the per-pane cell rectangles the
    /// renderer needs. tmux's layout already carries `(x, y, cols,
    /// rows)` for every node; we just collect the leaves.
    private func cellLayout(for layout: TmuxLayout) -> CellLayout {
        var panes: [PaneCellRect] = []
        collectPanes(layout, into: &panes)
        return CellLayout(cols: layout.cols, rows: layout.rows, panes: panes)
    }

    private func collectPanes(_ layout: TmuxLayout, into out: inout [PaneCellRect]) {
        switch layout.node {
        case .leaf(let pid):
            out.append(PaneCellRect(
                paneID: pid,
                x: layout.x, y: layout.y,
                cols: layout.cols, rows: layout.rows
            ))
        case .horizontal(let kids), .vertical(let kids):
            for kid in kids { collectPanes(kid, into: &out) }
        }
    }

    /// Convert `TmuxLayout` (TmuxCC module) into the App-side
    /// `LayoutCellNode` tree that the layout engine consumes.
    private func cellTree(for layout: TmuxLayout) -> LayoutCellNode {
        let kind: LayoutCellNode.Kind
        switch layout.node {
        case .leaf(let pid):
            kind = .leaf(paneID: pid)
        case .horizontal(let kids):
            kind = .horizontal(children: kids.map(cellTree(for:)))
        case .vertical(let kids):
            kind = .vertical(children: kids.map(cellTree(for:)))
        }
        return LayoutCellNode(cols: layout.cols, rows: layout.rows, kind: kind)
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

    /// SwiftTerm reported a render size for `paneID`. In the new
    /// architecture (tmux is the source of truth on grid size) this
    /// is purely a sanity-check signal — we already told tmux the
    /// grid we want and sized the pane view to match, so a report
    /// here that disagrees with what we asked for indicates either a
    /// font cell rounding issue or a layout race we want to see.
    /// We *do* still forward the active pane's size to the SSH PTY
    /// resize path, because the outer SSH PTY must be at least as
    /// big as the active pane for tmux to be willing to render at
    /// our requested size.
    fileprivate func paneResized(paneID: Int, cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        FileLogger.shared.log("[%\(paneID)] paneResized cols=\(cols) rows=\(rows) (informational; resize-pane no longer driven from SwiftTerm)")
        if let activePID = state.activePaneID, activePID == paneID {
            onActivePaneResize?(cols, rows)
        }
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
