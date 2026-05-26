import Foundation

/// Result of looking up a host's key in a known_hosts collection.
public enum MatchResult: Sendable, Equatable {
    /// The presented key bytes match the entry on file. Trust.
    case match

    /// We have an entry for this host with the same key type, but
    /// the key bytes differ. Possible MITM — surface a strong warning
    /// to the user.
    case mismatch(existing: Entry)

    /// No entry covers this host. Caller should TOFU-prompt and, on
    /// accept, append a fresh entry.
    case unknown

    /// The host is explicitly marked `@revoked`. Refuse the
    /// connection regardless of key.
    case revoked(Entry)
}
