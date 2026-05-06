import SwiftUI
import UIKit
import SSHCore
import TmuxCC
import TerminalKit

/// Live tmux `-CC` session screen with a tab strip and per-pane
/// SwiftTerm rendering. Tap a tab to switch windows on the server.
/// Typing in the active pane sends each input chunk back to the
/// pane via `send-keys -H -t %<paneID> <hex bytes>` — `-H` lets us
/// pass arbitrary bytes (control chars, escape sequences, UTF-8)
/// without shell-quoting headaches.
struct TmuxSessionView: View {
    let host: Host
    let tofu: TOFUCoordinator
    let settings: SettingsStore
    let store: HostStore
    let keyStore: KeyStore
    /// When true, skip the auto-attach to `host.lastTmuxSession` and
    /// always show the picker. Used by the "List tmux sessions" entry
    /// on the host detail screen.
    var forceShowPicker: Bool = false

    @State private var connection: SSHConnection?
    @State private var shell: SSHShellSession?
    @State private var session = TmuxSession()
    @State private var statusMessage: String = "Connecting…"
    @State private var errorMessage: String?
    @State private var pendingResize: Task<Void, Never>?
    @State private var lastAppliedSize: (cols: Int, rows: Int)?
    @State private var showingSessions = false
    @State private var availableSessions: [TmuxSessionInfo] = []
    @State private var showingAttachPicker = false
    @State private var showingDebug = false
    @State private var renamingWindowID: Int?
    @State private var renameText: String = ""
    @State private var renamingSession = false
    @State private var sessionRenameText: String = ""
    /// `true` if the bootstrap should run `capture-pane` for every
    /// pane regardless of how many bytes tmux already pushed.
    /// Set when attaching to an *existing* session — tmux sends only
    /// a partial redraw (typically a prompt re-paint) for one pane,
    /// so the rest of the pane content has to come from
    /// `capture-pane`. For a *new* session, tmux replays the bash
    /// prompt naturally; capturing on top would duplicate it.
    @State private var captureOnBootstrap: Bool = false
    /// Pane IDs we've already pulled scrollback for via
    /// `capture-pane`. Bootstrap fills the active window; switching
    /// to another tab triggers lazy capture for that window's panes
    /// (only if they're not already in this set).
    @State private var capturedPaneIDs: Set<Int> = []
    @State private var tabsVisible: Bool = true
    @State private var fullScreen: Bool = false
    /// Whether the slim accessory bar (Esc/Tab/arrows/`|`/prefix)
    /// is shown above the keyboard. Independent of soft-keyboard
    /// visibility — iPadOS owns that based on FR + HW state.
    @State private var specialKeys: Bool = true
    /// `@State` on a class-type session persists across `NavigationStack`
    /// pop+push, so on a fresh appear the session may still hold the
    /// previous attach's `sessionID`. Without this flag, the next
    /// `%session-changed` event looks like a `switch-client`
    /// (old != new, both non-nil) and triggers a spurious clear that
    /// zeroes `activeWindowID` and pops the view.
    @State private var hasObservedInitialSessionID = false

    /// While `true`, render the active pane as inactive — used as
    /// a 200ms feedback flash when `⌘⌥+arrow` hits a wall. Doesn't
    /// touch tmux state; only the local rendering layer dims.
    @State private var paneNavBlink: Bool = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if !fullScreen {
                statusBar
            }
            if tabsVisible {
                tabStrip
                    .frame(height: 44)
                    .background(Color(.secondarySystemBackground))
                Divider()
            }
            content
            if specialKeys, let pid = currentPaneID {
                SoftKeyboard(onKey: { data in
                    sendInput(data, toPaneID: pid)
                })
            }
            if showingDebug {
                Divider()
                debugOverlay
            }
        }
        .toolbar(fullScreen ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(fullScreen)
        .ignoresSafeArea(.all, edges: fullScreen ? [.top, .bottom] : [])
        .background(keyboardShortcutSink)
        .navigationTitle(session.sessionName.map { "tmux: \($0)" } ?? "tmux")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Replace the default centered title with a custom one
            // that supports long-press → "Rename session". Tapping
            // an item doesn't conflict with rename because long-press
            // is a separate gesture.
            ToolbarItem(placement: .principal) {
                Text(session.sessionName.map { "tmux: \($0)" } ?? "tmux")
                    .font(.headline)
                    .onLongPressGesture {
                        if session.sessionID != nil {
                            beginRenameSession()
                        }
                    }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    tabsVisible.toggle()
                } label: {
                    Image(systemName: tabsVisible
                        ? "rectangle.split.3x1.fill"
                        : "rectangle.split.3x1")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    specialKeys.toggle()
                    session.logDebug("toolbar.specialKeys → \(specialKeys)")
                } label: {
                    Image(systemName: specialKeys
                        ? "keyboard"
                        : "keyboard.chevron.compact.down")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSessions = true
                } label: {
                    Image(systemName: "rectangle.stack")
                }
                .disabled(shell == nil)
            }
        }
        .sheet(isPresented: $showingSessions) {
            if let shell {
                TmuxSessionsSheet(session: session, shell: shell) {
                    showingSessions = false
                }
            }
        }
        .alert(
            renamingWindowID.map { "Rename window @\($0)" } ?? "Rename window",
            isPresented: Binding(
                get: { renamingWindowID != nil },
                set: { if !$0 { renamingWindowID = nil; renameText = "" } }
            )
        ) {
            TextField("Name", text: $renameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {
                renamingWindowID = nil
                renameText = ""
            }
            Button("Rename", action: commitRenameWindow)
        }
        .alert(
            session.sessionID.map { "Rename session $\($0)" } ?? "Rename session",
            isPresented: $renamingSession
        ) {
            TextField("Name", text: $sessionRenameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {
                sessionRenameText = ""
            }
            Button("Rename", action: commitRenameSession)
        }
        .sheet(isPresented: $showingAttachPicker) {
            TmuxAttachPickerSheet(
                sessions: availableSessions,
                onAttach: { name, forceDetach in
                    showingAttachPicker = false
                    Task { await attach(.existing(name: name, forceDetach: forceDetach)) }
                },
                onCreate: { name in
                    showingAttachPicker = false
                    Task { await attach(.new(name)) }
                },
                onRename: { oldName, newName in
                    Task { await renameSessionViaExec(old: oldName, new: newName) }
                },
                onCancel: {
                    showingAttachPicker = false
                    statusMessage = "cancelled"
                }
            )
            .interactiveDismissDisabled()
        }
        .task { await connect() }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            session.logDebug("scenePhase: \(oldPhase) → \(newPhase)")
            if newPhase == .active {
                Task { await reconnectIfNeeded() }
            }
        }
        .onChange(of: session.isAttached) { _, attached in
            session.logDebug("onChange isAttached → \(attached)")
            if attached {
                Task { await bootstrapWindows() }
            }
        }
        .onChange(of: session.sessionID) { oldVal, newVal in
            session.logDebug("onChange sessionID: \(String(describing: oldVal)) → \(String(describing: newVal))  initialSeen=\(hasObservedInitialSessionID)")
            // Only a real `switch-client` should reset the view's
            // window state — and that requires us to have seen at
            // least one `%session-changed` *during this appear*.
            // The first transition could just be the new attach
            // landing on top of a stale `sessionID` left over from a
            // previous attach (see hasObservedInitialSessionID).
            guard let newVal else { return }
            guard hasObservedInitialSessionID else {
                hasObservedInitialSessionID = true
                return
            }
            if let oldVal, oldVal != newVal {
                session.logDebug("  → clearForSessionSwitch + rebootstrap")
                session.clearForSessionSwitch()
                Task { await bootstrapWindows() }
            }
        }
        .onChange(of: session.activeWindowID) { oldVal, newVal in
            session.logDebug("activeWindowID: \(String(describing: oldVal)) → \(String(describing: newVal))")
            // No active window after we used to have one → session is
            // empty (last window was killed). Pop back to the host
            // detail screen so the user isn't stranded on a dead
            // tmux view.
            if oldVal != nil, newVal == nil {
                session.logDebug("dismiss() — activeWindowID went nil")
                dismiss()
            }
            // Lazy capture: tmux doesn't replay scrollback to a
            // -CC client when it switches windows, so panes in
            // windows we haven't seen yet stay blank until a
            // redraw is triggered (resize, split, etc). Pull the
            // scrollback ourselves the first time each window
            // becomes active.
            if let newID = newVal, captureOnBootstrap {
                Task { await captureWindowPanesIfNeeded(windowID: newID) }
            }
        }
        .onAppear {
            session.logDebug("TmuxSessionView.onAppear (host=\(host.name))")
            hasObservedInitialSessionID = false
        }
        .onDisappear {
            session.logDebug("TmuxSessionView.onDisappear (host=\(host.name), sessionName=\(session.sessionName ?? "nil"))")
            // Persist on the way out, not on every sessionName change.
            // Saving mid-flow mutates `HostStore.hosts`, which causes
            // `HostListView`'s ForEach to rebuild the NavigationLink
            // destination closures and (in NavigationStack) pops the
            // pushed view, kicking the user back to the host detail
            // screen mid-attach.
            if let name = session.sessionName {
                store.updateLastTmuxSession(hostID: host.id, name: name)
                TranscriptStore.shared.close(host: host.host, session: name)
            }
            Task {
                await shell?.close()
                await connection?.disconnect()
            }
        }
    }

    /// Hidden buttons that exist solely to register hardware-keyboard
    /// shortcuts via `.keyboardShortcut`. Cmd-modified keys go through
    /// the iOS menu/responder chain *before* reaching SwiftTerm's text
    /// input, so this is the cleanest way to add iTerm2-style splits
    /// without fighting SwiftTerm for the keystroke.
    ///
    /// Mapping (matches iTerm2):
    ///   - ⌘D       → split right (panes side by side, tmux `-h`)
    ///   - ⌘⇧D      → split down  (panes stacked,    tmux `-v`)
    private var keyboardShortcutSink: some View {
        ZStack {
            Button("Split right") {
                sendShellCommand("split-window -h\n")
            }
            .keyboardShortcut("d", modifiers: .command)

            Button("Split down") {
                sendShellCommand("split-window -v\n")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("Close pane") {
                closeActivePane()
            }
            .keyboardShortcut("w", modifiers: .command)

            Button("Close window") {
                if let wid = session.activeWindowID {
                    closeWindow(wid)
                }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])

            Button("Toggle tab bar") {
                tabsVisible.toggle()
            }
            .keyboardShortcut("b", modifiers: .command)

            Button("Toggle full screen") {
                fullScreen.toggle()
            }
            .keyboardShortcut("f", modifiers: .command)

            // ⌘1..⌘9 → switch to tab N (1-based). Out-of-range
            // shortcuts no-op rather than wrapping.
            ForEach(1...9, id: \.self) { idx in
                Button("Switch to tab \(idx)") {
                    let windows = session.windows
                    guard idx - 1 < windows.count else {
                        session.logDebug("⌘\(idx) — no tab")
                        return
                    }
                    let target = windows[idx - 1].id
                    sendShellCommand("select-window -t :@\(target)\n")
                    session.logDebug("⌘\(idx) → @\(target)")
                }
                .keyboardShortcut(KeyEquivalent(Character("\(idx)")), modifiers: .command)
            }

            // ⌘⌥+arrow → spatial pane navigation. Uses tmux's own
            // cell-grid coordinates from `%layout-change` so the
            // neighbor pick is exact, not estimated.
            Button("Pane right") { navigatePane(.right) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Pane left")  { navigatePane(.left) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Pane up")    { navigatePane(.up) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Pane down")  { navigatePane(.down) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private var statusBar: some View {
        HStack {
            Text(statusMessage)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if isDisconnected {
                Button("Reconnect") {
                    Task { await reconnectIfNeeded() }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            Spacer()
            Button {
                showingDebug.toggle()
            } label: {
                Image(systemName: showingDebug ? "ladybug.fill" : "ladybug")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            if let id = session.sessionID, let name = session.sessionName {
                Text("$\(id) \(name)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Bottom-aligned overlay listing recent events + outgoing
    /// commands. Toggled via the ladybug in the status bar.
    private var debugOverlay: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(session.debugLog.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
                .padding(8)
            }
            .onChange(of: session.debugLog.count) { _, n in
                if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
        .frame(height: 200)
        .background(Color.black.opacity(0.85))
        .foregroundStyle(.green)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if session.windows.isEmpty {
                    Text("(waiting for windowAdd events)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                } else {
                    ForEach(session.windows) { window in
                        tabButton(window)
                    }
                }
                Button(action: newWindow) {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(!session.isAttached)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func tabButton(_ window: TmuxWindow) -> some View {
        let isActive = window.id == session.activeWindowID
        let label = window.name ?? "@\(window.id)"
        return HStack(spacing: 6) {
            Text(label)
                .font(.caption.monospaced())
                .contentShape(Rectangle())
                .onTapGesture { selectWindow(window.id) }
                .onLongPressGesture { beginRenameWindow(window) }
            Button {
                closeWindow(window.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)              // bigger tap target than the glyph
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func beginRenameWindow(_ window: TmuxWindow) {
        renameText = window.name ?? ""
        renamingWindowID = window.id
    }

    private func commitRenameWindow() {
        guard let id = renamingWindowID else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sendShellCommand("rename-window -t :@\(id) \(shellEscape(trimmed))\n")
        }
        renamingWindowID = nil
        renameText = ""
    }

    private func beginRenameSession() {
        sessionRenameText = session.sessionName ?? ""
        renamingSession = true
    }

    private func commitRenameSession() {
        guard let sid = session.sessionID else { return }
        let trimmed = sessionRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingSession = false
        sessionRenameText = ""
        guard !trimmed.isEmpty else { return }
        sendShellCommand("rename-session -t $\(sid) \(shellEscape(trimmed))\n")
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            if session.paneIDs.isEmpty {
                VStack(spacing: 8) {
                    Text(session.activeWindowID.map { "Window @\($0)" } ?? "no active window")
                        .font(.title2.weight(.semibold))
                    Text("Waiting for pane output…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let layout = currentWindow?.layout {
                // Recursive layout rendering. Drivers for off-window
                // panes live on in `session.drivers`; if the user
                // tabs back, the new SwiftTermView replays the buffer
                // from `TerminalDriver.bind`.
                paneTree(layout)
            } else {
                // Fallback: layoutChange hasn't arrived yet. Stack all
                // known panes; active is the only one shown.
                ForEach(session.paneIDs, id: \.self) { paneID in
                    paneCell(paneID: paneID, isActive: paneID == currentPaneID)
                        .opacity(paneID == currentPaneID ? 1 : 0)
                        .disabled(paneID != currentPaneID)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            if let line = session.lastResponseLine {
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(8)
            }
        }
        .overlay(alignment: .bottom) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(8)
            }
        }
        // Visible "can't go there" feedback for `⌘⌥+arrow` hitting
        // a wall: dim AND red-wash the pane region for 200ms.
        .opacity(paneNavBlink ? 0.3 : 1.0)
        .overlay {
            if paneNavBlink {
                Color.red.opacity(0.18)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.08), value: paneNavBlink)
        .onChange(of: paneNavBlink) { old, new in
            session.logDebug("paneNavBlink \(old) → \(new)")
        }
    }

    private var currentPaneID: Int? {
        guard let wid = session.activeWindowID,
              let win = session.windows.first(where: { $0.id == wid })
        else {
            return session.paneIDs.first
        }
        if let pane = win.activePaneID {
            return pane
        }
        // Active window known but no `%window-pane-changed` yet —
        // pick a pane *from this window's layout*. Earlier we fell
        // back to `session.paneIDs.first` which could point at a
        // pane in a different window, breaking active-pane detection
        // (and the keyboard-bringing-up tap path along with it).
        if let layoutPane = win.layout?.paneIDs.first {
            return layoutPane
        }
        return session.paneIDs.first
    }

    private var currentWindow: TmuxWindow? {
        guard let wid = session.activeWindowID else { return nil }
        return session.windows.first { $0.id == wid }
    }

    /// Recursively render a parsed tmux layout. Branches use
    /// `GeometryReader` + explicit frames sized by each child's share
    /// of the layout (cols for horizontal, rows for vertical) so a
    /// 60/40 split actually looks 60/40, not 50/50.
    private func paneTree(_ layout: TmuxLayout) -> AnyView {
        // `paneNavBlink` overrides the displayed active pane to nil
        // for 200ms — visual feedback for failed `⌘⌥+arrow` nav.
        let displayedActive: Int? = paneNavBlink ? nil : currentPaneID
        switch layout.node {
        case .leaf(let paneID):
            return AnyView(paneCell(paneID: paneID, isActive: paneID == displayedActive))

        case .horizontal(let kids):
            let total = max(kids.reduce(0) { $0 + $1.cols }, 1)
            return AnyView(
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(Array(kids.enumerated()), id: \.offset) { _, child in
                            paneTree(child)
                                .frame(width: geo.size.width * CGFloat(child.cols) / CGFloat(total))
                        }
                    }
                }
            )

        case .vertical(let kids):
            let total = max(kids.reduce(0) { $0 + $1.rows }, 1)
            return AnyView(
                GeometryReader { geo in
                    VStack(spacing: 1) {
                        ForEach(Array(kids.enumerated()), id: \.offset) { _, child in
                            paneTree(child)
                                .frame(height: geo.size.height * CGFloat(child.rows) / CGFloat(total))
                        }
                    }
                }
            )
        }
    }

    /// Single SwiftTermView for a pane. Inactive panes get a thin
    /// border tint and a transparent tap target on top — taps fire
    /// `select-pane` instead of being swallowed by SwiftTerm.
    @ViewBuilder
    private func paneCell(paneID: Int, isActive: Bool) -> some View {
        if let driver = session.driver(for: paneID) {
            ZStack {
                SwiftTermView(
                    driver: driver,
                    scheme: settings.selectedScheme,
                    isActive: isActive,
                    onInput: { data in sendInput(data, toPaneID: paneID) },
                    onSizeChange: { cols, rows in
                        // Only the active pane drives window resize;
                        // size events from background panes are noise
                        // (and would shrink the window unnecessarily).
                        if isActive {
                            scheduleResize(paneCols: cols, paneRows: rows, paneID: paneID)
                        }
                    },
                    onNavigatePane: { dir in
                        let mapped: PaneNavigationDirection = {
                            switch dir {
                            case .left:  return .left
                            case .right: return .right
                            case .up:    return .up
                            case .down:  return .down
                            }
                        }()
                        navigatePane(mapped)
                    },
                    onLog: { [session] msg in
                        session.logDebug("[%\(paneID)] \(msg)")
                    }
                )
                .disabled(!isActive)
                if !isActive {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectPane(paneID)
                            // Pre-emptively flip the local active
                            // pane so the next tap doesn't hit the
                            // overlay again — tmux sometimes
                            // suppresses `%window-pane-changed` when
                            // its server-side active already matches.
                            if let wid = session.activeWindowID {
                                session.setActivePane(paneID, in: wid)
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(
                        isActive ? Color.accentColor.opacity(0.6) : Color.gray.opacity(0.25),
                        lineWidth: isActive ? 2 : 1
                    )
            )
            // Force a fresh mount whenever the pane id changes so
            // SwiftUI doesn't reuse the previous tab's `TerminalView`
            // (which was bound to the old driver). Without this,
            // switching tabs leaves the stale pane visible.
            .id(paneID)
        }
    }

    private func selectPane(_ id: Int) {
        sendShellCommand("select-pane -t %\(id)\n")
    }

    /// Close a window: tell tmux, then optimistically prune our local
    /// state. If `%window-close` arrives later for the same id it's a
    /// no-op; if it never arrives (window was already gone), we
    /// don't end up showing a ghost tab.
    private func closeWindow(_ id: Int) {
        sendShellCommand("kill-window -t :@\(id)\n")
        session.removeWindow(id: id)
    }

    /// Close the active pane in our active window. We pass an
    /// explicit `-t :@<wid>` so kill-pane targets the window the user
    /// sees in the app, even if our local active state has drifted
    /// from tmux's current window (which it does after pre-emptive
    /// window removal — we don't follow up with `select-window`).
    /// Last-pane case pre-emptively drops the window because
    /// `%window-close` doesn't reliably arrive in `-CC` mode here;
    /// multi-pane case is left alone since `%layout-change` does.
    private func closeActivePane() {
        guard let wid = session.activeWindowID else { return }
        sendShellCommand("kill-pane -t :@\(wid)\n")
        let win = session.windows.first(where: { $0.id == wid })
        // A newly-opened window may not yet have its `%layout-change`
        // — treat absent layout as single-pane, since tmux always
        // creates windows with one pane.
        let singlePane: Bool
        if let layout = win?.layout {
            if case .leaf = layout.node { singlePane = true } else { singlePane = false }
        } else {
            singlePane = true
        }
        if singlePane {
            session.removeWindow(id: wid)
        }
    }

    private func selectWindow(_ id: Int) {
        sendShellCommand("select-window -t :@\(id)\n")
    }

    private func newWindow() {
        sendShellCommand("new-window\n")
    }

    /// Write one line of tmux-control-mode command directly to the
    /// master shell (i.e. the tmux client itself, not a pane). This is
    /// how every tmux verb in `-CC` mode is invoked — `select-window`,
    /// `split-window`, `kill-pane`, etc.
    /// Spatial pane navigation: walk the active window's
    /// `TmuxLayout`, find the neighbor leaf in `direction`, send
    /// `select-pane -t %<id>` to tmux. tmux gives us exact
    /// cell-grid coordinates per leaf so the geometry is accurate
    /// without estimation.
    ///
    /// On a no-neighbor result (the user tried to walk past the
    /// edge of the layout), flash `paneNavBlink` for 200ms — the
    /// active pane briefly dims so the user sees we tried but
    /// can't go that way.
    private func navigatePane(_ direction: PaneNavigationDirection) {
        let layout = currentWindow?.layout
        let active = currentPaneID
        let msg0 = "navigatePane(\(direction)) — activePane=\(active.map { "%\($0)" } ?? "nil") layout=\(layout != nil ? "yes" : "nil")"
        session.logDebug(msg0)
        print("[Tmux] " + msg0)

        guard let layout, let active else {
            print("[Tmux] navigatePane bail — no layout/active")
            return
        }
        let next = neighborPane(of: active, in: layout, direction: direction)
        let msg1 = "neighbor(of: %\(active), \(direction)) = \(next.map { "%\($0)" } ?? "nil")"
        session.logDebug(msg1)
        print("[Tmux] " + msg1)

        if let next {
            sendShellCommand("select-pane -t %\(next)\n")
        } else {
            paneNavBlink = true
            session.logDebug("⌘⌥\(direction) — no neighbor (blink set)")
            print("[Tmux] paneNavBlink = true")
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                paneNavBlink = false
                print("[Tmux] paneNavBlink = false")
            }
        }
    }

    private func neighborPane(
        of paneID: Int,
        in layout: TmuxLayout,
        direction: PaneNavigationDirection
    ) -> Int? {
        let leaves = collectLeaves(layout)
        guard let cur = leaves.first(where: { $0.id == paneID }) else { return nil }
        let past = leaves.filter { l in
            l.id != paneID && Self.isPastLeaf(l, current: cur, direction: direction)
        }
        let overlapping = past.filter {
            Self.leafHasPerpendicularOverlap($0, current: cur, direction: direction)
        }
        let pool = overlapping.isEmpty ? past : overlapping
        return pool.min { lhs, rhs in
            let lhsDir = Self.leafDirectionDistance(lhs, current: cur, direction: direction)
            let rhsDir = Self.leafDirectionDistance(rhs, current: cur, direction: direction)
            if lhsDir != rhsDir { return lhsDir < rhsDir }
            let lhsPerp = Self.leafPerpendicularCenterDistance(lhs, current: cur, direction: direction)
            let rhsPerp = Self.leafPerpendicularCenterDistance(rhs, current: cur, direction: direction)
            return lhsPerp < rhsPerp
        }?.id
    }

    private func collectLeaves(
        _ layout: TmuxLayout
    ) -> [(id: Int, x: Int, y: Int, cols: Int, rows: Int)] {
        switch layout.node {
        case .leaf(let id):
            return [(id, layout.x, layout.y, layout.cols, layout.rows)]
        case .horizontal(let kids), .vertical(let kids):
            return kids.flatMap { collectLeaves($0) }
        }
    }

    private static func isPastLeaf(
        _ candidate: (id: Int, x: Int, y: Int, cols: Int, rows: Int),
        current: (id: Int, x: Int, y: Int, cols: Int, rows: Int),
        direction: PaneNavigationDirection
    ) -> Bool {
        switch direction {
        case .right: return candidate.x >= current.x + current.cols
        case .left:  return candidate.x + candidate.cols <= current.x
        case .up:    return candidate.y + candidate.rows <= current.y
        case .down:  return candidate.y >= current.y + current.rows
        }
    }

    private static func leafHasPerpendicularOverlap(
        _ candidate: (id: Int, x: Int, y: Int, cols: Int, rows: Int),
        current: (id: Int, x: Int, y: Int, cols: Int, rows: Int),
        direction: PaneNavigationDirection
    ) -> Bool {
        switch direction {
        case .left, .right:
            let maxStart = max(candidate.y, current.y)
            let minEnd = min(candidate.y + candidate.rows, current.y + current.rows)
            return maxStart < minEnd
        case .up, .down:
            let maxStart = max(candidate.x, current.x)
            let minEnd = min(candidate.x + candidate.cols, current.x + current.cols)
            return maxStart < minEnd
        }
    }

    private static func leafDirectionDistance(
        _ candidate: (id: Int, x: Int, y: Int, cols: Int, rows: Int),
        current: (id: Int, x: Int, y: Int, cols: Int, rows: Int),
        direction: PaneNavigationDirection
    ) -> Int {
        switch direction {
        case .right: return candidate.x - (current.x + current.cols)
        case .left:  return current.x - (candidate.x + candidate.cols)
        case .up:    return current.y - (candidate.y + candidate.rows)
        case .down:  return candidate.y - (current.y + current.rows)
        }
    }

    private static func leafPerpendicularCenterDistance(
        _ candidate: (id: Int, x: Int, y: Int, cols: Int, rows: Int),
        current: (id: Int, x: Int, y: Int, cols: Int, rows: Int),
        direction: PaneNavigationDirection
    ) -> Int {
        switch direction {
        case .left, .right:
            return abs((candidate.y + candidate.rows / 2) - (current.y + current.rows / 2))
        case .up, .down:
            return abs((candidate.x + candidate.cols / 2) - (current.x + current.cols / 2))
        }
    }

    private func sendShellCommand(_ cmd: String) {
        session.logDebug("send: \(cmd.trimmingCharacters(in: .newlines))")
        guard let shell else {
            session.logDebug("  (no shell — dropped)")
            return
        }
        Task {
            try? await shell.write(Data(cmd.utf8))
        }
    }

    /// Route one chunk of keyboard input from SwiftTerm to a tmux
    /// pane via `send-keys -H` (hex byte arguments). One command per
    /// chunk — for typed keys that's per-keystroke, for paste it's
    /// one command for the whole burst.
    private func sendInput(_ data: Data, toPaneID paneID: Int) {
        guard let shell, !data.isEmpty else { return }
        let hexBytes = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        let cmd = "send-keys -H -t %\(paneID) \(hexBytes)\n"
        Task {
            try? await shell.write(Data(cmd.utf8))
        }
    }

    /// Debounced resize. Multiple SwiftTermView geometry updates
    /// during a single rotation/reflow collapse to one PTY resize.
    /// Skips when nothing has actually changed.
    ///
    /// `paneCols`/`paneRows` are the active pane's rendered size. With
    /// splits, the *window* spans more cells than that — we scale up
    /// using the active pane's share of the parsed layout so tmux
    /// gets the bounding-box size, not just the active pane's.
    private func scheduleResize(paneCols: Int, paneRows: Int, paneID: Int) {
        guard paneCols > 0, paneRows > 0 else { return }
        let (cols, rows) = scaleToWindow(paneCols: paneCols, paneRows: paneRows, paneID: paneID)
        if let last = lastAppliedSize, last.cols == cols, last.rows == rows {
            return
        }
        pendingResize?.cancel()
        pendingResize = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
            guard !Task.isCancelled else { return }
            await applyResize(cols: cols, rows: rows)
        }
    }

    private func scaleToWindow(paneCols: Int, paneRows: Int, paneID: Int) -> (Int, Int) {
        guard let layout = currentWindow?.layout,
              let pane = findPane(paneID, in: layout),
              pane.cols > 0, pane.rows > 0
        else {
            return (paneCols, paneRows)
        }
        let cScale = Double(layout.cols) / Double(pane.cols)
        let rScale = Double(layout.rows) / Double(pane.rows)
        return (
            Int((Double(paneCols) * cScale).rounded()),
            Int((Double(paneRows) * rScale).rounded())
        )
    }

    private func findPane(_ id: Int, in layout: TmuxLayout) -> TmuxLayout? {
        switch layout.node {
        case .leaf(let p):
            return p == id ? layout : nil
        case .horizontal(let kids), .vertical(let kids):
            for k in kids {
                if let hit = findPane(id, in: k) { return hit }
            }
            return nil
        }
    }

    private func applyResize(cols: Int, rows: Int) async {
        guard let shell else { return }
        do {
            try await shell.resize(cols: cols, rows: rows)
            await MainActor.run {
                lastAppliedSize = (cols, rows)
            }
        } catch {
            await MainActor.run {
                errorMessage = "resize failed: \(error)"
            }
        }
    }

    /// Re-attach after the SSH socket died (typically because iOS
    /// suspended the app). The server-side tmux session keeps running,
    /// so reconnecting + `tmux -CC new-session -A` re-attaches to it
    /// and the protocol replay rebuilds our window/pane state from
    /// scratch.
    private func reconnectIfNeeded() async {
        session.logDebug("reconnectIfNeeded (status=\(statusMessage), isDisconnected=\(isDisconnected))")
        guard isDisconnected else { return }
        session.logDebug("  → reconnecting")
        await shell?.close()
        await connection?.disconnect()
        shell = nil
        connection = nil
        session.reset()
        lastAppliedSize = nil
        errorMessage = nil
        statusMessage = "reconnecting…"
        await connect()
    }

    private var isDisconnected: Bool {
        statusMessage == "disconnected"
            || statusMessage == "stream ended"
            || statusMessage == "cancelled"
    }

    private enum AttachChoice: CustomStringConvertible {
        case existing(name: String, forceDetach: Bool)
        case new(String?)   // nil → tmux picks a name

        var description: String {
            switch self {
            case .existing(let name, let force):
                return ".existing(\(name), force=\(force))"
            case .new(let name):
                return ".new(\(name ?? "<auto>"))"
            }
        }
    }

    /// Phase 1: SSH-connect, probe `tmux ls`. If the host has a
    /// remembered session that still exists, attach to it directly.
    /// Otherwise present the picker so the user can choose or create.
    private func connect() async {
        let endpoint = SSHEndpoint(host: host.host, port: host.port, user: host.user)
        let verifier = KnownHostsVerifier(
            knownHostsURL: KnownHostsLocation.url,
            prompter: { [tofu] prompt in
                await tofu.awaitDecision(for: prompt)
            }
        )
        do {
            let creds = try await loadCredentials()
            let conn = try await SSHConnection.connect(
                endpoint: endpoint,
                credentials: creds,
                hostKeyVerifier: verifier
            )
            await MainActor.run {
                self.connection = conn
                self.statusMessage = "probing tmux sessions"
            }

            let sessions = try await probeSessions(conn: conn)
            await MainActor.run { self.availableSessions = sessions }

            if !forceShowPicker,
               let remembered = host.lastTmuxSession,
               let match = sessions.first(where: { $0.name == remembered }),
               !match.attached
            {
                await attach(.existing(name: remembered, forceDetach: false))
            } else {
                await MainActor.run {
                    self.statusMessage = "choose tmux session"
                    self.showingAttachPicker = true
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "connect failed: \(error)"
                self.statusMessage = "disconnected"
            }
        }
    }

    /// Pre-attach session rename. We're not in `-CC` mode yet, so
    /// the rename runs via the same SSH `exec` channel that probes
    /// the session list. Refreshes `availableSessions` afterward so
    /// the picker shows the new name.
    private func renameSessionViaExec(old: String, new: String) async {
        guard let conn = connection else { return }
        let oldEsc = shellEscape(old)
        let newEsc = shellEscape(new)
        let inner = "tmux rename-session -t \(oldEsc) \(newEsc) 2>/dev/null; true"
        _ = try? await conn.exec("$SHELL -lc '\(inner)'")
        if let refreshed = try? await probeSessions(conn: conn) {
            await MainActor.run { self.availableSessions = refreshed }
        }
    }

    /// Run `tmux ls -F '...'` over an SSH `exec` channel and parse
    /// the rows. We invoke through `$SHELL -lc` so the user's login
    /// PATH (where tmux usually lives — `/usr/local/bin`, Homebrew,
    /// etc.) is set; SSH `exec` otherwise gets a stripped PATH and
    /// `tmux` may not resolve.
    ///
    /// An empty list (no tmux server, or no sessions) is not an
    /// error — the picker just offers "+ New" only.
    private func probeSessions(conn: SSHConnection) async throws -> [TmuxSessionInfo] {
        // Real TAB (0x09) in the format string — tmux does NOT
        // interpret `\t` as TAB in `-F`, so we have to embed the
        // separator literally. Outer single-quoted via `$SHELL -lc`
        // ensures tmux is on PATH from the user's login profile.
        let format = "#{session_id}\t#{session_name}\t#{session_windows}\t#{session_attached}"
        let inner = "tmux ls -F \"\(format)\" 2>/dev/null"
        let cmd = "$SHELL -lc '\(inner)'"
        let result = try await conn.exec(cmd)
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        return stdout
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { TmuxSessionInfo.parse(String($0)) }
    }

    /// Phase 2: open the master shell, ship the chosen `tmux -CC`
    /// command, and start pumping the stream into the parser.
    private func attach(_ choice: AttachChoice) async {
        guard let conn = connection else {
            session.logDebug("attach: no connection — bail")
            return
        }
        session.logDebug("attach: choice=\(choice)")
        // Existing-session attaches need the bootstrap to run
        // `capture-pane` for every pane, even if tmux already pushed
        // a few bytes (a partial redraw of the active pane). New
        // sessions don't — tmux replays the bash prompt itself, and
        // capturing on top of that would duplicate it.
        switch choice {
        case .existing: captureOnBootstrap = true
        case .new: captureOnBootstrap = false
        }
        capturedPaneIDs = []
        do {
            // For an attach where the user opted into force-detach,
            // boot every other client off the target session before
            // we open our control-mode session. Has to happen on the
            // SSH `exec` channel because we're not in `-CC` mode yet.
            if case .existing(let name, true) = choice {
                let escaped = shellEscape(name)
                let inner = "tmux detach-client -s \(escaped) 2>/dev/null; true"
                _ = try? await conn.exec("$SHELL -lc '\(inner)'")
            }
            let shellSession = try await conn.openShell()
            let cmd: String
            switch choice {
            case .existing(let name, _):
                cmd = "tmux -CC attach-session -t \(shellEscape(name))\n"
            case .new(let maybeName):
                if let name = maybeName, !name.isEmpty {
                    cmd = "tmux -CC new-session -A -s \(shellEscape(name))\n"
                } else {
                    cmd = "tmux -CC\n"
                }
            }
            await MainActor.run {
                self.shell = shellSession
                self.statusMessage = "starting tmux -CC"
            }

            try await shellSession.write(Data(cmd.utf8))

            Task {
                var parser = TmuxCCParser()
                do {
                    for try await data in shellSession.output {
                        let events = parser.feed(data)
                        await MainActor.run {
                            for event in events {
                                self.session.handle(event)
                                if case .output(let pid, let payload) = event {
                                    TranscriptStore.shared.feed(
                                        host: host.host,
                                        session: session.sessionName ?? "default",
                                        windowID: session.windowID(forPane: pid),
                                        paneID: pid,
                                        data: payload
                                    )
                                }
                            }
                            if self.session.isAttached, self.statusMessage != "attached" {
                                self.statusMessage = "attached"
                            }
                        }
                    }
                    await MainActor.run { self.statusMessage = "stream ended" }
                } catch {
                    await MainActor.run {
                        self.errorMessage = "stream error: \(error)"
                        self.statusMessage = "disconnected"
                    }
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "attach failed: \(error)"
                self.statusMessage = "disconnected"
            }
        }
    }

    /// Enumerate the active session's windows via `list-windows -F`
    /// and feed the snapshots into `TmuxSession.bootstrap`. tmux
    /// `-CC` doesn't replay `%window-add` for pre-existing windows,
    /// so without this we'd attach to a session and see "no windows".
    ///
    /// `\t` here is a literal TAB byte — tmux's `-F` parser does not
    /// interpret backslash escapes, but it preserves TABs from the
    /// surrounding double-quoted argument.
    private func bootstrapWindows() async {
        guard let shell else { return }
        let format = "#{window_id}\t#{window_active}\t#{window_name}\t#{window_layout}"
        do {
            let lines = try await session.runCommand(
                "list-windows -F \"\(format)\"\n",
                write: { try await shell.write($0) }
            )
            let snaps = lines.compactMap(parseWindowSnapshot)
            session.bootstrap(windows: snaps)

            // After we know the active window's layout, dump each
            // pane's existing scrollback into its driver so the user
            // doesn't see empty panes — tmux doesn't replay buffered
            // pane content to attaching clients.
            if let active = snaps.first(where: { $0.isActive }),
               let raw = active.layout,
               let layout = try? TmuxLayout.parse(raw)
            {
                for paneID in layout.paneIDs {
                    await capturePane(paneID: paneID)
                }
            }
        } catch {
            // Best-effort — without windows the user can still create
            // new ones, so don't surface this as a hard failure.
        }
    }

    /// Dump pane scrollback into its `TerminalDriver`. Each response
    /// line is one row of the pane buffer; control bytes come back
    /// octal-escaped (`\033`, etc.) so we run them through
    /// `OutputDecoder` and then rejoin with CRLF before feeding the
    /// terminal.
    private func capturePane(paneID: Int) async {
        guard let shell else { return }
        guard let driver = session.driver(for: paneID) else { return }
        // Don't capture twice — bootstrap may capture the active
        // window's panes, and the activeWindowID watcher will try
        // again if we don't gate it. (We *can't* fall back to a
        // pure `bufferedByteCount == 0` check after the first
        // capture, because the captured bytes themselves leave the
        // driver non-empty.)
        if capturedPaneIDs.contains(paneID) { return }
        // For new-session attaches, only capture cold panes —
        // tmux itself replays the bash prompt and capturing on top
        // would duplicate it. For existing-session attaches we
        // always capture: tmux only pushes a tiny partial redraw
        // for the active pane (and nothing for the others), so the
        // driver buffer being non-empty doesn't mean there's
        // anything substantive on screen.
        if !captureOnBootstrap, driver.bufferedByteCount > 0 { return }
        do {
            let lines = try await session.runCommand(
                "capture-pane -p -e -S - -t %\(paneID)\n",
                write: { try await shell.write($0) }
            )
            guard !lines.isEmpty else { return }
            var bytes = Data()
            for (idx, line) in lines.enumerated() {
                bytes.append(OutputDecoder.decode(line))
                if idx < lines.count - 1 {
                    bytes.append(contentsOf: [0x0D, 0x0A])
                }
            }
            driver.feed(bytes)
            capturedPaneIDs.insert(paneID)
        } catch {
            // Capture failure is harmless — the pane just stays empty
            // until new output arrives.
        }
    }

    /// Pull scrollback for any panes in `windowID` that we haven't
    /// captured yet. Triggered when the user switches to a tab whose
    /// panes were never visible — tmux doesn't replay scrollback in
    /// that situation, so the panes would otherwise be blank.
    private func captureWindowPanesIfNeeded(windowID: Int) async {
        guard let win = session.windows.first(where: { $0.id == windowID }),
              let layout = win.layout
        else { return }
        for paneID in layout.paneIDs where !capturedPaneIDs.contains(paneID) {
            await capturePane(paneID: paneID)
        }
    }

    private func parseWindowSnapshot(_ line: String) -> TmuxSession.WindowSnapshot? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return nil }
        let rawID = parts[0]
        guard rawID.first == "@", let id = Int(rawID.dropFirst()) else { return nil }
        let isActive = parts[1] == "1"
        let name = parts[2].isEmpty ? nil : String(parts[2])
        let layout = parts[3].isEmpty ? nil : String(parts[3])
        return TmuxSession.WindowSnapshot(
            id: id,
            name: name,
            isActive: isActive,
            layout: layout
        )
    }

    /// Wrap a session name in single quotes for the tmux command line.
    /// Single-quote any single-quotes inside via the standard
    /// `'\''` close-reopen trick.
    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func loadCredentials() async throws -> Credentials {
        let id = host.keyID ?? keyStore.keys.first?.id
        guard let id else {
            throw NSError(
                domain: "TmuxSessionView",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No SSH key configured for this host."]
            )
        }
        let (meta, data) = try await keyStore.load(
            id,
            prompt: "Authenticate to use SSH key for \(host.name)"
        )
        return KeyStore.credentials(for: meta, data: data)
    }
}
