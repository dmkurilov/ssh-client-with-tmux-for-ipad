import Foundation

/// One parsed event from a tmux `-CC` control-mode stream.
///
/// The parser is stateless beyond DCS framing and does not correlate
/// `%begin` with `%end`/`%error`; consumers match on the `number` field.
public enum TmuxEvent: Equatable, Sendable {

    // MARK: - Framing

    /// `\x1bP1000p` — start of the DCS envelope that wraps all `-CC` output.
    case dcsBegin

    /// `\x1b\\` — end of the DCS envelope. Arrives after `%exit`.
    case dcsEnd

    // MARK: - Response bracketing

    case begin(time: Int, number: Int, flags: Int)
    case end(time: Int, number: Int, flags: Int)
    case responseError(time: Int, number: Int, flags: Int)

    /// A non-`%` line — always a payload line of a command response,
    /// bracketed by the most recent `%begin` and `%end`/`%error`.
    case responseLine(String)

    // MARK: - Notifications

    case output(paneID: Int, data: Data)

    case sessionChanged(sessionID: Int, name: String)
    case sessionRenamed(sessionID: Int, name: String)
    case sessionsChanged
    case sessionWindowChanged(sessionID: Int, windowID: Int)

    case windowAdd(windowID: Int)
    case windowClose(windowID: Int)
    case windowRenamed(windowID: Int, name: String)
    case windowPaneChanged(windowID: Int, paneID: Int)

    /// `%layout-change @<id> <layout> [<visible-layout>] [<flags>]`.
    /// Layout strings are deliberately not parsed here — they carry the
    /// nested `{…}` layout mini-language and belong in a higher layer
    /// that renders splits.
    case layoutChange(windowID: Int, layout: String, visibleLayout: String?, flags: String?)

    case unlinkedWindowAdd(windowID: Int)
    case unlinkedWindowClose(windowID: Int)
    case unlinkedWindowRenamed(windowID: Int, name: String)

    case paneModeChanged(paneID: Int)

    case clientSessionChanged(client: String, sessionID: Int, name: String)
    case subscriptionChanged(raw: String)

    case pause(paneID: Int)
    case continuePane(paneID: Int)

    case exit(reason: String?)

    // MARK: - Fallback

    /// A line starting with `%` that didn't match any known pattern, or a
    /// known pattern with malformed arguments. Kept so consumers can log
    /// and so we don't silently drop forward-compatibility surprises.
    case unknown(String)
}
