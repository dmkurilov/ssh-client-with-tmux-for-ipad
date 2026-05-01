#if canImport(UIKit)
import Foundation
import SwiftUI
import SwiftTerm
import UIKit
import ColorSchemes

/// `TerminalView` subclass that gates first-responder status on a
/// caller-driven flag. Toggling the flag off makes the view refuse
/// to become first responder, so the soft keyboard goes away and
/// stays away — until the user toggles back on.
///
/// Side-effect: hardware-keyboard input is also gated (HW keys only
/// route to a first responder). The trade-off matches the user's
/// mental model: keyboard shows ↔ I can type; keyboard hidden ↔ no
/// typing until I tap the toolbar button again.
/// `TerminalView` subclass that decouples *first responder* (HW key
/// routing) from *soft keyboard visibility*. We always accept first
/// responder so `pressesBegan` reaches SwiftTerm; the soft keyboard
/// is suppressed by installing an empty `inputView` when the user
/// toggles it off. SwiftTerm stores `inputView` in `_inputView`, so
/// `self.inputView = …` actually takes effect.
final class GatedTerminalView: SwiftTerm.TerminalView {
    /// `true`  → default keyboard chain (system soft keyboard).
    /// `false` → an empty zero-frame inputView replaces the system
    ///           keyboard, while first responder is preserved so
    ///           hardware keys still work.
    var softKeyboardEnabled: Bool = true {
        didSet {
            guard softKeyboardEnabled != oldValue else { return }
            if softKeyboardEnabled {
                self.inputView = nil
                if let saved = savedAccessoryView {
                    self.inputAccessoryView = saved
                    savedAccessoryView = nil
                }
            } else {
                self.inputView = UIView(frame: .zero)
                // Stash SwiftTerm's `TerminalAccessory` so we can
                // restore the same instance later — the alternative
                // is leaving the strip visible at the bottom of the
                // screen, which the user reads as "keyboard still
                // here".
                if savedAccessoryView == nil {
                    savedAccessoryView = self.inputAccessoryView
                }
                self.inputAccessoryView = nil
            }
            if isFirstResponder {
                reloadInputViews()
            }
        }
    }

    private var savedAccessoryView: UIView?

    override var canBecomeFirstResponder: Bool { true }

    /// Auto-claim first responder once we're in a window, so HW
    /// keystrokes (and the soft keyboard, if enabled) work without
    /// the caller having to explicitly tap.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !isFirstResponder {
            _ = becomeFirstResponder()
        }
    }
}

/// SwiftUI wrapper around SwiftTerm's iOS `TerminalView`. Provides
/// real ANSI rendering, colors, scroll-back, and keyboard input
/// capture. Bytes flow:
///   - **In**: caller pushes via `TerminalDriver.feed(_:)`.
///   - **Out**: user keystrokes arrive via `onInput` callback (raw
///     bytes ready to send over SSH or wherever).
///   - **Resize**: SwiftTerm reports `(cols, rows)` via
///     `onSizeChange`; the caller is responsible for forwarding
///     these to whatever PTY backs the session.
public struct SwiftTermView: UIViewRepresentable {
    let driver: TerminalDriver
    let scheme: ColorSchemes.ColorScheme?
    let isActive: Bool
    /// Caller-driven flag: should the soft keyboard be shown for the
    /// active pane right now? We don't auto-claim on tap, so this is
    /// the only way the keyboard appears — typically toggled by the
    /// keyboard button in `TmuxSessionView`'s toolbar.
    let softKeyboard: Bool
    let onInput: (Data) -> Void
    let onSizeChange: (Int, Int) -> Void
    /// Optional debug logger — wired through to the App's
    /// `FileLogger` so `becomeFirstResponder` / `resignFirstResponder`
    /// behaviour shows up in `debug.log`.
    let onLog: ((String) -> Void)?

    public init(
        driver: TerminalDriver,
        scheme: ColorSchemes.ColorScheme? = nil,
        isActive: Bool = true,
        softKeyboard: Bool = false,
        onInput: @escaping (Data) -> Void,
        onSizeChange: @escaping (Int, Int) -> Void = { _, _ in },
        onLog: ((String) -> Void)? = nil
    ) {
        self.driver = driver
        self.scheme = scheme
        self.isActive = isActive
        self.softKeyboard = softKeyboard
        self.onInput = onInput
        self.onSizeChange = onSizeChange
        self.onLog = onLog
    }

    public func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = GatedTerminalView()
        view.terminalDelegate = context.coordinator
        context.coordinator.log = onLog
        if let scheme {
            ColorSchemeApply.apply(scheme, to: view)
        }
        view.softKeyboardEnabled = softKeyboard
        // We *don't* bind here. SwiftTerm computes cols/rows from its
        // frame, and at makeUIView time the frame can still be zero
        // (especially in nested SwiftUI like GeometryReader inside a
        // split layout). Binding too early would replay buffered
        // bytes against a 0/2-column terminal — they'd hard-wrap one
        // char per line. Instead the coordinator binds the first
        // time `sizeChanged` reports a real width.
        return view
    }

    public func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        // Re-apply the scheme on update so changing it from a
        // settings sheet recolors live terminals without remounting.
        if let scheme {
            ColorSchemeApply.apply(scheme, to: uiView)
        }
        // Soft-keyboard visibility is independent of first responder.
        // The active pane is always FR (so HW keys work); whether the
        // soft keyboard pops up is governed by `inputView` on the
        // gated view.
        if let gated = uiView as? GatedTerminalView {
            gated.softKeyboardEnabled = softKeyboard
        }
        context.coordinator.wantsKeyboard = isActive
        if isActive, !uiView.isFirstResponder {
            let ok = uiView.becomeFirstResponder()
            onLog?("STV → becomeFirstResponder() ok=\(ok) isFirst=\(uiView.isFirstResponder)")
        } else if !isActive, uiView.isFirstResponder {
            let ok = uiView.resignFirstResponder()
            onLog?("STV → resignFirstResponder() ok=\(ok) isFirst=\(uiView.isFirstResponder)")
        }
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
        /// Mirror of the parent's `softKeyboard` so `sizeChanged`
        /// (which fires once the view has a real size, i.e. is in
        /// the window hierarchy) can perform the initial claim.
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

        // MARK: - TerminalViewDelegate (required & commonly-required)

        public func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            log?("STV.send \(data.count) bytes")
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
                    // The view now has real cell dimensions and is
                    // in the window hierarchy — safe to claim first
                    // responder if the parent asked for it. Doing
                    // this in `updateUIView` was racing the view's
                    // attachment and the becomeFirstResponder call
                    // returned `false` silently.
                    // `wantsKeyboard` here means "active pane wants
                    // first-responder" — the soft-keyboard flag has
                    // already been pushed into `softKeyboardEnabled`
                    // by `updateUIView`.
                    if wantsKeyboard, !source.isFirstResponder {
                        let ok = source.becomeFirstResponder()
                        log?("STV.sizeChanged → becomeFirstResponder() ok=\(ok) isFirst=\(source.isFirstResponder)")
                    }
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
