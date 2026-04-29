#if canImport(UIKit)
import Foundation
import UIKit
import SwiftTerm

/// Hands bytes from the caller (e.g. an SSH output stream pump) into
/// the underlying `SwiftTerm.TerminalView`. Created by the caller and
/// passed into a `SwiftTermView`; the representable binds the live
/// view into the driver when it materializes.
///
/// The driver keeps a rolling buffer of all bytes ever fed (capped by
/// `maxBufferedBytes`) so that a `SwiftTermView` mounted after some
/// bytes have already arrived can be replayed up to the current
/// state. This solves the standard SwiftUI race where `output` events
/// can be processed before `makeUIView` runs.
@MainActor
public final class TerminalDriver {
    private weak var terminal: SwiftTerm.TerminalView?
    private var buffer: [UInt8] = []
    private let maxBufferedBytes: Int

    public init(maxBufferedBytes: Int = 1_000_000) {
        self.maxBufferedBytes = maxBufferedBytes
    }

    /// How many bytes have been fed in. Callers check this to decide
    /// whether `capture-pane` would duplicate live output already
    /// pushed via `%output`.
    public var bufferedByteCount: Int { buffer.count }

    /// Push bytes from the remote (or any source) into the terminal.
    /// Must be called on the main actor. Always buffers; also feeds
    /// the view directly if one is bound.
    public func feed(_ data: Data) {
        let bytes = Array(data)
        buffer.append(contentsOf: bytes)
        let overflow = buffer.count - maxBufferedBytes
        if overflow > 0 {
            buffer.removeFirst(overflow)
        }
        terminal?.feed(byteArray: ArraySlice(bytes))
    }

    func bind(_ view: SwiftTerm.TerminalView) {
        terminal = view
        // The caller defers `bind` to the next runloop tick so
        // SwiftTerm's `layoutSubviews` has run and computed real
        // cell dimensions before replay. If the cols-≈-0 hard-wrap
        // bug returns, we'll need to find SwiftTerm's public sizing
        // API (TerminalView.terminal is internal) and force a known
        // size here.
        if !buffer.isEmpty {
            view.feed(byteArray: ArraySlice(buffer))
        }
    }
}
#endif
