import Foundation

/// In-memory model of an OpenSSH `known_hosts` file. Immutable;
/// `adding(...)` returns a new value with one extra entry appended.
public struct KnownHosts: Sendable, Equatable {
    public let entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public init(text: String) {
        self.entries = Parser.parse(text)
    }

    public static func load(url: URL) throws -> KnownHosts {
        let text = try String(contentsOf: url, encoding: .utf8)
        return KnownHosts(text: text)
    }

    /// Look up a presented `(host, port, keyType, keyData)` against
    /// the entries. The order of checks matters:
    ///
    /// 1. **`@revoked`** wins outright — if any matching entry with
    ///    the same key type and bytes is revoked, return `.revoked`.
    /// 2. **Exact match** — same host pattern, same key type, same
    ///    bytes → `.match`.
    /// 3. **Mismatch** — same host pattern, same key type, different
    ///    bytes → `.mismatch(existing:)`. This is the MITM signal.
    /// 4. **`.unknown`** — no entry covers the host at all (or covers
    ///    it only with a different key type, e.g. RSA on file but
    ///    Ed25519 presented).
    public func match(
        host: String,
        port: Int = 22,
        keyType: String,
        keyData: Data
    ) -> MatchResult {
        let matchingEntries = entries.filter { $0.matches(host: host, port: port) }
        if matchingEntries.isEmpty { return .unknown }

        // Revocations take precedence and are scoped by keyType+bytes.
        for entry in matchingEntries
        where entry.marker == .revoked
            && entry.keyType == keyType
            && entry.keyData == keyData {
            return .revoked(entry)
        }

        let nonRevokedSameType = matchingEntries.filter {
            $0.marker != .revoked && $0.keyType == keyType
        }
        for entry in nonRevokedSameType where entry.keyData == keyData {
            return .match
        }
        if let conflicting = nonRevokedSameType.first {
            return .mismatch(existing: conflicting)
        }
        return .unknown
    }

    /// Append a new entry for `(host, port, keyType, keyData)`. The
    /// new entry uses a plain (unhashed) host pattern. If `port` is
    /// 22, no port is recorded; otherwise the `[host]:port` form is
    /// used.
    public func adding(
        host: String,
        port: Int = 22,
        keyType: String,
        keyData: Data,
        marker: Entry.Marker = .none,
        comment: String? = nil
    ) -> KnownHosts {
        let pattern: HostPattern = (port == 22)
            ? .plain(host: host, port: nil)
            : .plain(host: host, port: port)
        let entry = Entry(
            marker: marker,
            hostPatterns: [pattern],
            keyType: keyType,
            keyData: keyData,
            comment: comment
        )
        return KnownHosts(entries: entries + [entry])
    }

    public func serialized() -> String {
        Serializer.serialize(entries)
    }

    public func write(to url: URL) throws {
        try serialized().write(to: url, atomically: true, encoding: .utf8)
    }
}
