#if canImport(UIKit)
import SwiftUI
import TerminalKit
import ColorSchemes

/// SwiftUI view that talks only to a `SessionBackend`. Lays out the
/// chrome described in `docs/05-ui-vision.md` §3 — top toolbar, tab
/// strip, pane area with `[x ...]` overlay — and drives all
/// state-mutating actions through the backend protocol.
///
/// Used for the demo against `FakeSessionBackend`; the real tmux
/// path will swap the backend without touching this view.
struct DemoSessionView: View {
    /// Existential because views read state through `backend.state`
    /// (an `@Observable` `SessionState`). Reference identity carries
    /// observation; the protocol type is just dispatch.
    let backend: any SessionBackend
    let scheme: ColorSchemes.ColorScheme?
    /// Optional explicit close callback. Used when the demo lives
    /// inside a `.fullScreenCover` *and* a `NavigationStack`, where
    /// `Environment(\.dismiss)` can resolve to "pop nav stack" first
    /// instead of "dismiss cover" — depending on iOS version. If
    /// supplied, this is called instead.
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var fullScreen: Bool = false
    @State private var tabsVisible: Bool = true
    /// One-axis toggle for the slim accessory bar (Esc/Tab/arrows
    /// /`|`/prefix). The SW keyboard itself is owned by iPadOS
    /// based on FR + HW state — we no longer try to override it
    /// from the app side.
    @State private var specialKeysVisible: Bool = true

    @State private var renamingWindowID: Int?
    @State private var renameText: String = ""
    @State private var renamingSession: Bool = false
    @State private var sessionRenameText: String = ""

    @State private var searchVisible: Bool = false
    @State private var searchQuery: String = ""
    /// Drives keyboard focus on the search field — `true` after
    /// `⌘F`, `false` after Esc / close. Without this the user has
    /// to tap into the field after `⌘F` opens it.
    @FocusState private var searchFocused: Bool

    /// Tab the user long-pressed (or tapped `…` on). Drives the
    /// confirmation-dialog action sheet below.
    @State private var actionTab: WindowInfo?

    // `HardwareKeyboardObserver.shared` is still around for future
    // status-indicator UI, but the keyboard refactor no longer
    // needs to read HW state — iPadOS owns SW keyboard visibility
    // and we just toggle our own accessory bar on top.

    /// Color for the 1pt strip between adjacent panes. Contrasts
    /// with the *terminal* color scheme (not iOS light/dark): a
    /// dark scheme gets a near-white separator, a light scheme gets
    /// a near-black one. Falls back to `.separator` if no scheme is
    /// supplied. Computed via Rec.709 luma on the scheme's
    /// background colour.
    private var paneSeparator: Color {
        guard let bg = scheme?.background else { return Color(.separator) }
        let luma = 0.2126 * bg.red + 0.7152 * bg.green + 0.0722 * bg.blue
        return luma < 0.5
            ? Color.white.opacity(0.35)
            : Color.black.opacity(0.35)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                if !fullScreen {
                    topToolbar
                    Divider()
                }
                if tabsVisible {
                    tabStrip
                        .frame(height: 44)
                        .background(Color(.secondarySystemBackground))
                    Divider()
                }
                paneArea
                if specialKeysVisible {
                    AccessoryBar(onKey: { data in
                        if let pid = backend.state.activePaneID,
                           let pane = backend.pane(pid)
                        {
                            Task { await pane.send(data) }
                        }
                    })
                }
            }
            // Near-transparent exit-fullscreen affordance per UI
            // vision §3.1: only visible when toolbar is hidden, and
            // intentionally low-opacity so it doesn't compete with
            // pane content.
            if fullScreen {
                Button {
                    fullScreen = false
                    FileLogger.shared.log("Demo: exit-fullscreen affordance tapped")
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.title3)
                        .padding(8)
                        .background(.thinMaterial, in: Circle())
                }
                .opacity(0.35)
                .padding(8)
            }
        }
        .statusBarHidden(fullScreen)
        // Always ignore the *bottom* safe area — the home-indicator
        // zone is iPad's standard reserved strip and we'd otherwise
        // see it as a grey band below the panes / accessory bar.
        // Top safe area is only ignored in fullscreen (where we
        // also hide the toolbar).
        .ignoresSafeArea(.all, edges: fullScreen ? [.top, .bottom] : .bottom)
        // Hide the wrapping NavigationStack's nav bar — the demo
        // draws its own toolbar.
        .toolbar(.hidden, for: .navigationBar)
        .background(keyboardShortcutSink)
        .background(searchEscapeSink)
        .confirmationDialog(
            actionTab.map { "Tab @\($0.id)" } ?? "Tab",
            isPresented: Binding(
                get: { actionTab != nil },
                set: { if !$0 { actionTab = nil } }
            ),
            titleVisibility: .visible,
            presenting: actionTab
        ) { window in
            Button("Rename tab") {
                beginRenameWindow(window)
                actionTab = nil
            }
            Button("Close tab", role: .destructive) {
                Task { await backend.killWindow(window.id) }
                FileLogger.shared.log("Demo: tab close (action) @\(window.id)")
                actionTab = nil
            }
            Button("Cancel", role: .cancel) { actionTab = nil }
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
            backend.state.sessionID.map { "Rename session $\($0)" } ?? "Rename session",
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
    }

    // MARK: - Top toolbar

    private var topToolbar: some View {
        HStack(spacing: 12) {
            Button {
                close()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
            }

            Spacer()

            HStack(spacing: 6) {
                Text(backend.state.sessionName ?? "demo")
                    .font(.headline)
                    .onLongPressGesture { beginRenameSession() }
                Text("(FAKE)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.orange)
                Button {
                    beginRenameSession()
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button {
                fullScreen.toggle()
                FileLogger.shared.log("Demo: fs toggled → \(fullScreen)")
            } label: {
                Image(systemName: fullScreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
                    .font(.title3)
            }

            Button {
                tabsVisible.toggle()
                FileLogger.shared.log("Demo: tb toggled → \(tabsVisible)")
            } label: {
                Image(systemName: tabsVisible
                    ? "rectangle.split.3x1.fill"
                    : "rectangle.split.3x1")
                    .font(.title3)
            }

            Button {
                specialKeysVisible.toggle()
                FileLogger.shared.log("Demo: special keys → \(specialKeysVisible)")
            } label: {
                Image(systemName: specialKeysVisible
                    ? "keyboard"
                    : "keyboard.chevron.compact.down")
                    .font(.title3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(backend.state.windows) { window in
                    tabButton(window)
                }
                Button {
                    Task { await backend.newWindow() }
                    FileLogger.shared.log("Demo: + new tab")
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func tabButton(_ window: WindowInfo) -> some View {
        let isActive = window.id == backend.state.activeWindowID
        let label = window.name ?? "@\(window.id)"
        return HStack(spacing: 6) {
            Text(label)
                .font(.caption.monospaced())
                .fontWeight(isActive ? .bold : .regular)
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await backend.selectWindow(window.id) }
                    FileLogger.shared.log("Demo: tab tap @\(window.id)")
                }
                .onLongPressGesture {
                    actionTab = window
                    FileLogger.shared.log("Demo: tab long-press @\(window.id)")
                }
            // `…` opens the same action sheet as long-press
            // (rename / close). Replaces the previous `x` button —
            // tab close is no longer a single-tap action.
            Button {
                actionTab = window
                FileLogger.shared.log("Demo: tab ⋯ tap @\(window.id)")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // Accept dropped panes from another tab. We encode the
        // dragged pane id as `pane:%<id>` (see paneControlOverlay)
        // so the destination can demux without a custom
        // Transferable. `isTargeted` is unused here — visual
        // affordance for in-flight drag is a future polish item.
        .dropDestination(for: String.self) { items, _ in
            for item in items {
                if let pid = parseDraggedPaneID(item) {
                    Task { await backend.movePane(paneID: pid, toWindow: window.id) }
                    FileLogger.shared.log("Demo: drop pane %\(pid) → tab @\(window.id)")
                    return true
                }
            }
            return false
        }
    }

    private func parseDraggedPaneID(_ s: String) -> Int? {
        guard s.hasPrefix("pane:%") else { return nil }
        return Int(s.dropFirst("pane:%".count))
    }

    // MARK: - Pane area

    @ViewBuilder
    private var paneArea: some View {
        VStack(spacing: 0) {
            if searchVisible {
                searchBar
                Divider()
            }
            paneContent
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        if let win = backend.state.activeWindow, !win.paneIDs.isEmpty {
            if let zoomed = backend.state.zoomedPaneID, win.paneIDs.contains(zoomed) {
                // Zoomed: only the zoomed pane fills the area.
                // Active flag forced to true since user just zoomed
                // it; tmux's behaviour is the same.
                paneCell(paneID: zoomed, isActive: true)
            } else {
                renderNode(win.layout, activePaneID: win.activePaneID)
            }
        } else {
            VStack(spacing: 8) {
                Text("No active window")
                    .font(.title3)
                Button("New window") {
                    Task { await backend.newWindow() }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Recursive renderer for `PaneNode`. Returns `AnyView` because
    /// the natural `some View` return shape varies by case (leaf vs
    /// HStack vs VStack); the existing `TmuxSessionView.paneTree`
    /// uses the same pattern. Type erasure costs an allocation per
    /// node, which is fine for the small trees a real tmux layout
    /// produces.
    ///
    /// Inter-pane separators: each split sets its own background to
    /// `paneSeparator`, and lays its children out with `spacing: 1`.
    /// The 1pt gap exposes the parent's background colour as a thin
    /// contrast line — light on dark schemes, dark on light schemes.
    private func renderNode(_ node: PaneNode, activePaneID: Int?) -> AnyView {
        switch node {
        case .leaf(let pid):
            return AnyView(paneCell(paneID: pid, isActive: pid == activePaneID))
        case .split(.horizontal, let kids):
            return AnyView(
                HStack(spacing: 1) {
                    ForEach(Array(kids.enumerated()), id: \.offset) { _, kid in
                        renderNode(kid, activePaneID: activePaneID)
                    }
                }
                .background(paneSeparator)
            )
        case .split(.vertical, let kids):
            return AnyView(
                VStack(spacing: 1) {
                    ForEach(Array(kids.enumerated()), id: \.offset) { _, kid in
                        renderNode(kid, activePaneID: activePaneID)
                    }
                }
                .background(paneSeparator)
            )
        }
    }

    /// Inline search bar shown above the pane area when the user
    /// presses `⌘F`. Prev/next are wired to disabled buttons for
    /// now — actual scrollback search needs a SwiftTerm API call
    /// we haven't surfaced yet. The shell is in place so the rest
    /// of the UI behaves correctly when search lands.
    ///
    /// `Esc` is intercepted by a hidden `.keyboardShortcut(.escape)`
    /// button rendered only while the search bar is visible — see
    /// the `.background` overlay in `body`. That prevents Esc from
    /// reaching whatever defaultchain handler currently dismisses
    /// the whole session.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in scrollback…", text: $searchQuery)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .focused($searchFocused)
                // Intercept Esc *at the focused field* so it doesn't
                // bubble up to NavigationStack's default pop-on-cancel
                // (which dismisses the whole demo). `.handled`
                // explicitly stops propagation.
                .onKeyPress(.escape) {
                    closeSearch()
                    return .handled
                }
            Text("not yet implemented")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button {
                FileLogger.shared.log("Demo: search prev (TBD) query=\(searchQuery)")
            } label: { Image(systemName: "chevron.up") }
                .disabled(true)
            Button {
                FileLogger.shared.log("Demo: search next (TBD) query=\(searchQuery)")
            } label: { Image(systemName: "chevron.down") }
                .disabled(true)
            Button {
                closeSearch()
            } label: { Image(systemName: "xmark") }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    /// Hidden Esc-handler attached only while the search bar is up.
    /// Mounting it conditionally means Esc reaches the terminal
    /// (where vim/etc. need it) when the bar is closed.
    @ViewBuilder
    private var searchEscapeSink: some View {
        if searchVisible {
            Button("Close search (Esc)") {
                closeSearch()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    private func closeSearch() {
        searchVisible = false
        searchQuery = ""
        searchFocused = false
        FileLogger.shared.log("Demo: search closed")
    }

    private func openSearch() {
        searchVisible = true
        searchQuery = ""
        // Focus must be set *after* the bar mounts. A tiny task
        // dispatch is enough — SwiftUI runs the view update first,
        // then yields back to the main loop, then we set focus.
        Task { @MainActor in
            searchFocused = true
        }
        FileLogger.shared.log("Demo: search opened")
    }

    @ViewBuilder
    private func paneCell(paneID: Int, isActive: Bool) -> some View {
        if let pane = backend.pane(paneID) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    SwiftTermView(
                        driver: pane.driver,
                        scheme: scheme,
                        isActive: isActive,
                        onInput: { data in
                            Task { await pane.send(data) }
                        },
                        onSizeChange: { cols, rows in
                            Task { await pane.resize(cols: cols, rows: rows) }
                        },
                        onLog: { msg in
                            FileLogger.shared.log("Demo[%\(paneID)] \(msg)")
                        }
                    )
                    .disabled(!isActive)
                    if !isActive {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task { await backend.selectPane(paneID) }
                                FileLogger.shared.log("Demo: pane tap %\(paneID)")
                            }
                    }
                }
                paneControlOverlay(paneID: paneID)
                    .padding(6)
            }
            .opacity(isActive ? 1.0 : 0.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Identity tied to pane id so SwiftUI doesn't recycle a
            // view onto a different pane's driver during a layout
            // shuffle (split, kill).
            .id(paneID)
        } else {
            Color.gray.opacity(0.1)
        }
    }

    /// Per-pane control strip rendered in the top-right corner.
    /// Near-transparent at rest per UI vision §3.4. Touch users tap
    /// the `x` to close, `...` to open the menu, or drag the strip
    /// itself to move the pane onto another tab.
    private func paneControlOverlay(paneID: Int) -> some View {
        HStack(spacing: 2) {
            // Drag handle. iPadOS turns press-and-drag into a drag
            // gesture; quick taps still fire the `x` and `...`
            // children below. Per UI vision §3.4 the strip itself
            // is the handle — no separate drag dot.
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 4)

            Button {
                Task { await backend.killPane(paneID) }
                FileLogger.shared.log("Demo: pane x %\(paneID)")
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    Task { await backend.splitPane(direction: .horizontal, target: paneID) }
                    FileLogger.shared.log("Demo: pane split → %\(paneID)")
                } label: {
                    Label("Split pane vertically", systemImage: "rectangle.split.2x1")
                }
                Button {
                    Task { await backend.splitPane(direction: .vertical, target: paneID) }
                    FileLogger.shared.log("Demo: pane split ↓ %\(paneID)")
                } label: {
                    Label("Split pane horizontally", systemImage: "rectangle.split.1x2")
                }
                Button {
                    Task { await backend.toggleZoom(paneID: paneID) }
                    FileLogger.shared.log("Demo: pane zoom toggle %\(paneID)")
                } label: {
                    Label("Toggle pane zoom", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Divider()
                // Move-to is the menu equivalent of drag-to-tab;
                // a target picker UI is TBD.
                Button("Move pane to …") {
                    FileLogger.shared.log("Demo: pane move %\(paneID) (TBD)")
                }
                .disabled(true)
                Divider()
                // Select all / Copy / Paste / Insert image are
                // placeholders for now — the menu structure matches
                // `docs/05-ui-vision.md` §3.4 so the layout doesn't
                // shift when those land.
                Button("Select all") {
                    FileLogger.shared.log("Demo: select all %\(paneID) (TBD)")
                }
                .disabled(true)
                Button("Copy") {
                    FileLogger.shared.log("Demo: copy %\(paneID) (TBD)")
                }
                .disabled(true)
                Button("Paste") {
                    FileLogger.shared.log("Demo: paste %\(paneID) (TBD)")
                }
                .disabled(true)
                Button("Insert image to current working directory") {
                    FileLogger.shared.log("Demo: insert image %\(paneID) (TBD)")
                }
                .disabled(true)
                Divider()
                Button("Clear buffer") {
                    FileLogger.shared.log("Demo: clear buffer %\(paneID) (TBD)")
                }
                .disabled(true)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Without `.fixed`, iOS reverses the menu items when the
            // popover opens upward (panes near the bottom of the
            // screen). `.fixed` keeps declaration order regardless.
            .menuOrder(.fixed)
        }
        .foregroundStyle(.secondary)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
        .opacity(0.55)
        // Encode pane id as a String so we don't have to define a
        // custom Transferable. `parseDraggedPaneID` on the tab
        // dropDestination demuxes.
        .draggable("pane:%\(paneID)") {
            // Drag preview: a compact pill so the user sees what
            // they're carrying without obscuring the destination.
            Text("pane %\(paneID)")
                .font(.caption.monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
        }
    }

    // MARK: - Hotkeys

    /// Hidden buttons that register hardware-keyboard shortcuts via
    /// `.keyboardShortcut`. Cmd-modified keys go through the iOS
    /// menu/responder chain *before* reaching SwiftTerm, so this is
    /// the cleanest place to bind them.
    ///
    /// Mapping (matches `docs/05-ui-vision.md` §5):
    ///   - ⌘F        → Find in scrollback (toggle search bar)
    ///   - ⌘⇧F       → Toggle app-level fullscreen
    ///   - ⌘⇧Enter   → Toggle pane zoom (resize-pane -Z equivalent)
    ///   - ⌘⇧T       → Toggle tab strip visibility
    ///   - ⌘D        → Split pane vertically (panes side by side)
    ///   - ⌘⇧D       → Split pane horizontally (panes stacked)
    ///   - ⌘W        → Close active pane
    ///   - ⌘T        → New tab (window)
    private var keyboardShortcutSink: some View {
        ZStack {
            Button("Find") {
                if searchVisible {
                    closeSearch()
                } else {
                    openSearch()
                }
                FileLogger.shared.log("Demo: ⌘F search → \(searchVisible)")
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Toggle fullscreen") {
                fullScreen.toggle()
                FileLogger.shared.log("Demo: ⌘⇧F fs → \(fullScreen)")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button("Toggle pane zoom") {
                guard let target = backend.state.activePaneID else { return }
                Task { await backend.toggleZoom(paneID: target) }
                FileLogger.shared.log("Demo: ⌘⇧Enter zoom %\(target)")
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])

            Button("Toggle tab strip") {
                tabsVisible.toggle()
                FileLogger.shared.log("Demo: ⌘⇧T tabs → \(tabsVisible)")
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button("Split right") {
                guard let target = backend.state.activePaneID else { return }
                Task { await backend.splitPane(direction: .horizontal, target: target) }
                FileLogger.shared.log("Demo: ⌘D split-right")
            }
            .keyboardShortcut("d", modifiers: .command)

            Button("Split down") {
                guard let target = backend.state.activePaneID else { return }
                Task { await backend.splitPane(direction: .vertical, target: target) }
                FileLogger.shared.log("Demo: ⌘⇧D split-down")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("Close pane") {
                guard let target = backend.state.activePaneID else { return }
                Task { await backend.killPane(target) }
                FileLogger.shared.log("Demo: ⌘W close-pane")
            }
            .keyboardShortcut("w", modifiers: .command)

            Button("New tab") {
                Task { await backend.newWindow() }
                FileLogger.shared.log("Demo: ⌘T new-tab")
            }
            .keyboardShortcut("t", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    // MARK: - Actions

    private func close() {
        FileLogger.shared.log("Demo: close pressed")
        Task {
            await backend.disconnect()
            if let onClose {
                onClose()
            } else {
                dismiss()
            }
        }
    }

    private func beginRenameWindow(_ window: WindowInfo) {
        renameText = window.name ?? ""
        renamingWindowID = window.id
        FileLogger.shared.log("Demo: rename window @\(window.id) (begin)")
    }

    private func commitRenameWindow() {
        guard let id = renamingWindowID else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingWindowID = nil
        renameText = ""
        guard !trimmed.isEmpty else { return }
        Task { await backend.renameWindow(id, name: trimmed) }
        FileLogger.shared.log("Demo: rename window @\(id) → \(trimmed)")
    }

    private func beginRenameSession() {
        sessionRenameText = backend.state.sessionName ?? ""
        renamingSession = true
        FileLogger.shared.log("Demo: rename session (begin)")
    }

    private func commitRenameSession() {
        let trimmed = sessionRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingSession = false
        sessionRenameText = ""
        guard !trimmed.isEmpty else { return }
        Task { await backend.renameSession(trimmed) }
        FileLogger.shared.log("Demo: rename session → \(trimmed)")
    }
}

#Preview {
    DemoSessionView(
        backend: FakeSessionBackend(echoDelay: .seconds(1), paneCount: 2),
        scheme: BuiltInSchemes.all.first
    )
}
#endif
