#if canImport(UIKit)
import Foundation
import SwiftUI
import SwiftTerm
import UIKit

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
    let onInput: (Data) -> Void
    let onSizeChange: (Int, Int) -> Void

    public init(
        driver: TerminalDriver,
        onInput: @escaping (Data) -> Void,
        onSizeChange: @escaping (Int, Int) -> Void = { _, _ in }
    ) {
        self.driver = driver
        self.onInput = onInput
        self.onSizeChange = onSizeChange
    }

    public func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView()
        view.terminalDelegate = context.coordinator
        // Defer bind to the next runloop tick: by then SwiftUI has
        // applied a layout pass and SwiftTerm's `layoutSubviews` has
        // computed real cell dimensions. Replaying buffered bytes
        // against the live size avoids the cols≈0 wrap-each-char bug.
        let driver = self.driver
        DispatchQueue.main.async {
            driver.bind(view)
        }
        return view
    }

    public func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        // No-op; bytes are pushed via the driver and input is forwarded
        // through the delegate. SwiftUI doesn't need to drive updates.
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onSizeChange: onSizeChange)
    }

    public final class Coordinator: NSObject, SwiftTerm.TerminalViewDelegate {
        let onInput: (Data) -> Void
        let onSizeChange: (Int, Int) -> Void

        init(
            onInput: @escaping (Data) -> Void,
            onSizeChange: @escaping (Int, Int) -> Void
        ) {
            self.onInput = onInput
            self.onSizeChange = onSizeChange
        }

        // MARK: - TerminalViewDelegate (required & commonly-required)

        public func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            onInput(Data(data))
        }

        public func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
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
