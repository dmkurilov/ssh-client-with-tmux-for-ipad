#if canImport(UIKit)
import SwiftUI
import UIKit
import TerminalKit
import ColorSchemes

/// One drag handle, implemented as a single `UIView` that owns
/// both the pan gesture *and* the pointer interaction. Earlier we
/// had two layers (a SwiftUI `Color` with `.gesture` + a sibling
/// `UIPointerInteraction` view in a `ZStack`); SwiftUI's gesture
/// system intercepted hover events before they reached the
/// embedded UIView, so the cursor never changed. Putting both in
/// the same UIView fixes that.
///
/// `onDragChange` fires continuously during the gesture with the
/// signed pixel delta along the drag axis. `onDragEnd` fires once
/// when the gesture ends with the final delta. Finger users get
/// the gesture; iPad pointer users also get the resize cursor.
private struct PaneDividerHandle: UIViewRepresentable {
    let axis: EngineDivider.Axis
    let onDragChange: (CGFloat) -> Void
    let onDragEnd: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = true
        view.backgroundColor = .clear

        let interaction = UIPointerInteraction(delegate: context.coordinator)
        view.addInteraction(interaction)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        // Touch + indirect pointer (trackpad/mouse) both fire pan.
        pan.allowedScrollTypesMask = .continuous
        view.addGestureRecognizer(pan)

        context.coordinator.view = view
        return view
    }

    func updateUIView(_: UIView, context: Context) {
        context.coordinator.axis = axis
        context.coordinator.onDragChange = onDragChange
        context.coordinator.onDragEnd = onDragEnd
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(axis: axis, onDragChange: onDragChange, onDragEnd: onDragEnd)
    }

    final class Coordinator: NSObject, UIPointerInteractionDelegate {
        var axis: EngineDivider.Axis
        var onDragChange: (CGFloat) -> Void
        var onDragEnd: (CGFloat) -> Void
        weak var view: UIView?

        init(axis: EngineDivider.Axis,
             onDragChange: @escaping (CGFloat) -> Void,
             onDragEnd: @escaping (CGFloat) -> Void)
        {
            self.axis = axis
            self.onDragChange = onDragChange
            self.onDragEnd = onDragEnd
        }

        func pointerInteraction(_ i: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
            let path = Self.makeDoubleArrowPath(axis: axis)
            let constrainedAxes: UIAxis = (axis == .vertical) ? .horizontal : .vertical
            return UIPointerStyle(shape: .path(path), constrainedAxes: constrainedAxes)
        }

        /// Double-arrow filled polygon — `↔` for vertical dividers
        /// (drag horizontally), `↕` for horizontal dividers. Built
        /// from a single closed path so the system fills it once and
        /// gives the pointer a clear "this is a resize handle" feel.
        /// The path is centered around `(0, 0)` as `UIPointerShape`
        /// expects.
        private static func makeDoubleArrowPath(axis: EngineDivider.Axis) -> UIBezierPath {
            let arrowLen: CGFloat = 5     // length of each arrow head
            let arrowFlare: CGFloat = 4   // half-thickness at the arrow's base
            let barHalfLen: CGFloat = 5   // half-length of the connecting bar
            let barHalfThick: CGFloat = 1 // half-thickness of the bar
            let path = UIBezierPath()
            switch axis {
            case .vertical:
                // ←─→ shape, horizontal axis.
                path.move(to:    CGPoint(x: -(barHalfLen + arrowLen), y: 0))
                path.addLine(to: CGPoint(x: -barHalfLen,              y: -arrowFlare))
                path.addLine(to: CGPoint(x: -barHalfLen,              y: -barHalfThick))
                path.addLine(to: CGPoint(x: barHalfLen,               y: -barHalfThick))
                path.addLine(to: CGPoint(x: barHalfLen,               y: -arrowFlare))
                path.addLine(to: CGPoint(x: barHalfLen + arrowLen,    y: 0))
                path.addLine(to: CGPoint(x: barHalfLen,               y: arrowFlare))
                path.addLine(to: CGPoint(x: barHalfLen,               y: barHalfThick))
                path.addLine(to: CGPoint(x: -barHalfLen,              y: barHalfThick))
                path.addLine(to: CGPoint(x: -barHalfLen,              y: arrowFlare))
                path.close()
            case .horizontal:
                // ↑─↓ shape, vertical axis (same path, transposed).
                path.move(to:    CGPoint(x: 0,           y: -(barHalfLen + arrowLen)))
                path.addLine(to: CGPoint(x: -arrowFlare, y: -barHalfLen))
                path.addLine(to: CGPoint(x: -barHalfThick, y: -barHalfLen))
                path.addLine(to: CGPoint(x: -barHalfThick, y: barHalfLen))
                path.addLine(to: CGPoint(x: -arrowFlare, y: barHalfLen))
                path.addLine(to: CGPoint(x: 0,           y: barHalfLen + arrowLen))
                path.addLine(to: CGPoint(x: arrowFlare,  y: barHalfLen))
                path.addLine(to: CGPoint(x: barHalfThick, y: barHalfLen))
                path.addLine(to: CGPoint(x: barHalfThick, y: -barHalfLen))
                path.addLine(to: CGPoint(x: arrowFlare,  y: -barHalfLen))
                path.close()
            }
            return path
        }

        @objc func handlePan(_ gr: UIPanGestureRecognizer) {
            guard let view else { return }
            let translation = gr.translation(in: view)
            let delta: CGFloat = axis == .vertical ? translation.x : translation.y
            switch gr.state {
            case .changed:
                onDragChange(delta)
            case .ended, .cancelled, .failed:
                onDragEnd(delta)
            default:
                break
            }
        }
    }
}

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
    /// `false` for production-mode (real `TmuxSessionBackend`),
    /// `true` for the demo-only `FakeSessionBackend` so users can
    /// see they're not connected to anything real.
    var showFakeBadge: Bool = true
    /// Optional explicit close callback. Used when the demo lives
    /// inside a `.fullScreenCover` *and* a `NavigationStack`, where
    /// `Environment(\.dismiss)` can resolve to "pop nav stack" first
    /// instead of "dismiss cover" — depending on iOS version. If
    /// supplied, this is called instead.
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var fullScreen: Bool = false
    @State private var tabsVisible: Bool = true
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

    /// Cell metrics for this session — measured once from the
    /// default monospace font. Drives the "tmux owns the grid"
    /// invariant: pane area pixel size ÷ `cellMetrics` = the cell
    /// grid we ask tmux to use; per-pane pixel sizes = pane cell
    /// counts × `cellMetrics`.
    @State private var cellMetrics: CellMetrics = .defaultMetrics()

    /// Minimum cell counts for a pane after split. iTerm2 uses
    /// similar values; the goal is a pane that's still usable for
    /// at least a shell prompt + one line of feedback.
    private static let minPaneCols = 20
    private static let minPaneRows = 5

    /// `true` iff splitting `paneID` along `direction` would leave
    /// both halves at or above the minimum cell counts. Used to
    /// disable split actions before they hit tmux. When we don't
    /// have a cell layout (fake backend, brief window before the
    /// first `%layout-change`), we permit the split — tmux will
    /// reject if it really doesn't fit.
    private func canSplit(paneID: Int, direction: SplitDirection) -> Bool {
        guard let cellLayout = backend.state.activeWindow?.cellLayout,
              let pane = cellLayout.panes.first(where: { $0.paneID == paneID })
        else {
            return true
        }
        switch direction {
        case .horizontal:
            // Side-by-side: each half needs minCols. +1 cell for
            // the divider tmux inserts between panes.
            return pane.cols >= 2 * Self.minPaneCols + 1
        case .vertical:
            return pane.rows >= 2 * Self.minPaneRows + 1
        }
    }

    /// `true` once we've confirmed tmux's layout reflects a request
    /// we made. Until then the pane area shows a small spinner so
    /// we don't paint stale-grid content from before the handshake.
    @State private var gridReady: Bool = false
    /// Most recent computed engine layout (per-pane pixel rects +
    /// hidden flag) for the *active* window. Mirror of
    /// `layoutCache[activeWindowID].layouts`.
    @State private var paneFinalLayouts: [PaneFinalLayout] = []
    /// Active window's draggable boundaries between panes. Mirror
    /// of `layoutCache[activeWindowID].dividers`. Rendered as
    /// invisible 8pt-thick gesture overlays.
    @State private var paneDividers: [EngineDivider] = []
    /// Measured pane-area pixel size from the inner GeometryReader.
    @State private var paneAreaSize: CGSize = .zero
    /// Drag state for the currently-active divider, if any. Lives
    /// only between drag-begin and drop; `nil` outside that window.
    /// `previewOffset` is the proposed pixel delta along the drag
    /// axis — converted to cells on drop.
    @State private var activeDividerDrag: DividerDragState? = nil

    private struct DividerDragState: Equatable {
        let divider: EngineDivider
        var previewOffset: CGFloat
    }
    /// Per-window cache of engine output. Avoids re-running the
    /// engine — and re-issuing per-pane `resize-pane` to tmux —
    /// every time the user taps a tab. Without this, tmux's
    /// sequential resize-pane drift would shift `%1` / `%2` by one
    /// row on every tab switch (see `debug.log.55`). Invalidated
    /// per-window when its topology changes, globally when the
    /// pane area changes (rotation / chrome toggle / etc.).
    @State private var layoutCache: [Int: CachedWindowLayout] = [:]


    /// Captures everything we need to decide "still valid": the
    /// topology shape the engine apportioned against, the pane area
    /// that was available, and the resulting per-pane layout.
    private struct CachedWindowLayout {
        let topology: LayoutCellNode
        let paneArea: CGSize
        let layouts: [PaneFinalLayout]
        let dividers: [EngineDivider]
    }

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
                if showFakeBadge {
                    Text("(FAKE)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange)
                }
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
            GeometryReader { geo in
                paneAreaContent(window: win, area: geo.size)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .onAppear {
                        // Each fresh appearance gets a clean cache.
                        // Defensive: SwiftUI sometimes keeps the
                        // same DemoSessionView identity across a
                        // disconnect/reconnect, which would leave
                        // stale per-window cached layouts from the
                        // previous tmux session. Clearing on appear
                        // forces the first engine pass on (re)attach.
                        layoutCache.removeAll()
                        paneAreaSize = geo.size
                        syncAllWindowLayouts()
                    }
                    .onChange(of: geo.size) { _, new in
                        // Pane area moved — every window's cached
                        // layout was sized to the old area and is
                        // now stale. Drop the whole cache so
                        // every tab recomputes.
                        paneAreaSize = new
                        layoutCache.removeAll()
                        syncAllWindowLayouts()
                    }
                    // Tab tap: `activeWindowID` changes but the
                    // window trees don't, so the `cellTree`
                    // .onChange below wouldn't fire. We still need
                    // to update `paneFinalLayouts` to the new
                    // active window's cached layout (or compute
                    // it if first visit). syncAllWindowLayouts is
                    // cheap when caches are warm.
                    .onChange(of: backend.state.activeWindowID) { _, _ in
                        syncAllWindowLayouts()
                    }
                    // Watch *every* window's cellTree, not just the
                    // active one. tmux pushes `%layout-change`
                    // events for any window — including external
                    // resizes from a second client connected to the
                    // same session — and we want those reflected
                    // for every tab, not just the visible one.
                    .onChange(of: backend.state.windows.map { $0.cellTree }) { _, _ in
                        syncAllWindowLayouts()
                    }
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

    /// Tree-structural equality: same split tree shape and same
    /// pane ids at the leaves, ignoring cell counts. Used as the
    /// first half of the cache-hit check.
    private static func sameTopology(_ a: LayoutCellNode, _ b: LayoutCellNode) -> Bool {
        switch (a.kind, b.kind) {
        case (.leaf(let pa), .leaf(let pb)):
            return pa == pb
        case (.horizontal(let ka), .horizontal(let kb)),
             (.vertical(let ka), .vertical(let kb)):
            return ka.count == kb.count
                && zip(ka, kb).allSatisfy { sameTopology($0, $1) }
        default:
            return false
        }
    }


    /// Re-run `PaneLayoutEngine` against the current pane area + the
    /// active window's tmux-authored cell tree. If the engine's
    /// per-pane decisions differ from what we last sent, ship the
    /// new sizes to the backend (which will issue per-pane
    /// `resize-pane` and recapture). Idempotent — repeated calls
    /// with no state change are silent.
    /// Run the engine for `win`. The function is window-agnostic:
    /// it caches per `win.id` and only touches the *active*-window
    /// rendering state (`paneFinalLayouts`, `gridReady`). Used both
    /// directly for the active window and indirectly from
    /// `syncAllWindowLayouts` for background-warming non-active tabs.
    private func syncLayoutFromEngine(window win: WindowInfo) {
        guard paneAreaSize.width > 0, paneAreaSize.height > 0 else { return }
        let isActive = (win.id == backend.state.activeWindowID)
        guard let tree = win.cellTree else {
            // No tmux layout yet for this window (just created and
            // we haven't pulled its layout back, fake backend, etc.).
            // If this is the active window, *clear* paneFinalLayouts
            // so the renderer falls through to the proportional
            // fallback using the new window's topology — otherwise
            // we'd keep painting the previously-active window's
            // pane rectangles + pane ids, which is exactly the
            // "new tab shows the old tab's content" bug.
            if isActive {
                if !paneFinalLayouts.isEmpty { paneFinalLayouts = [] }
                if !paneDividers.isEmpty { paneDividers = [] }
                if !gridReady { gridReady = true }
            }
            return
        }
        // Cache hit: same window, same topology, same pane area.
        // Drift in cell counts is *expected* (tmux's resize-pane is
        // sequential and our chrome math eats a few cells per
        // split), so we ignore it.
        if let cached = layoutCache[win.id],
           cached.paneArea == paneAreaSize,
           Self.sameTopology(cached.topology, tree)
        {
            if isActive {
                paneFinalLayouts = cached.layouts
                paneDividers = cached.dividers
                if !gridReady { gridReady = true }
            }
            return
        }
        // Cache miss: compute fresh and send to tmux.
        let output = PaneLayoutEngine.layout(
            tree: tree,
            area: paneAreaSize,
            cellMetrics: cellMetrics
        )
        layoutCache[win.id] = CachedWindowLayout(
            topology: tree,
            paneArea: paneAreaSize,
            layouts: output.layouts,
            dividers: output.dividers
        )
        // Gate the spinner only on the *first* layout for this
        // window — i.e. when we have no prior layouts to show.
        // Subsequent cache misses (a resize, a split, a nav-driven
        // promote) update the existing layout in place. Toggling
        // gridReady false→true on every cellTree change was forcing
        // SwiftUI to swap `paneAreaContent` branches (engineDriven
        // → ProgressView → engineDriven), which tears down every
        // TerminalHost. With many rapid navs the SwiftTerm churn
        // accumulated faster than ARC could keep up and brought
        // the simulator to its knees.
        let wasEmpty = isActive && paneFinalLayouts.isEmpty
        if isActive {
            paneFinalLayouts = output.layouts
            paneDividers = output.dividers
            if wasEmpty { gridReady = false }
        }
        let entries = output.layouts.map { (paneID: $0.paneID, cols: $0.cellCols, rows: $0.cellRows) }
        FileLogger.shared.log("Demo: engine for @\(win.id) → window=\(output.windowCellCols)x\(output.windowCellRows) panes: \(entries.map { "%\($0.paneID)=\($0.cols)x\($0.rows)" }.joined(separator: " "))")
        Task {
            await backend.applyWindowLayout(
                windowID: win.id,
                cellCols: output.windowCellCols,
                cellRows: output.windowCellRows,
                panes: entries
            )
            await MainActor.run {
                if isActive && !self.gridReady { self.gridReady = true }
            }
        }
    }

    /// Run the engine for every window in the session — active
    /// first (so its spinner clears as fast as possible), then the
    /// rest in background. Cache hits early-return; misses
    /// trigger compute + `resize-pane`. Triggered on attach, on
    /// pane-area change (rotation / chrome toggle), and on any
    /// window's `cellTree` change.
    private func syncAllWindowLayouts() {
        let windows = backend.state.windows
        let activeID = backend.state.activeWindowID
        if let activeID, let active = windows.first(where: { $0.id == activeID }) {
            syncLayoutFromEngine(window: active)
        }
        for window in windows where window.id != activeID {
            syncLayoutFromEngine(window: window)
        }
    }

    @ViewBuilder
    private func paneAreaContent(window win: WindowInfo, area: CGSize) -> some View {
        if !gridReady {
            VStack(spacing: 8) {
                ProgressView()
                Text("Sizing terminal…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: area.width, height: area.height)
        } else if let zoomed = backend.state.zoomedPaneID, win.paneIDs.contains(zoomed) {
            paneCell(
                paneID: zoomed,
                isActive: !paneNavBlink,
                showControlBar: false,
                cellRect: nil,
                fallbackPixelSize: area
            )
        } else if !paneFinalLayouts.isEmpty {
            engineDrivenPanes(window: win, area: area)
        } else {
            // Engine hasn't produced output yet (no cell tree from
            // backend — fake backend, or first frame on attach).
            // Fall back to the legacy proportional renderer.
            proportionalPanes(window: win, area: area)
        }
    }

    @ViewBuilder
    private func engineDrivenPanes(window win: WindowInfo, area: CGSize) -> some View {
        let active = paneNavBlink ? nil : win.activePaneID
        ZStack(alignment: .topLeading) {
            paneSeparator
            // Render every pane the engine apportioned, including
            // panes flagged `hidden=true`. Filtering them out left
            // the apportioned space empty — the grey strip at the
            // bottom of screen-109. The `hidden` flag is still
            // useful for nav 2b (where we promote a too-small
            // target), but mounting is unconditional.
            ForEach(paneFinalLayouts, id: \.paneID) { p in
                let outer = p.outerRect
                let rect = PaneCellRect(
                    paneID: p.paneID,
                    x: 0, y: 0,
                    cols: p.cellCols, rows: p.cellRows
                )
                paneCell(
                    paneID: p.paneID,
                    isActive: p.paneID == active,
                    cellRect: rect,
                    fallbackPixelSize: outer.size
                )
                .frame(width: outer.width, height: outer.height)
                .position(x: outer.midX, y: outer.midY)
            }
            // Drag handles sit on top of the panes so touches land
            // on the divider's hit rect instead of the
            // SwiftTermView underneath.
            ForEach(Array(paneDividers.enumerated()), id: \.offset) { _, divider in
                dragHandle(for: divider)
            }
            // Live preview overlay: a thin colored bar at the
            // *proposed* divider position while the user drags. The
            // panes themselves don't move until drop.
            if let drag = activeDividerDrag {
                dividerPreview(drag)
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
    }

    /// One draggable handle for a divider — implemented as a
    /// single UIKit view (`PaneDividerHandle`) so the pan gesture
    /// and the pointer interaction live on the same responder.
    /// Pointer-equipped iPad users see a beam-shaped resize cursor
    /// constrained to the drag axis; touch users get the pan
    /// gesture as usual. The preview overlay is driven from
    /// `activeDividerDrag`.
    @ViewBuilder
    private func dragHandle(for divider: EngineDivider) -> some View {
        PaneDividerHandle(
            axis: divider.axis,
            onDragChange: { delta in
                activeDividerDrag = DividerDragState(divider: divider, previewOffset: delta)
            },
            onDragEnd: { delta in
                commitDividerDrag(divider, deltaPoints: delta)
                activeDividerDrag = nil
            }
        )
        .frame(width: divider.hitRect.width, height: divider.hitRect.height)
        .position(x: divider.hitRect.midX, y: divider.hitRect.midY)
    }

    /// Translates the pixel delta into cell delta, decides which
    /// pane to push and in what direction, invalidates the cache for
    /// this window so the engine re-runs on the new sizes, and
    /// fires `backend.resizePane`. tmux may reject; we accept.
    private func commitDividerDrag(_ divider: EngineDivider, deltaPoints: CGFloat) {
        let cellSize = divider.axis == .vertical
            ? cellMetrics.cellWidth
            : cellMetrics.cellHeight
        let deltaCells = Int(deltaPoints / cellSize)
        guard deltaCells != 0 else { return }
        // Pick the reference pane and direction. For a vertical
        // divider: drag-right (positive delta) pushes the *left*
        // pane's right edge right; drag-left pushes the *right*
        // pane's left edge left.
        let target: Int
        let direction: ResizeDirection
        switch divider.axis {
        case .vertical:
            if deltaCells > 0 {
                target = divider.beforePaneID
                direction = .right
            } else {
                target = divider.afterPaneID
                direction = .left
            }
        case .horizontal:
            if deltaCells > 0 {
                target = divider.beforePaneID
                direction = .down
            } else {
                target = divider.afterPaneID
                direction = .up
            }
        }
        let magnitude = abs(deltaCells)
        if let winID = backend.state.activeWindowID {
            // Cache stays warm on same-topology, but the sizes we
            // get back from tmux will be different — and we need
            // the engine to re-flow against the new tree. Drop the
            // cached entry for this window so the next cellTree
            // change misses and re-engineers.
            layoutCache.removeValue(forKey: winID)
        }
        FileLogger.shared.log("Demo: drag %\(target) \(direction) \(magnitude) cells")
        Task {
            await backend.resizePane(target, direction: direction, cells: magnitude)
            // For backends that mutate cellTree synchronously (fake),
            // run the sync now to pick up the new layout. For tmux,
            // the layout-change event will fire it.
            await MainActor.run { syncAllWindowLayouts() }
        }
    }

    /// A 2pt-thick colored line drawn at the proposed divider
    /// position while the user drags. Doesn't actually resize the
    /// panes — they snap on drop. Matches the visual you sketched
    /// (preview while dragging, commit on drop).
    @ViewBuilder
    private func dividerPreview(_ drag: DividerDragState) -> some View {
        let d = drag.divider
        let previewRect: CGRect = {
            switch d.axis {
            case .vertical:
                return CGRect(
                    x: d.hitRect.midX + drag.previewOffset - 1,
                    y: d.hitRect.minY,
                    width: 2,
                    height: d.hitRect.height
                )
            case .horizontal:
                return CGRect(
                    x: d.hitRect.minX,
                    y: d.hitRect.midY + drag.previewOffset - 1,
                    width: d.hitRect.width,
                    height: 2
                )
            }
        }()
        Color.accentColor
            .frame(width: previewRect.width, height: previewRect.height)
            .position(x: previewRect.midX, y: previewRect.midY)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func proportionalPanes(window win: WindowInfo, area: CGSize) -> some View {
        let entries: [PaneLayoutEntry] = win.layout
            .paneRects(in: CGRect(origin: .zero, size: area))
            .map { PaneLayoutEntry(id: $0.id, frame: $0.frame) }
        let active = paneNavBlink ? nil : win.activePaneID
        ZStack(alignment: .topLeading) {
            paneSeparator
            ForEach(entries) { entry in
                let f = entry.frame.insetBy(dx: 0.5, dy: 0.5)
                paneCell(
                    paneID: entry.id,
                    isActive: entry.id == active,
                    cellRect: nil,
                    fallbackPixelSize: f.size
                )
                .frame(width: f.width, height: f.height)
                .position(x: f.midX, y: f.midY)
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
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
    private func paneCell(
        paneID: Int,
        isActive: Bool,
        showControlBar: Bool = true,
        cellRect: PaneCellRect? = nil,
        fallbackPixelSize: CGSize? = nil
    ) -> some View {
        if let pane = backend.pane(paneID) {
            VStack(spacing: 0) {
                if showControlBar {
                    // Force the chrome's pixel budget so the layout
                    // engine's outerRect = controlPanel + cellGrid
                    // matches what we actually paint. Without this
                    // the bar's intrinsic height drifts ±2pt from
                    // `LayoutChrome.controlPanelPt` and the cell
                    // area absorbs the drift, producing
                    // off-by-one-row sizeChanged MISMATCH reports.
                    paneControlBar(paneID: paneID, isActive: isActive)
                        .frame(height: LayoutChrome.default.controlPanelPt)
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
                            // Informational only — the grid is
                            // driven top-down by the layout
                            // engine + applyPaneLayout. We still
                            // forward to the backend so the SSH
                            // PTY can stay synced to the active
                            // pane's size.
                            Task { await pane.resize(cols: cols, rows: rows) }
                        },
                        onNavigatePane: { dir in
                            navigatePane(Self.mapDirection(dir))
                        },
                        onLog: { msg in
                            FileLogger.shared.log("Demo[%\(paneID)] \(msg)")
                        },
                        gridCols: cellRect?.cols,
                        gridRows: cellRect?.rows,
                        cellMetrics: cellRect != nil ? cellMetrics : nil
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
                    // Pane-to-pane drag target. Four edge-strip drop
                    // zones: each strip lights up its half live as
                    // the user drags toward an edge, so they see
                    // which way the target will be split before
                    // releasing. Strips also forward quick taps
                    // through `onTap` so the iPad UX of "tap any-
                    // where on a pane to focus it" still works
                    // (the dead-centre is tap-passthrough straight
                    // to the `Color.clear` shim above).
                    PaneDropZone(
                        targetPaneID: paneID,
                        onDrop: { sourceID, edge in
                            Task { await backend.movePane(paneID: sourceID, toPane: paneID, edge: edge) }
                        },
                        onTap: {
                            if !isActive {
                                Task { await backend.selectPane(paneID) }
                                FileLogger.shared.log("Demo: pane tap %\(paneID) (via dropZone)")
                            }
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Active/inactive shown via stroke colour and width
            // (matches the look in `TmuxSessionView`). Previously we
            // dimmed the inactive pane with `.opacity(0.8)`, but the
            // 20% transparency let the `paneSeparator` colour bleed
            // through and the result looked progressively darker
            // when nested inside multiple splits — the user's "more
            // splits, more darker" complaint. A border keeps each
            // pane's terminal colours pixel-identical regardless of
            // active state or split nesting.
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(
                        isActive ? Color.accentColor.opacity(0.6) : Color.gray.opacity(0.25),
                        lineWidth: isActive ? 2 : 1
                    )
            )
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
                .disabled(!canSplit(paneID: paneID, direction: .horizontal))
                Button {
                    Task { await backend.splitPane(direction: .vertical, target: paneID) }
                    FileLogger.shared.log("Demo: pane split ↓ %\(paneID)")
                } label: {
                    Label("Split pane horizontally", systemImage: "rectangle.split.1x2")
                }
                .disabled(!canSplit(paneID: paneID, direction: .vertical))
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
            DragPreview(paneID: paneID)
        }
    }

    /// Drag preview shown under the user's finger during a pane
    /// drag. The `init` side-effect logs the drag start — SwiftUI
    /// rebuilds the preview view exactly when the drag session
    /// begins, which is the closest hook we have to a "did start
    /// dragging" callback.
    private struct DragPreview: View {
        let paneID: Int
        init(paneID: Int) {
            self.paneID = paneID
            FileLogger.shared.log("Demo: drag start %\(paneID)")
        }
        var body: some View {
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
                guard let target = backend.state.activePaneID,
                      canSplit(paneID: target, direction: .horizontal)
                else { return }
                Task { await backend.splitPane(direction: .horizontal, target: target) }
                FileLogger.shared.log("Demo: ⌘D split-right")
            }
            .keyboardShortcut("d", modifiers: .command)

            Button("Split down") {
                guard let target = backend.state.activePaneID,
                      canSplit(paneID: target, direction: .vertical)
                else { return }
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
        // 1. Try the immediate neighbor.
        // 2. If we're at the edge, wrap to the farthest pane in the
        //    *opposite* direction (left arrow at leftmost pane → go
        //    to the rightmost pane).
        let target = win.layout.neighbor(of: pid, direction: direction)
            ?? Self.farthestOpposite(direction, excluding: pid, in: win.layout)
        if let target, target != pid {
            let targetWasHidden = paneFinalLayouts.contains { $0.paneID == target && $0.hidden }
            FileLogger.shared.log("⌘⌥\(direction) %\(pid) → %\(target)\(targetWasHidden ? " (promote)" : "")")
            if targetWasHidden {
                // Swap semantics: target was hidden, so promote it
                // to at least the min usable size. Cells come from
                // its siblings (engine apportions; tmux may reject).
                // The outgoing pane is not shrunk — leaving it
                // alone keeps plain navs cheap and avoids cascading
                // re-layouts that previously brought the simulator
                // to a crawl.
                if let winID = backend.state.activeWindowID {
                    layoutCache.removeValue(forKey: winID)
                }
                Task {
                    await promoteHiddenAsync(paneID: target)
                    await backend.selectPane(target)
                    await MainActor.run { syncAllWindowLayouts() }
                }
            } else {
                // Plain visible→visible nav: just move focus. No
                // resize, no engine churn, no SwiftUI tree rebuild
                // beyond the active-pane border swap.
                Task { await backend.selectPane(target) }
            }
        } else {
            // Single-pane window or no other pane to move to — brief
            // visual feedback.
            paneNavBlink = true
            FileLogger.shared.log("⌘⌥\(direction) %\(pid) — no target (blink)")
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                paneNavBlink = false
            }
        }
    }

    /// Push a hidden pane back above the visibility threshold by
    /// resizing only the dimension(s) that are actually below the
    /// minimum. Uses relative `resizePane` (a delta) rather than an
    /// absolute target — the cellTree stores logical *weights*, not
    /// the engine's apportioned cells, so feeding the engine's
    /// cellCols back through `applyPaneLayout` would compute a
    /// bogus delta and shift cols around every time. Relative deltas
    /// only touch the axes we need to grow.
    private func promoteHiddenAsync(paneID: Int) async {
        guard let layout = paneFinalLayouts.first(where: { $0.paneID == paneID }) else { return }
        let rowGap = PaneLayoutEngine.minRows - layout.cellRows
        let colGap = PaneLayoutEngine.minCols - layout.cellCols
        if rowGap > 0 {
            await backend.resizePane(paneID, direction: .down, cells: rowGap + 5)
        }
        if colGap > 0 {
            await backend.resizePane(paneID, direction: .right, cells: colGap + 10)
        }
    }

    /// Pane *farthest in the opposite direction* of `direction`,
    /// excluding `pid`. Used to wrap around when `neighbor()`
    /// returned nil. For `.left`, that's the rightmost pane
    /// (largest `maxX`); for `.up`, the bottom-most pane; etc.
    private static func farthestOpposite(
        _ direction: PaneNavigationDirection,
        excluding pid: Int,
        in layout: PaneNode
    ) -> Int? {
        let rects = layout.paneRects().filter { $0.id != pid }
        guard !rects.isEmpty else { return nil }
        switch direction {
        case .left:  return rects.max(by: { $0.frame.maxX < $1.frame.maxX })?.id
        case .right: return rects.min(by: { $0.frame.minX < $1.frame.minX })?.id
        case .up:    return rects.max(by: { $0.frame.maxY < $1.frame.maxY })?.id
        case .down:  return rects.min(by: { $0.frame.minY < $1.frame.minY })?.id
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
