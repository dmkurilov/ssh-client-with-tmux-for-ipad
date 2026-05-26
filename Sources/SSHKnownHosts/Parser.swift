import Foundation

/// Parses OpenSSH `known_hosts` content into `[Entry]`. Malformed
/// lines are silently skipped (matching OpenSSH's permissive
/// behavior); blank lines and `#` comment lines are ignored.
enum Parser {
    static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        // Normalize line endings — Swift treats `\r\n` as a single
        // extended grapheme cluster, so a Character-level split on
        // `\n` would never fire on CRLF input.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
        for raw in lines {
            let trimmed = String(raw).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if let entry = parseLine(trimmed) {
                entries.append(entry)
            }
        }
        return entries
    }

    private static func parseLine(_ line: String) -> Entry? {
        var tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return nil }

        var marker: Entry.Marker = .none
        if tokens[0] == "@cert-authority" {
            marker = .certAuthority
            tokens.removeFirst()
        } else if tokens[0] == "@revoked" {
            marker = .revoked
            tokens.removeFirst()
        }

        guard tokens.count >= 3 else { return nil }
        let hostPatternsField = tokens[0]
        let keyType = tokens[1]
        let keyB64 = tokens[2]
        let comment: String? = tokens.count > 3
            ? tokens[3...].joined(separator: " ")
            : nil

        guard let keyData = Data(base64Encoded: keyB64) else { return nil }
        let hostPatterns = parseHostPatterns(hostPatternsField)
        guard !hostPatterns.isEmpty else { return nil }

        return Entry(
            marker: marker,
            hostPatterns: hostPatterns,
            keyType: keyType,
            keyData: keyData,
            comment: comment
        )
    }

    private static func parseHostPatterns(_ field: String) -> [HostPattern] {
        // The hashed form is one pattern per line and must not be
        // comma-split.
        if field.hasPrefix("|1|") {
            return parseHashed(field).map { [$0] } ?? []
        }
        return field.split(separator: ",").compactMap { parsePlain(String($0)) }
    }

    private static func parseHashed(_ field: String) -> HostPattern? {
        // `|1|<base64-salt>|<base64-hash>`
        let parts = field.split(separator: "|", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, parts[0] == "1" else { return nil }
        guard let salt = Data(base64Encoded: parts[1]),
              let hash = Data(base64Encoded: parts[2]) else {
            return nil
        }
        return .hashed(salt: salt, hash: hash)
    }

    private static func parsePlain(_ raw: String) -> HostPattern? {
        // Strip leading `!` (negation — recognized but not yet
        // honored in matching). Empty patterns are dropped.
        var s = raw
        if s.hasPrefix("!") { s.removeFirst() }
        guard !s.isEmpty else { return nil }

        // `[host]:port`
        if s.hasPrefix("[") {
            guard let endBracket = s.firstIndex(of: "]") else {
                return .plain(host: String(s.dropFirst()), port: nil)
            }
            let host = String(s[s.index(after: s.startIndex)..<endBracket])
            let after = s[s.index(after: endBracket)...]
            if after.hasPrefix(":"), let port = Int(after.dropFirst()) {
                return .plain(host: host, port: port)
            }
            return .plain(host: host, port: nil)
        }
        return .plain(host: s, port: nil)
    }
}
