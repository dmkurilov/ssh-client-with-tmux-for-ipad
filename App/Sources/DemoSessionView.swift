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
    /// /`|`/prefix). Defaults to *off when a HW keyboard is
    /// attached* (the user has Esc/Tab/etc. on real keys already)
    /// and *on otherwise*. User can flip via the `kb` toolbar
    /// button.
    @State private var specialKeysVisible: Bool = !HardwareKeyboardObserver.shared.isAttached

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

    /// Hover state for the exit-fullscreen affordance. iPadOS
    /// trackpad / pencil / mouse pointer drive `.onHover`. Touch
    /// taps don't, so this lights up only when a pointer device
    /// is over the button — useful as both an affordance and a
    /// diagnostic signal.
    @State private var exitFullScreenHovered: Bool = false

    /// While `true`, the rendering layer treats *no* pane as
    /// active. Used as a 200ms feedback blink when `⌘⌥+arrow`
    /// hits a wall — the active pane briefly dims so the user
    /// sees "I tried, but I can't go that way." Set true on the
    /// failed nav attempt and cleared by a delayed `Task`.
    @State private var paneNavBlink: Bool = false

    // `HardwareKeyboardObserver.shared` informs the initial
    // `specialKeysVisible` default. After mount, the user owns the
    // toggle; we don't auto-flip on connect/disconnect to avoid
    // pulling the bar out from under them mid-session.

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
                    SoftKeyboard(onKey: { data in
                        if let pid = backend.state.activePaneID,
                           let pane = backend.pane(pid)
                        {
                            Task { await pane.send(data) }
                        }
                    })
                }
            }
            // Bare exit-fullscreen affordance per UI vision §3.1.
            // No background circle — the icon alone, grey at rest,
            // blue when a pointer device hovers (trackpad / pencil /
            // mouse). Touch taps don't fire `onHover`, so finger
            // users see only grey but the tap still works.
            //
            // `Image` + `.onTapGesture` (not `Button`) because
            // button taps lose to the SwiftTerm view's gesture
            // chain underneath. `.simultaneousGesture` keeps a
            // backup tap path in case the primary loses again.
            //
            // The 8pt internal padding gives the hit area room to
            // breathe without a visual frame; `.contentShape` makes
            // the entire padded rectangle tappable, not just the
            // icon glyph.
            if fullScreen {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.title3)
                    .foregroundStyle(exitFullScreenHovered ? Color.accentColor : Color.gray)
                    .padding(8)
                    .contentShape(Rectangle())
                    .onHover { hovered in
                        exitFullScreenHovered = hovered
                        FileLogger.shared.log("Demo: exit-fs hover → \(hovered)")
                    }
                    .onTapGesture {
                        FileLogger.shared.log("Demo: exit-fs onTapGesture FIRED → setting fullScreen=false")
                        fullScreen = false
                    }
                    .simultaneousGesture(
                        TapGesture()
                            .onEnded {
                                FileLogger.shared.log("Demo: exit-fs simultaneousGesture FIRED")
                                if fullScreen {
                                    fullScreen = false
                                }
                            }
                    )
                    .padding(.top, 4)
                    .padding(.trailing, 6)
                    .zIndex(1)
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
                // Visible "can't go there" feedback for `⌘⌥+arrow`
                // hitting a wall: dim the entire pane region AND
                // overlay a red wash for 200ms. Two visual cues
                // because earlier (subtler) attempts went unnoticed.
                .opacity(paneNavBlink ? 0.3 : 1.0)
                .overlay {
                    if paneNavBlink {
                        Color.red.opacity(0.18)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeInOut(duration: 0.08), value: paneNavBlink)
                .onChange(of: paneNavBlink) { old, new in
                    FileLogger.shared.log("Demo: paneNavBlink \(old) → \(new)")
                }
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        if let win = backend.state.activeWindow, !win.paneIDs.isEmpty {
            if let zoomed = backend.state.zoomedPaneID, win.paneIDs.contains(zoomed) {
                // Zoomed: only the zoomed pane fills the area, no
                // control bar. User exits zoom via `⌘⇧Enter` or the
                // pane menu (still reachable when un-zoomed).
                paneCell(paneID: zoomed, isActive: !paneNavBlink, showControlBar: false)
            } else {
                // `paneNavBlink` overrides the active pane id with
                // nil so every pane renders as inactive — the brief
                // "can't go there" feedback for `⌘⌥+arrow`.
                renderNode(
                    win.layout,
                    activePaneID: paneNavBlink ? nil : win.activePaneID
                )
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
    private func paneCell(paneID: Int, isActive: Bool, showControlBar: Bool = true) -> some View {
        if let pane = backend.pane(paneID) {
            VStack(spacing: 0) {
                if showControlBar {
                    paneControlBar(paneID: paneID, isActive: isActive)
                }
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
                        onNavigatePane: { dir in
                            navigatePane(Self.mapDirection(dir))
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
                .opacity(isActive ? 1.0 : 0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Identity tied to pane id so SwiftUI doesn't recycle a
            // view onto a different pane's driver during a layout
            // shuffle (split, kill).
            .id(paneID)
        } else {
            Color.gray.opacity(0.1)
        }
    }

    /// Solid strip at the top of each pane: `[x] | <title> | [⋯]`.
    /// The whole strip is the drag handle for moving panes onto
    /// other tabs. Active pane gets an accent tint; inactive panes
    /// fade to the system tertiary background.
    ///
    /// Hidden when the pane is zoomed (one pane fills the tab area)
    /// — the user exits zoom via the `⌘⇧Enter` shortcut or the
    /// `…` menu.
    private func paneControlBar(paneID: Int, isActive: Bool) -> some View {
        let title = backend.paneTitle(paneID) ?? "%\(paneID)"
        return HStack(spacing: 8) {
            Button {
                Task { await backend.killPane(paneID) }
                FileLogger.shared.log("Demo: pane x %\(paneID)")
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(title)
                .font(.caption.monospaced())
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Tap on the strip's title selects the pane —
                // matches "tap inactive pane to focus" via a more
                // discoverable target than the empty-pane Color.clear.
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isActive {
                        Task { await backend.selectPane(paneID) }
                        FileLogger.shared.log("Demo: pane title tap %\(paneID)")
                    }
                }

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
                // Move-to is the menu equivalent of drag-to-tab; a
                // target picker UI is TBD.
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
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Without `.fixed`, iOS reverses the menu items when the
            // popover opens upward (panes near the bottom of the
            // screen). `.fixed` keeps declaration order regardless.
            .menuOrder(.fixed)
        }
        .background(
            isActive
                ? Color.accentColor.opacity(0.18)
                : Color(.tertiarySystemBackground)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)
        }
        // The whole strip is the drag handle for moving the pane
        // onto another tab. Buttons inside still receive taps; iOS
        // distinguishes drag-press-and-move from tap.
        .draggable("pane:%\(paneID)") {
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

            // ⌘1..⌘9 → jump to tab N (1-based). Out-of-range
            // shortcuts no-op; we don't shift to "last tab" because
            // that's ambiguous.
            ForEach(1...9, id: \.self) { idx in
                Button("Switch to tab \(idx)") {
                    let windows = backend.state.windows
                    guard idx - 1 < windows.count else {
                        FileLogger.shared.log("Demo: ⌘\(idx) — no tab")
                        return
                    }
                    let target = windows[idx - 1].id
                    Task { await backend.selectWindow(target) }
                    FileLogger.shared.log("Demo: ⌘\(idx) → @\(target)")
                }
                .keyboardShortcut(KeyEquivalent(Character("\(idx)")), modifiers: .command)
            }

            // ⌘⌥+arrow → spatial pane navigation. Edges no-op
            // (`PaneNode.neighbor` returns nil at boundaries).
            Button("Pane right") {
                navigatePane(.right)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Pane left") {
                navigatePane(.left)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Pane up") {
                navigatePane(.up)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Pane down") {
                navigatePane(.down)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    // MARK: - Actions

    /// Translate `TerminalKit`'s direction enum (used by the
    /// UIKit `keyCommands` path) into the App-side enum used by
    /// `PaneNode.neighbor`. Both have the same cases; we just
    /// don't share the type across the module boundary.
    static func mapDirection(_ dir: TerminalNavigationDirection) -> PaneNavigationDirection {
        switch dir {
        case .left:  return .left
        case .right: return .right
        case .up:    return .up
        case .down:  return .down
        }
    }

    private func navigatePane(_ direction: PaneNavigationDirection) {
        guard let pid = backend.state.activePaneID,
              let win = backend.state.activeWindow
        else { return }
        if let next = win.layout.neighbor(of: pid, direction: direction) {
            Task { await backend.selectPane(next) }
            FileLogger.shared.log("⌘⌥\(direction) %\(pid) → %\(next)")
        } else {
            // No neighbor — flash for 200ms as feedback.
            paneNavBlink = true
            FileLogger.shared.log("⌘⌥\(direction) %\(pid) — no neighbor (blink)")
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                paneNavBlink = false
            }
        }
    }

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
