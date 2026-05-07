#if canImport(UIKit)
import Foundation
import SwiftUI
import SwiftTerm
import UIKit
import ColorSchemes

/// Plain `UIView` that owns the active pane's first responder
/// **without** being a `UIKeyInput`. iPadOS reserves a fair amount
/// of bottom-edge chrome (HW-keyboard hint pill, accessory dock,
/// home-indicator safe area) for any first responder that conforms
/// to `UIKeyInput`. By holding FR on a plain `UIResponder` and
/// keeping `SwiftTerm.TerminalView` as a render-only child, iPadOS
/// stops drawing that chrome — the screen runs edge-to-edge.
///
/// Hardware keys arrive via `pressesBegan(_:with:)` and are
/// translated to terminal bytes in `encodeKey`. SwiftTerm's own
/// input pipeline is bypassed entirely (it never becomes FR, so
/// its `UIKeyInput` machinery is dormant). The same `onInput`
/// callback that SwiftTerm used to fire is now driven by us
/// directly.
///
/// Software keys are NOT solved here — see Phase 2 (`SoftKeyboard`),
/// which renders our own keyboard as a SwiftUI sibling and feeds
/// bytes through the same `onInput` path.
/// Thin `SwiftTerm.TerminalView` subclass that refuses to become
/// first responder. Critical: the stock class *does* become FR on
/// touch (via its UIKeyInput chain), and when it does iPadOS sees
/// a UIKeyInput FR holder and draws the system shortcut bar (the
/// `esc / ctrl / F1–F8 / arrows / icons` strip). It also steals
/// FR away from `TerminalHost` after a `selectPane` flip, breaking
/// our `keyCommands` registration — that was the immediate cause
/// of "⌘⌥+arrow only works once" in the demo.
///
/// `canBecomeFirstResponder = false` blocks the system path that
/// asks before claiming, but SwiftTerm sometimes calls
/// `becomeFirstResponder()` *directly* (programmatically, via its
/// own gesture recognizers). The explicit override of that method
/// shuts down that path too. Belt-and-suspenders is correct here:
/// if either fails, every UIKeyCommand we register on the host
/// stops being consulted because FR has moved.
final class RenderOnlyTerminalView: SwiftTerm.TerminalView {
    override var canBecomeFirstResponder: Bool { false }

    override func becomeFirstResponder() -> Bool {
        // Refuse all FR claims unconditionally.
        return false
    }

    /// Strip all `UIKeyCommand` registrations the parent class
    /// might surface. iOS otherwise consults this view's
    /// `keyCommands` when matching a chord up the responder
    /// chain, which let SwiftTerm's own arrow-key handlers fire
    /// on pane %2 even after our `becomeFirstResponder` refused.
    override var keyCommands: [UIKeyCommand]? { nil }
}

/// Direction for spatial pane navigation routed through
/// `UIKeyCommand`. Exposed publicly so the App layer can map it
/// onto its own `PaneNavigationDirection` (the App side enum is
/// declared in `TerminalSessionState.swift` and we don't share
/// the type across module boundaries).
public enum TerminalNavigationDirection {
    case left, right, up, down
}

final class TerminalHost: UIView {
    let terminalView: RenderOnlyTerminalView
    var onInput: ((Data) -> Void)?
    var onNavigatePane: ((TerminalNavigationDirection) -> Void)?
    var log: ((String) -> Void)?

    /// Whether this host should currently own first responder.
    /// The SwiftUI wrapper sets this from `isActive` in both
    /// `makeUIView` and `updateUIView`. The `didSet` flips FR
    /// atomically, which keeps "which pane gets keystrokes"
    /// in lockstep with "which pane is active" — without it,
    /// each host's `didMoveToWindow` unconditionally claimed
    /// FR, the last one mounted won (typically the wrong pane),
    /// and typing went to the inactive pane on first mount.
    var isActivePane: Bool = false {
        didSet {
            guard isActivePane != oldValue else { return }
            // Outside a window, FR changes are no-ops; the next
            // `didMoveToWindow` will use the value we set here.
            guard window != nil else { return }
            if isActivePane, !isFirstResponder {
                // **Defer to the next run-loop tick.** SwiftUI calls
                // `updateUIView` for sibling panes synchronously
                // during a batch update, in an order it doesn't
                // promise. If we call `becomeFirstResponder()` here
                // while the sibling pane is still mid-update (its
                // own `resignFirstResponder()` hasn't yet run), the
                // call returns `true` but UIKit ends up with no
                // first responder once the sibling's `resignFR`
                // completes — keys are then dropped. Deferring lets
                // the sibling resign first, so we claim FR against
                // a stable window state.
                //
                // Reproduction (without this fix): tap pane B, type
                // — nothing. Tap pane A, type — works. Tap B again,
                // type — still nothing. Always reproducible because
                // the broken-state paths are deterministic.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.isActivePane,
                          !self.isFirstResponder,
                          self.window != nil
                    else { return }
                    let ok = self.becomeFirstResponder()
                    self.log?("isActivePane=true → becomeFR=\(ok) isFirst=\(self.isFirstResponder) (async)")
                }
            } else if !isActivePane, isFirstResponder {
                let ok = resignFirstResponder()
                log?("isActivePane=false → resignFR=\(ok) isFirst=\(isFirstResponder)")
            }
        }
    }

    override init(frame: CGRect) {
        terminalView = RenderOnlyTerminalView(frame: frame)
        super.init(frame: frame)
        addSubview(terminalView)
        // Render-only: no touches, hovers, presses ever route into
        // SwiftTerm. Cuts off the path where SwiftTerm's input
        // handlers would otherwise consume ⌘⌥+arrow chords.
        terminalView.isUserInteractionEnabled = false
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        // Pane-id-prefixed via the caller's `log` closure. The
        // ObjectIdentifier disambiguates instances when SwiftUI
        // recycles a paneCell (which would leave us with multiple
        // TerminalHosts for the same pane id, only one of which
        // is in the visible hierarchy).
        log?("TerminalHost deinit id=\(ObjectIdentifier(self).hashValue & 0xFFFF)")
    }

    override var canBecomeFirstResponder: Bool { true }

    /// `UIKeyCommand` registrations. Used for `⌘⌥+arrow` pane
    /// navigation because SwiftUI's `.keyboardShortcut(.rightArrow,
    /// modifiers: [.command, .option])` wasn't reaching our hidden
    /// shortcut buttons in practice — chord either consumed by
    /// iPadOS / Simulator before reaching SwiftUI's responder
    /// chain, or filtered out at SwiftUI's hosting layer. UIKit's
    /// `keyCommands` is the system path text-editing apps use and
    /// runs at first responder before SwiftUI gets a look.
    override var keyCommands: [UIKeyCommand]? {
        return [
            UIKeyCommand(
                action: #selector(handleNavLeft),
                input: UIKeyCommand.inputLeftArrow,
                modifierFlags: [.command, .alternate]
            ),
            UIKeyCommand(
                action: #selector(handleNavRight),
                input: UIKeyCommand.inputRightArrow,
                modifierFlags: [.command, .alternate]
            ),
            UIKeyCommand(
                action: #selector(handleNavUp),
                input: UIKeyCommand.inputUpArrow,
                modifierFlags: [.command, .alternate]
            ),
            UIKeyCommand(
                action: #selector(handleNavDown),
                input: UIKeyCommand.inputDownArrow,
                modifierFlags: [.command, .alternate]
            ),
        ]
    }

    @objc private func handleNavLeft()  { onNavigatePane?(.left) }
    @objc private func handleNavRight() { onNavigatePane?(.right) }
    @objc private func handleNavUp()    { onNavigatePane?(.up) }
    @objc private func handleNavDown()  { onNavigatePane?(.down) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let hostID = ObjectIdentifier(self).hashValue & 0xFFFF
        if window == nil {
            log?("TerminalHost didMoveToWindow window=nil active=\(isActivePane) FR=\(isFirstResponder) id=\(hostID)")
            if isFirstResponder {
                _ = resignFirstResponder()
            }
            return
        }
        log?("TerminalHost didMoveToWindow window=set active=\(isActivePane) FR=\(isFirstResponder) id=\(hostID)")
        // Only claim if this is the active pane. The inactive pane's
        // host stays passive on mount.
        if isActivePane, !isFirstResponder {
            let ok = becomeFirstResponder()
            log?("TerminalHost didMoveToWindow becomeFR=\(ok) id=\(hostID)")
        }
    }

    // MARK: - Hardware key handling

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let hostID = ObjectIdentifier(self).hashValue & 0xFFFF
        log?("TerminalHost pressesBegan count=\(presses.count) FR=\(isFirstResponder) active=\(isActivePane) onInputSet=\(onInput != nil) id=\(hostID)")
        var unhandled: Set<UIPress> = []
        for press in presses {
            if let bytes = press.key.flatMap(encodeKey) {
                onInput?(Data(bytes))
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    /// Translate a `UIKey` into raw terminal bytes. Returns `nil`
    /// for keys we don't (yet) handle — the caller passes those up
    /// the responder chain so menu shortcuts (`⌘D`, `⌘W`, etc.)
    /// still work.
    ///
    /// Coverage today is "the basics" — enough to type ASCII, run
    /// vim, navigate a shell. Composed input (IME), dead keys, and
    /// most function-key behaviors land in Phase 2 alongside the
    /// custom soft keyboard.
    private func encodeKey(_ key: UIKey) -> [UInt8]? {
        let mods = key.modifierFlags
        // Cmd-modified keys belong to menus / `.keyboardShortcut`.
        // Don't intercept; let the responder chain dispatch.
        if mods.contains(.command) { return nil }

        // Named keys take precedence over `characters` because
        // some of them (Esc, Tab, arrows) have no useful character.
        switch key.keyCode {
        case .keyboardEscape:                     return [0x1B]
        case .keyboardTab:                        return [0x09]
        case .keyboardReturnOrEnter,
             .keypadEnter:                        return [0x0D]
        case .keyboardDeleteOrBackspace:          return [0x7F]
        case .keyboardLeftArrow:                  return [0x1B, 0x5B, 0x44]
        case .keyboardRightArrow:                 return [0x1B, 0x5B, 0x43]
        case .keyboardUpArrow:                    return [0x1B, 0x5B, 0x41]
        case .keyboardDownArrow:                  return [0x1B, 0x5B, 0x42]
        case .keyboardHome:                       return [0x1B, 0x5B, 0x48]
        case .keyboardEnd:                        return [0x1B, 0x5B, 0x46]
        case .keyboardPageUp:                     return [0x1B, 0x5B, 0x35, 0x7E]
        case .keyboardPageDown:                   return [0x1B, 0x5B, 0x36, 0x7E]
        default: break
        }

        // Ctrl+<letter> → control byte (Ctrl-A = 0x01, …, Ctrl-Z = 0x1A).
        // Use `charactersIgnoringModifiers` so caps-shift doesn't matter.
        if mods.contains(.control),
           let scalar = key.charactersIgnoringModifiers.lowercased().unicodeScalars.first,
           (0x61...0x7A).contains(scalar.value)
        {
            return [UInt8(scalar.value & 0x1F)]
        }

        // Alt/Option+<key> → ESC <key> (xterm "meta" mode).
        if mods.contains(.alternate), let scalar = key.characters.unicodeScalars.first {
            return [0x1B, UInt8(scalar.value & 0x7F)]
        }

        // Plain printable.
        if !key.characters.isEmpty {
            return Array(key.characters.utf8)
        }
        return nil
    }
}

/// SwiftUI wrapper that vends a `TerminalHost`. The host's child
/// `SwiftTerm.TerminalView` does the rendering; the host owns FR
/// and HW-key handling. The flow:
///   - **In**: caller pushes via `TerminalDriver.feed(_:)`. The
///     driver eventually binds to the inner SwiftTerm view once it
///     has a real size.
///   - **Out (HW)**: `TerminalHost.pressesBegan` → `encodeKey` →
///     `onInput`.
///   - **Out (SW)**: solved separately by Phase 2's custom
///     keyboard, which calls `onInput` directly.
///   - **Resize**: SwiftTerm reports `(cols, rows)` via
///     `onSizeChange`; the caller forwards to whatever PTY backs
///     the session.
public struct SwiftTermView: UIViewRepresentable {
    let driver: TerminalDriver
    let scheme: ColorSchemes.ColorScheme?
    let isActive: Bool
    let onInput: (Data) -> Void
    let onSizeChange: (Int, Int) -> Void
    /// Caller-supplied handler for `⌘⌥+arrow` pane navigation.
    /// Routed through UIKit's `keyCommands`, not SwiftUI's
    /// `.keyboardShortcut`.
    let onNavigatePane: ((TerminalNavigationDirection) -> Void)?
    /// Optional debug logger — wired through to the App's
    /// `FileLogger` so FR transitions and HW-key traffic show up
    /// in `debug.log`.
    let onLog: ((String) -> Void)?

    public init(
        driver: TerminalDriver,
        scheme: ColorSchemes.ColorScheme? = nil,
        isActive: Bool = true,
        onInput: @escaping (Data) -> Void,
        onSizeChange: @escaping (Int, Int) -> Void = { _, _ in },
        onNavigatePane: ((TerminalNavigationDirection) -> Void)? = nil,
        onLog: ((String) -> Void)? = nil
    ) {
        self.driver = driver
        self.scheme = scheme
        self.isActive = isActive
        self.onInput = onInput
        self.onSizeChange = onSizeChange
        self.onNavigatePane = onNavigatePane
        self.onLog = onLog
    }

    // The associated `UIViewType` is `UIView` — an erasure that
    // keeps `TerminalHost` package-internal. SwiftUI accepts the
    // concrete subclass at runtime; we downcast in `updateUIView`.
    public func makeUIView(context: Context) -> UIView {
        let host = TerminalHost(frame: .zero)
        host.terminalView.terminalDelegate = context.coordinator
        host.onInput = onInput
        host.onNavigatePane = onNavigatePane
        host.log = onLog
        host.isActivePane = isActive
        context.coordinator.log = onLog
        if let scheme {
            ColorSchemeApply.apply(scheme, to: host.terminalView)
        }
        onLog?("TerminalHost makeUIView active=\(isActive) id=\(ObjectIdentifier(host).hashValue & 0xFFFF)")
        // We *don't* bind the driver here. SwiftTerm computes
        // cols/rows from its frame, and at makeUIView time the
        // frame can still be zero (especially in nested SwiftUI
        // like GeometryReader inside a split layout). The
        // coordinator binds the first time `sizeChanged` reports a
        // real width.
        return host
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        guard let host = uiView as? TerminalHost else { return }
        if let scheme {
            ColorSchemeApply.apply(scheme, to: host.terminalView)
        }
        host.onInput = onInput
        host.onNavigatePane = onNavigatePane
        host.log = onLog
        context.coordinator.log = onLog
        context.coordinator.wantsKeyboard = isActive
        // FR is driven by `isActivePane`'s didSet — assigning here
        // flips first responder atomically to whichever pane is
        // newly active, in a single hop, without a window of "no
        // FR" or "two FR claims racing" between mount events.
        host.isActivePane = isActive
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(driver: driver, onInput: onInput, onSizeChange: onSizeChange)
    }

    public final class Coordinator: NSObject, SwiftTerm.TerminalViewDelegate {
        let driver: TerminalDriver
        let onInput: (Data) -> Void
        let onSizeChange: (Int, Int) -> Void
        private var hasBound = false
        var log: ((String) -> Void)?
        /// Mirror of the parent's `isActive` so `sizeChanged` (which
        /// fires once the view has a real size, i.e. is in the window
        /// hierarchy) can perform the initial first-responder claim.
        var wantsKeyboard: Bool = false

        init(
            driver: TerminalDriver,
            onInput: @escaping (Data) -> Void,
            onSizeChange: @escaping (Int, Int) -> Void
        ) {
            self.driver = driver
            self.onInput = onInput
            self.onSizeChange = onSizeChange
        }

        // MARK: - TerminalViewDelegate

        /// SwiftTerm normally calls this when *its* `UIKeyInput` chain
        /// receives a key. With `TerminalHost` as FR, SwiftTerm is
        /// never FR, so this is mostly dormant — but we still wire
        /// it to `onInput` as a safety net for any internal SwiftTerm
        /// path that might fire it (paste handling, accessibility,
        /// etc.).
        public func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            log?("STV.send \(data.count) bytes (unexpected — host should own FR)")
            onInput(Data(data))
        }

        public func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            // First plausible size triggers the buffer replay. Use a
            // small threshold so a transient `(2, 2)` from an early
            // layout pass doesn't lock us into wrap-each-char mode.
            // SwiftTerm calls delegates on the main thread, but the
            // protocol isn't `@MainActor`, so we have to assert it.
            if !hasBound, newCols >= 10, newRows >= 3 {
                MainActor.assumeIsolated {
                    driver.bind(source)
                }
                hasBound = true
            }
            onSizeChange(newCols, newRows)
        }

        public func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}

        public func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

        public func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

        public func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

        public func requestOpenLink(
            source: SwiftTerm.TerminalView,
            link: String,
            params: [String: String]
        ) {}

        public func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}

        public func bell(source: SwiftTerm.TerminalView) {}

        public func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    }
}
#endif
