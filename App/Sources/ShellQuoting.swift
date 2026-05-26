import Foundation

/// Two flavors of shell-arg quoting, picked by context.
///
/// The naive single-quote-wrap (`'…'`, with internal quotes
/// `'\''`-encoded) is the right answer for a *top-level* shell
/// command argument or for input to tmux's own command parser —
/// but it explodes if you try to drop it inside an *outer*
/// single-quoted shell string (e.g. `$SHELL -lc '… \(arg) …'`),
/// because the inner quotes close the outer one. The two helpers
/// here cover both cases; pick the one matching where the result
/// will land.
enum ShellQuoting {
    /// Wrap `s` for use as a top-level shell argument (or as input
    /// to tmux's command interpreter). Internal single quotes are
    /// encoded with the standard close-escape-reopen trick.
    ///
    /// Do **not** use this when interpolating into a string that's
    /// already inside outer single quotes — use `embeddedInSingle`
    /// instead.
    static func topLevel(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Wrap `s` for embedding *inside* an outer single-quoted shell
    /// string, e.g. `"$SHELL -lc '… \(embeddedInSingle(name)) …'"`.
    /// Result is a double-quoted string with backslash escapes for
    /// the characters the inner shell still interprets inside
    /// `"…"`: `\`, `"`, `$`, `` ` ``.
    ///
    /// The outer single quotes pass the double-quoted token through
    /// verbatim to the inner shell; the inner shell then parses
    /// the double quotes when executing. Single-quoting at the
    /// inner level would close the outer wrapper — that's the bug
    /// this exists to avoid.
    static func embeddedInSingle(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"" + escaped + "\""
    }
}
