import Foundation

/// One line in a known_hosts file: a marker, one or more host
/// patterns, a key type, the key itself, and an optional comment.
public struct Entry: Sendable, Equatable {
    public enum Marker: Sendable, Equatable {
        case none
        case certAuthority
        case revoked
    }

    public let marker: Marker
    public let hostPatterns: [HostPattern]

    /// E.g. `"ssh-ed25519"`, `"ssh-rsa"`, `"ecdsa-sha2-nistp256"`.
    public let keyType: String

    /// Raw key bytes (base64 already decoded).
    public let keyData: Data

    /// Free-form trailing text from the line, if any.
    public let comment: String?

    public init(
        marker: Marker = .none,
        hostPatterns: [HostPattern],
        keyType: String,
        keyData: Data,
        comment: String? = nil
    ) {
        self.marker = marker
        self.hostPatterns = hostPatterns
        self.keyType = keyType
        self.keyData = keyData
        self.comment = comment
    }

    /// `true` if any of this entry's host patterns match the given
    /// `(host, port)`.
    public func matches(host: String, port: Int) -> Bool {
        hostPatterns.contains { $0.matches(host: host, port: port) }
    }
}
