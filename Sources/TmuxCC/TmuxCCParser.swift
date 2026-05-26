import Foundation

/// A push-shaped parser for tmux `-CC` control-mode output.
///
/// Feed bytes in, get `TmuxEvent`s out. The parser is a value type; copy
/// it to snapshot state. It handles the outer DCS envelope
/// (`\x1bP1000p … \x1b\\`) plus line-by-line parsing of every `%`
/// notification we care about. It never throws; malformed lines come
/// out as `.unknown(_)`.
public struct TmuxCCParser {

    // MARK: - Public API

    /// Construct a parser. If `expectDCSFraming` is `true` (default), the
    /// parser discards bytes until it sees `\x1bP1000p`, then parses
    /// lines until `\x1b\\`. Pass `false` when the stream is already
    /// un-framed (e.g. captured without the DCS bytes).
    public init(expectDCSFraming: Bool = true) {
        self.framing = expectDCSFraming ? .preDCS : .inDCS
    }

    @discardableResult
    public mutating func feed(_ data: Data) -> [TmuxEvent] {
        var events: [TmuxEvent] = []
        for byte in data {
            step(byte, events: &events)
        }
        return events
    }

    @discardableResult
    public mutating func feed(_ text: String) -> [TmuxEvent] {
        feed(Data(text.utf8))
    }

    /// Flush any line currently buffered. Call when the input stream
    /// ends, in case the final line had no trailing newline.
    @discardableResult
    public mutating func finish() -> [TmuxEvent] {
        var events: [TmuxEvent] = []
        flushLine(events: &events)
        return events
    }

    // MARK: - Framing state

    private enum FramingState {
        case preDCS                   // before `\x1bP1000p` arrives
        case preDCSIntro(nextIndex: Int)  // partway through matching the intro
        case inDCS                    // between intro and ST — line-oriented
        case inDCSAfterEsc            // just saw `\x1b` inside DCS; may be ST
        case afterDCS                 // past ST — ignore everything
    }

    private static let dcsIntro: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]

    private var framing: FramingState
    private var lineBuffer: [UInt8] = []

    // MARK: - Byte-level stepping

    private mutating func step(_ byte: UInt8, events: inout [TmuxEvent]) {
        switch framing {
        case .preDCS:
            if byte == Self.dcsIntro[0] {
                framing = .preDCSIntro(nextIndex: 1)
            }

        case .preDCSIntro(let idx):
            if byte == Self.dcsIntro[idx] {
                if idx + 1 == Self.dcsIntro.count {
                    framing = .inDCS
                    events.append(.dcsBegin)
                } else {
                    framing = .preDCSIntro(nextIndex: idx + 1)
                }
            } else {
                framing = (byte == Self.dcsIntro[0]) ? .preDCSIntro(nextIndex: 1) : .preDCS
            }

        case .inDCS:
            if byte == 0x1B {
                framing = .inDCSAfterEsc
                return
            }
            if byte == 0x0A {
                flushLine(events: &events)
                return
            }
            lineBuffer.append(byte)

        case .inDCSAfterEsc:
            // Only treat `\x1b\` as the DCS terminator when it
            // appears at the *start* of a line (i.e. the line
            // buffer is empty). Otherwise it's content — typically
            // an OSC hyperlink's String-Terminator embedded inside a
            // capture-pane response. Treating it as DCS-end mid-line
            // ate the rest of the response and the `%exit` that
            // followed.
            if byte == 0x5C /* '\' */, lineBuffer.isEmpty {
                framing = .afterDCS
                events.append(.dcsEnd)
                return
            }
            // Not a real ST — push the ESC back and reprocess the
            // byte as a normal in-DCS byte (so CSI/OSC sequences
            // survive in the content).
            lineBuffer.append(0x1B)
            framing = .inDCS
            step(byte, events: &events)

        case .afterDCS:
            break
        }
    }

    private mutating func flushLine(events: inout [TmuxEvent]) {
        guard !lineBuffer.isEmpty else { return }
        // Strip a trailing CR so CRLF-terminated streams (the default
        // when tmux runs behind a PTY with ONLCR) parse the same as
        // LF-only streams.
        if lineBuffer.last == 0x0D {
            lineBuffer.removeLast()
        }
        guard !lineBuffer.isEmpty else {
            return
        }
        let line = String(decoding: lineBuffer, as: UTF8.self)
        lineBuffer.removeAll(keepingCapacity: true)
        events.append(parseLine(line))
    }

    // MARK: - Line parsing

    private func parseLine(_ line: String) -> TmuxEvent {
        guard line.hasPrefix("%") else {
            return .responseLine(line)
        }
        guard let spaceIdx = line.firstIndex(of: " ") else {
            return dispatch(keyword: line, rest: "")
        }
        let keyword = String(line[..<spaceIdx])
        let rest = String(line[line.index(after: spaceIdx)...])
        return dispatch(keyword: keyword, rest: rest)
    }

    private func dispatch(keyword: String, rest: String) -> TmuxEvent {
        switch keyword {
        case "%begin":
            return parseResponseBracket(rest, ctor: TmuxEvent.begin)
        case "%end":
            return parseResponseBracket(rest, ctor: TmuxEvent.end)
        case "%error":
            return parseResponseBracket(rest, ctor: TmuxEvent.responseError)

        case "%output":
            return parseOutput(rest)

        case "%session-changed":
            return parseIDAndName(
                rest,
                idParser: parseSessionID,
                ctor: { .sessionChanged(sessionID: $0, name: $1) }
            )
        case "%session-renamed":
            return parseIDAndName(
                rest,
                idParser: parseSessionID,
                ctor: { .sessionRenamed(sessionID: $0, name: $1) }
            )
        case "%sessions-changed":
            return .sessionsChanged
        case "%session-window-changed":
            return parseSessionWindowChanged(rest)

        case "%window-add":
            return parseSingleWindow(rest, ctor: TmuxEvent.windowAdd)
        case "%window-close":
            return parseSingleWindow(rest, ctor: TmuxEvent.windowClose)
        case "%window-renamed":
            return parseIDAndName(
                rest,
                idParser: parseWindowID,
                ctor: { .windowRenamed(windowID: $0, name: $1) }
            )
        case "%window-pane-changed":
            return parseWindowPaneChanged(rest)
        case "%layout-change":
            return parseLayoutChange(rest)

        case "%unlinked-window-add":
            return parseSingleWindow(rest, ctor: TmuxEvent.unlinkedWindowAdd)
        case "%unlinked-window-close":
            return parseSingleWindow(rest, ctor: TmuxEvent.unlinkedWindowClose)
        case "%unlinked-window-renamed":
            return parseIDAndName(
                rest,
                idParser: parseWindowID,
                ctor: { .unlinkedWindowRenamed(windowID: $0, name: $1) }
            )

        case "%pane-mode-changed":
            return parseSinglePane(rest, ctor: TmuxEvent.paneModeChanged)

        case "%client-session-changed":
            return parseClientSessionChanged(rest)
        case "%subscription-changed":
            return .subscriptionChanged(raw: rest)

        case "%pause":
            return parseSinglePane(rest, ctor: TmuxEvent.pause)
        case "%continue":
            return parseSinglePane(rest, ctor: TmuxEvent.continuePane)

        case "%exit":
            return .exit(reason: rest.isEmpty ? nil : rest)

        default:
            return .unknown(rest.isEmpty ? keyword : "\(keyword) \(rest)")
        }
    }

    // MARK: - Field parsers

    private func parseResponseBracket(
        _ rest: String,
        ctor: (Int, Int, Int) -> TmuxEvent
    ) -> TmuxEvent {
        let parts = rest.split(separator: " ").map(String.init)
        guard parts.count == 3,
              let t = Int(parts[0]),
              let n = Int(parts[1]),
              let f = Int(parts[2])
        else { return .unknown(rest) }
        return ctor(t, n, f)
    }

    private func parseOutput(_ rest: String) -> TmuxEvent {
        guard let spaceIdx = rest.firstIndex(of: " ") else {
            return .unknown(rest)
        }
        let paneStr = String(rest[..<spaceIdx])
        let dataStr = String(rest[rest.index(after: spaceIdx)...])
        guard let paneID = parsePaneID(paneStr) else {
            return .unknown(rest)
        }
        return .output(paneID: paneID, data: OutputDecoder.decode(dataStr))
    }

    private func parseIDAndName(
        _ rest: String,
        idParser: (String) -> Int?,
        ctor: (Int, String) -> TmuxEvent
    ) -> TmuxEvent {
        guard let spaceIdx = rest.firstIndex(of: " ") else {
            return .unknown(rest)
        }
        let idStr = String(rest[..<spaceIdx])
        let name = String(rest[rest.index(after: spaceIdx)...])
        guard let id = idParser(idStr) else { return .unknown(rest) }
        return ctor(id, name)
    }

    private func parseSessionWindowChanged(_ rest: String) -> TmuxEvent {
        let parts = rest.split(separator: " ").map(String.init)
        guard parts.count == 2,
              let s = parseSessionID(parts[0]),
              let w = parseWindowID(parts[1])
        else { return .unknown(rest) }
        return .sessionWindowChanged(sessionID: s, windowID: w)
    }

    private func parseSingleWindow(
        _ rest: String,
        ctor: (Int) -> TmuxEvent
    ) -> TmuxEvent {
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        guard let w = parseWindowID(trimmed) else { return .unknown(rest) }
        return ctor(w)
    }

    private func parseSinglePane(
        _ rest: String,
        ctor: (Int) -> TmuxEvent
    ) -> TmuxEvent {
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        guard let p = parsePaneID(trimmed) else { return .unknown(rest) }
        return ctor(p)
    }

    private func parseWindowPaneChanged(_ rest: String) -> TmuxEvent {
        let parts = rest.split(separator: " ").map(String.init)
        guard parts.count == 2,
              let w = parseWindowID(parts[0]),
              let p = parsePaneID(parts[1])
        else { return .unknown(rest) }
        return .windowPaneChanged(windowID: w, paneID: p)
    }

    private func parseLayoutChange(_ rest: String) -> TmuxEvent {
        let parts = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, let w = parseWindowID(parts[0]) else {
            return .unknown(rest)
        }
        let layout = parts[1]
        let visible = parts.count >= 3 ? parts[2] : nil
        let flags = parts.count >= 4 ? parts[3] : nil
        return .layoutChange(windowID: w, layout: layout, visibleLayout: visible, flags: flags)
    }

    private func parseClientSessionChanged(_ rest: String) -> TmuxEvent {
        let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            .map(String.init)
        guard parts.count == 3,
              let s = parseSessionID(parts[1])
        else { return .unknown(rest) }
        return .clientSessionChanged(client: parts[0], sessionID: s, name: parts[2])
    }

    // MARK: - ID parsers

    private func parseSessionID(_ s: String) -> Int? {
        guard s.hasPrefix("$") else { return nil }
        return Int(s.dropFirst())
    }

    private func parseWindowID(_ s: String) -> Int? {
        guard s.hasPrefix("@") else { return nil }
        return Int(s.dropFirst())
    }

    private func parsePaneID(_ s: String) -> Int? {
        guard s.hasPrefix("%") else { return nil }
        return Int(s.dropFirst())
    }
}
