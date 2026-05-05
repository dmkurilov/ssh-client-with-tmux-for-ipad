#if canImport(UIKit)
import SwiftUI
import TerminalKit
import ColorSchemes

/// Three keyboard modes from `docs/05-ui-vision.md` §4.3. The demo
/// can't yet detect HW keyboard presence (`GCKeyboard` work is in
/// `04-todos.md`), so `auto` here behaves the same as `forcedShown`
/// — soft keyboard always available. Once HW detection lands the
/// auto branch will hide the SW when HW is connected.
enum KeyboardMode: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case forcedShown = "Forcefully shown"
    case forcedHidden = "Forcefully hidden"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .auto: return "keyboard.badge.eye"
        case .forcedShown: return "keyboard"
        case .forcedHidden: return "keyboard.chevron.compact.down"
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

    @Environment(\.dismiss) private var dismiss

    @State private var fullScreen: Bool = false
    @State private var tabsVisible: Bool = true
    @State private var keyboardMode: KeyboardMode = .auto

    @State private var renamingWindowID: Int?
    @State private var renameText: String = ""
    @State private var renamingSession: Bool = false
    @State private var sessionRenameText: String = ""

    private var softKeyboard: Bool {
        switch keyboardMode {
        case .auto, .forcedShown: return true
        case .forcedHidden: return false
        }
    }

    private var keyboardModeBinding: Binding<KeyboardMode> {
        Binding(
            get: { keyboardMode },
            set: {
                keyboardMode = $0
                FileLogger.shared.log("Demo: kb mode → \($0.rawValue)")
            }
        )
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
        .ignoresSafeArea(.all, edges: fullScreen ? [.top, .bottom] : [])
        .background(keyboardShortcutSink)
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

            // `Picker` inside a `Menu` renders with native checkmarks
            // on the selected option, so we don't have to compose the
            // selected indicator manually.
            Menu {
                Picker("Keyboard mode", selection: keyboardModeBinding) {
                    ForEach(KeyboardMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.iconName).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: keyboardMode.iconName)
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
                    beginRenameWindow(window)
                }
            Button {
                Task { await backend.killWindow(window.id) }
                FileLogger.shared.log("Demo: tab x @\(window.id)")
            } label: {
                Image(systemName: "xmark")
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
    }

    // MARK: - Pane area

    @ViewBuilder
    private var paneArea: some View {
        if let win = backend.state.activeWindow, !win.paneIDs.isEmpty {
            HStack(spacing: 1) {
                ForEach(win.paneIDs, id: \.self) { paneID in
                    paneCell(paneID: paneID, isActive: paneID == win.activePaneID)
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

    @ViewBuilder
    private func paneCell(paneID: Int, isActive: Bool) -> some View {
        if let pane = backend.pane(paneID) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    SwiftTermView(
                        driver: pane.driver,
                        scheme: scheme,
                        isActive: isActive,
                        softKeyboard: softKeyboard,
                        onInput: { data in
                            Task { await pane.send(data) }
                        },
                        onSizeChange: { cols, rows in
                            Task { await pane.resize(cols: cols, rows: rows) }
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
    /// the `x` to close, `...` to open the menu.
    private func paneControlOverlay(paneID: Int) -> some View {
        HStack(spacing: 2) {
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
                Divider()
                // Move-to / Insert image / Select all / Copy / Paste
                // are placeholders for now — the menu structure
                // matches `docs/05-ui-vision.md` §3.4 so the layout
                // doesn't shift when those land.
                Button("Move pane to …") {
                    FileLogger.shared.log("Demo: pane move %\(paneID) (TBD)")
                }
                .disabled(true)
                Divider()
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
        }
        .foregroundStyle(.secondary)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
        .opacity(0.55)
    }

    // MARK: - Hotkeys

    /// Hidden buttons that register hardware-keyboard shortcuts via
    /// `.keyboardShortcut`. Cmd-modified keys go through the iOS
    /// menu/responder chain *before* reaching SwiftTerm, so this is
    /// the cleanest place to bind them.
    ///
    /// Mapping (matches `docs/05-ui-vision.md` §5):
    ///   - ⌘D    → Split pane vertically (panes side by side)
    ///   - ⌘⇧D   → Split pane horizontally (panes stacked)
    ///   - ⌘W    → Close active pane
    ///   - ⌘T    → New tab (window)
    ///   - ⌘⇧F   → Toggle app-level fullscreen
    ///   - ⌘⇧T   → Toggle tab strip visibility
    private var keyboardShortcutSink: some View {
        ZStack {
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

            Button("Toggle fullscreen") {
                fullScreen.toggle()
                FileLogger.shared.log("Demo: ⌘⇧F fs → \(fullScreen)")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button("Toggle tab strip") {
                tabsVisible.toggle()
                FileLogger.shared.log("Demo: ⌘⇧T tabs → \(tabsVisible)")
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    // MARK: - Actions

    private func close() {
        FileLogger.shared.log("Demo: close pressed")
        Task {
            await backend.disconnect()
            dismiss()
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
