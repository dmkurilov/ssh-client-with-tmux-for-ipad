import Foundation

public struct SourceLocation: Equatable, Sendable, CustomStringConvertible {
    public let file: URL?
    public let line: Int
    public let column: Int

    public init(file: URL?, line: Int, column: Int) {
        self.file = file
        self.line = line
        self.column = column
    }

    public var description: String {
        let name = file?.lastPathComponent ?? "<input>"
        return "\(name):\(line):\(column)"
    }
}

public struct SSHConfigError: Error, CustomStringConvertible, Sendable {
    public enum Kind: Sendable, Equatable {
        case unterminatedQuote
        case emptyKeyword
        case missingArgument(keyword: String)
        case malformedMatch(String)
        case includeCycle(URL)
        case includeDepthExceeded
        case includeResolutionFailed(pattern: String, underlying: String)
    }

    public let kind: Kind
    public let source: SourceLocation?

    public init(kind: Kind, source: SourceLocation? = nil) {
        self.kind = kind
        self.source = source
    }

    public var description: String {
        let sourceDesc = source.map { " at \($0)" } ?? ""
        return "ssh_config error: \(describe(kind))\(sourceDesc)"
    }

    private func describe(_ kind: Kind) -> String {
        switch kind {
        case .unterminatedQuote:
            return "unterminated double-quoted argument"
        case .emptyKeyword:
            return "empty keyword"
        case .missingArgument(let k):
            return "missing argument for '\(k)'"
        case .malformedMatch(let m):
            return "malformed Match condition: \(m)"
        case .includeCycle(let url):
            return "Include cycle detected at \(url.path)"
        case .includeDepthExceeded:
            return "Include depth limit exceeded"
        case .includeResolutionFailed(let p, let u):
            return "Include pattern '\(p)' failed: \(u)"
        }
    }
}
