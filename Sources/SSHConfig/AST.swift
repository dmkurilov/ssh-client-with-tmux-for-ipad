import Foundation

public struct Directive: Equatable, Sendable {
    public let keyword: String
    public let normalizedKeyword: String
    public let arguments: [String]
    public let source: SourceLocation?

    public init(keyword: String, arguments: [String], source: SourceLocation? = nil) {
        self.keyword = keyword
        self.normalizedKeyword = keyword.lowercased()
        self.arguments = arguments
        self.source = source
    }
}

public enum Block: Sendable, Equatable {
    case global(directives: [Directive])
    case host(patterns: [HostPattern], directives: [Directive], source: SourceLocation?)
    case match(condition: MatchCondition, directives: [Directive], source: SourceLocation?)

    public var directives: [Directive] {
        switch self {
        case .global(let d): return d
        case .host(_, let d, _): return d
        case .match(_, let d, _): return d
        }
    }
}

public struct HostPattern: Equatable, Sendable {
    public let pattern: String
    public let negated: Bool

    public init(_ raw: String) {
        if raw.hasPrefix("!") {
            self.negated = true
            self.pattern = String(raw.dropFirst())
        } else {
            self.negated = false
            self.pattern = raw
        }
    }

    public func matches(_ candidate: String) -> Bool {
        Pattern.glob(pattern: pattern.lowercased(), candidate: candidate.lowercased())
    }
}

public enum MatchCondition: Sendable, Equatable {
    case all
    case host(patterns: [HostPattern])
    case originalHost(patterns: [HostPattern])
    case user(patterns: [HostPattern])
    case localUser(patterns: [HostPattern])
    case unsupported(keyword: String, argument: String?)
}

public struct ResolutionContext: Sendable {
    public let host: String
    public let originalHost: String
    public let user: String?
    public let localUser: String
    public let port: Int?

    public init(
        host: String,
        originalHost: String? = nil,
        user: String? = nil,
        localUser: String = NSUserName(),
        port: Int? = nil
    ) {
        self.host = host
        self.originalHost = originalHost ?? host
        self.user = user
        self.localUser = localUser
        self.port = port
    }
}
