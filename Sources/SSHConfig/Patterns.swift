import Foundation

enum Pattern {
    /// Glob match with `*` (zero or more) and `?` (exactly one). Both inputs
    /// must already be case-normalized by the caller if case-insensitive
    /// matching is desired.
    static func glob(pattern: String, candidate: String) -> Bool {
        let p = Array(pattern)
        let s = Array(candidate)
        var pi = 0
        var si = 0
        var starP = -1
        var starS = 0

        while si < s.count {
            if pi < p.count, p[pi] == "?" || p[pi] == s[si] {
                pi += 1
                si += 1
            } else if pi < p.count, p[pi] == "*" {
                starP = pi
                starS = si
                pi += 1
            } else if starP >= 0 {
                pi = starP + 1
                starS += 1
                si = starS
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" {
            pi += 1
        }
        return pi == p.count
    }

    /// Split a comma-separated pattern list into `HostPattern`s, preserving
    /// leading `!` negation markers. Whitespace around each entry is trimmed.
    static func splitList(_ raw: String) -> [HostPattern] {
        raw.split(separator: ",").map {
            HostPattern(String($0).trimmingCharacters(in: .whitespaces))
        }
    }

    /// Evaluate an OpenSSH pattern list against a candidate.
    /// Any matching negated pattern causes an overall miss even if other
    /// non-negated patterns match; otherwise, at least one non-negated
    /// pattern must match.
    static func matchList(_ patterns: [HostPattern], against candidate: String) -> Bool {
        var matched = false
        for p in patterns {
            if p.matches(candidate) {
                if p.negated { return false }
                matched = true
            }
        }
        return matched
    }
}
