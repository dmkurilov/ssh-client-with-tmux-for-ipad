import Foundation

public struct TokenContext: Sendable {
    public let localUser: String
    public let localHost: String
    public let localHostFQDN: String
    public let remoteUser: String?
    public let remoteHost: String?
    public let originalHost: String?
    public let remotePort: Int?
    public let homeDirectory: String

    public init(
        localUser: String = NSUserName(),
        localHost: String = ProcessInfo.processInfo.hostName,
        localHostFQDN: String = ProcessInfo.processInfo.hostName,
        remoteUser: String? = nil,
        remoteHost: String? = nil,
        originalHost: String? = nil,
        remotePort: Int? = nil,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.localUser = localUser
        self.localHost = localHost
        self.localHostFQDN = localHostFQDN
        self.remoteUser = remoteUser
        self.remoteHost = remoteHost
        self.originalHost = originalHost
        self.remotePort = remotePort
        self.homeDirectory = homeDirectory
    }
}

/// Expand OpenSSH-style `%` tokens in a string. Not every keyword supports
/// every token — this is a raw expansion; callers decide which keywords to
/// apply it to.
public enum TokenExpander {
    public static func expand(_ input: String, with context: TokenContext) -> String {
        var result = ""
        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            if c != "%" {
                result.append(c)
                i = input.index(after: i)
                continue
            }
            let next = input.index(after: i)
            guard next < input.endIndex else {
                result.append(c)
                i = next
                continue
            }
            let token = input[next]
            let replacement: String? = replacement(for: token, context: context)
            if let r = replacement {
                result.append(r)
            } else {
                result.append(c)
                result.append(token)
            }
            i = input.index(after: next)
        }
        return result
    }

    private static func replacement(for token: Character, context: TokenContext) -> String? {
        switch token {
        case "%":
            return "%"
        case "h":
            return context.remoteHost
        case "n":
            return context.originalHost
        case "p":
            return context.remotePort.map(String.init)
        case "r":
            return context.remoteUser
        case "u":
            return context.localUser
        case "l":
            return context.localHostFQDN
        case "L":
            let h = context.localHost
            if let dot = h.firstIndex(of: ".") {
                return String(h[..<dot])
            }
            return h
        case "d":
            return context.homeDirectory
        default:
            return nil
        }
    }
}
