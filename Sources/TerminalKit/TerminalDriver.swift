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
    /// Optional logger. Wired from the App layer so feed / bind
    /// activity shows up in `debug.log` alongside SwiftTerm's
    /// `sizeChanged` reports — needed to correlate "bytes arrived"
    /// with "renderer size at the moment they were rendered."
    public var log: ((String) -> Void)?

    /// Suspended → live `feed(_)` calls go to a side buffer instead
    /// of the bound view. Used by the re-capture flow: when we ask
    /// tmux for `capture-pane` after a resize/reattach, any `%output`
    /// that arrived between our request and tmux's response is
    /// already reflected in the captured snapshot — feeding it to
    /// the view *and then* feeding the snapshot would render the
    /// same bytes twice. We suspend on capture-request, feed the
    /// captured content via `feedSnapshot`, then `resume()` to drain
    /// any post-capture live bytes that arrived in the meantime.
    private var suspended: Bool = false
    private var pendingLive: [UInt8] = []

    public init(maxBufferedBytes: Int = 1_000_000) {
        self.maxBufferedBytes = maxBufferedBytes
    }

    /// How many bytes have been fed in. Callers check this to decide
    /// whether `capture-pane` would duplicate live output already
    /// pushed via `%output`.
    public var bufferedByteCount: Int { buffer.count }

    /// Push bytes from the remote (or any source) into the terminal.
    /// Must be called on the main actor. Always buffers; also feeds
    /// the view directly if one is bound *and* not suspended.
    public func feed(_ data: Data) {
        let bytes = Array(data)
        buffer.append(contentsOf: bytes)
        let overflow = buffer.count - maxBufferedBytes
        if overflow > 0 {
            buffer.removeFirst(overflow)
        }
        if suspended {
            pendingLive.append(contentsOf: bytes)
            log?("driver.feed \(bytes.count)B suspended pendingLive=\(pendingLive.count)")
        } else {
            let live = terminal != nil
            terminal?.feed(byteArray: ArraySlice(bytes))
            log?("driver.feed \(bytes.count)B \(live ? "live" : "buffered-only") bufTotal=\(buffer.count)")
        }
    }

    /// Hold rendering of incoming `feed` bytes. The replay buffer
    /// keeps growing; only the live view is paused.
    public func suspend() {
        suspended = true
        log?("driver.suspend")
    }

    /// Drop any live bytes received during the suspend window
    /// (they're considered already-applied via `feedSnapshot`) and
    /// resume rendering. Called after a capture has been fed.
    public func resumeDiscardingPending() {
        suspended = false
        let dropped = pendingLive.count
        pendingLive.removeAll(keepingCapacity: false)
        log?("driver.resume discarded=\(dropped)B")
    }

    /// Resume rendering, feeding any bytes that landed during the
    /// suspend window. Use this if the snapshot wasn't applied (e.g.
    /// the capture-pane request failed).
    public func resumeFlushingPending() {
        suspended = false
        let bytes = pendingLive
        pendingLive.removeAll(keepingCapacity: false)
        terminal?.feed(byteArray: ArraySlice(bytes))
        log?("driver.resume flushed=\(bytes.count)B")
    }

    /// Replace the visible grid with a captured snapshot from tmux.
    /// Wipes the SwiftTerm screen + scrollback first (`ESC c` /
    /// RIS), re-asserts DECAWM, then feeds the supplied bytes — they
    /// are tmux's `capture-pane -p -e` output already framed with
    /// SGR attributes. Also resets the replay buffer so a future
    /// remount starts from this snapshot rather than the pre-capture
    /// byte stream.
    public func feedSnapshot(_ data: Data) {
        let bytes = Array(data)
        // RIS (Reset to Initial State) clears screen + scrollback +
        // most modes. We follow with an explicit DECAWM-on so the
        // wrap behavior matches our binding-time setup.
        let reset: [UInt8] = [0x1B, 0x63]                   // ESC c
        let enableAutowrap: [UInt8] = [0x1B, 0x5B, 0x3F, 0x37, 0x68] // ESC [ ? 7 h
        buffer = reset + enableAutowrap + bytes
        let overflow = buffer.count - maxBufferedBytes
        if overflow > 0 {
            buffer.removeFirst(overflow)
        }
        terminal?.feed(byteArray: ArraySlice(reset))
        terminal?.feed(byteArray: ArraySlice(enableAutowrap))
        terminal?.feed(byteArray: ArraySlice(bytes))
        log?("driver.feedSnapshot \(bytes.count)B (replay buffer reset)")
    }

    func bind(_ view: SwiftTerm.TerminalView) {
        terminal = view
        // The caller defers `bind` to the next runloop tick so
        // SwiftTerm's `layoutSubviews` has run and computed real
        // cell dimensions before replay. If the cols-≈-0 hard-wrap
        // bug returns, we'll need to find SwiftTerm's public sizing
        // API (TerminalView.terminal is internal) and force a known
        // size here.
        let f = view.frame
        log?("driver.bind replay=\(buffer.count)B frame=\(Int(f.width.rounded()))x\(Int(f.height.rounded()))")
        if !buffer.isEmpty {
            view.feed(byteArray: ArraySlice(buffer))
        }
        // Force DECAWM (DEC Auto-Wrap Mode) ON. tmux runs bash
        // inside a `screen-256color` terminfo entry which has
        // `xenl@` (no pending-wrap), so readline uses the no-xenl
        // wrap pattern: write `<char>`, then `<space>` to push the
        // cursor past the right margin (relying on `am=on` to
        // auto-wrap to the next row), then `\r` to settle at col 0
        // of the new row. If our terminal has DECAWM OFF the
        // `<space>` overwrites the char in place and `\r` lands at
        // col 0 of the *same* row — the cursor-jumps-to-col-0
        // symptom users see when typing fills a narrow pane. Some
        // prior state in the replay buffer (vim disabling autowrap
        // and being killed before restoring it, etc.) can leave
        // DECAWM off; re-asserting it at bind time pins it back on.
        let enableAutowrap: [UInt8] = [0x1B, 0x5B, 0x3F, 0x37, 0x68] // ESC [ ? 7 h
        view.feed(byteArray: ArraySlice(enableAutowrap))
    }
}
#endif
