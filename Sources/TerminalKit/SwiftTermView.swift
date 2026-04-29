#if canImport(UIKit)
import Foundation
import SwiftUI
import SwiftTerm
import UIKit
import ColorSchemes

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
    let onInput: (Data) -> Void
    let onSizeChange: (Int, Int) -> Void

    public init(
        driver: TerminalDriver,
        scheme: ColorSchemes.ColorScheme? = nil,
        onInput: @escaping (Data) -> Void,
        onSizeChange: @escaping (Int, Int) -> Void = { _, _ in }
    ) {
        self.driver = driver
        self.scheme = scheme
        self.onInput = onInput
        self.onSizeChange = onSizeChange
    }

    public func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView()
        view.terminalDelegate = context.coordinator
        if let scheme {
            ColorSchemeApply.apply(scheme, to: view)
        }
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
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(driver: driver, onInput: onInput, onSizeChange: onSizeChange)
    }

    public final class Coordinator: NSObject, SwiftTerm.TerminalViewDelegate {
        let driver: TerminalDriver
        let onInput: (Data) -> Void
        let onSizeChange: (Int, Int) -> Void
        private var hasBound = false

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
