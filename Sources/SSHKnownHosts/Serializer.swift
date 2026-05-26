import Foundation

/// Renders `[Entry]` back to OpenSSH `known_hosts` format. One line
/// per entry, terminated by `\n`. Comments and blank lines from the
/// original source are not preserved — only entries.
enum Serializer {
    static func serialize(_ entries: [Entry]) -> String {
        guard !entries.isEmpty else { return "" }
        return entries.map(serialize).joined(separator: "\n") + "\n"
    }

    private static func serialize(_ entry: Entry) -> String {
        var parts: [String] = []
        switch entry.marker {
        case .none: break
        case .certAuthority: parts.append("@cert-authority")
        case .revoked: parts.append("@revoked")
        }
        let hostsField = entry.hostPatterns.map(serializePattern).joined(separator: ",")
        parts.append(hostsField)
        parts.append(entry.keyType)
        parts.append(entry.keyData.base64EncodedString())
        if let comment = entry.comment, !comment.isEmpty {
            parts.append(comment)
        }
        return parts.joined(separator: " ")
    }

    private static func serializePattern(_ pattern: HostPattern) -> String {
        switch pattern {
        case .plain(let host, .some(let port)):
            return "[\(host)]:\(port)"
        case .plain(let host, .none):
            return host
        case .hashed(let salt, let hash):
            return "|1|\(salt.base64EncodedString())|\(hash.base64EncodedString())"
        }
    }
}
