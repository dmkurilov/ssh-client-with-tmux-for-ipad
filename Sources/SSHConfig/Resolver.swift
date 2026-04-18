import Foundation

public struct ResolvedConfig: Sendable, Equatable {
    /// For each lowercased keyword, the full ordered list of argument vectors
    /// encountered during resolution. The first entry wins for non-
    /// accumulating keywords; use `allArgs(_:)` for keywords like
    /// `IdentityFile` that may accumulate.
    public let values: [String: [[String]]]

    public init(values: [String: [[String]]]) {
        self.values = values
    }

    public func firstArg(_ keyword: String) -> String? {
        values[keyword.lowercased()]?.first?.first
    }

    public func firstArgs(_ keyword: String) -> [String]? {
        values[keyword.lowercased()]?.first
    }

    public func allArgs(_ keyword: String) -> [[String]] {
        values[keyword.lowercased()] ?? []
    }

    public var hostName: String? { firstArg("hostname") }
    public var port: Int? { firstArg("port").flatMap(Int.init) }
    public var user: String? { firstArg("user") }
    public var identityFiles: [String] {
        allArgs("identityfile").compactMap(\.first)
    }
    public var proxyJump: String? { firstArg("proxyjump") }
    public var proxyCommand: String? {
        firstArgs("proxycommand").map { $0.joined(separator: " ") }
    }
    public var preferredAuthentications: [String] {
        (firstArg("preferredauthentications") ?? "")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

public struct Resolver: Sendable {
    public init() {}

    public func resolve(blocks: [Block], context: ResolutionContext) -> ResolvedConfig {
        var values: [String: [[String]]] = [:]
        for block in blocks {
            guard matches(block, context: context) else { continue }
            for d in block.directives {
                values[d.normalizedKeyword, default: []].append(d.arguments)
            }
        }
        return ResolvedConfig(values: values)
    }

    private func matches(_ block: Block, context: ResolutionContext) -> Bool {
        switch block {
        case .global:
            return true
        case .host(let patterns, _, _):
            return Pattern.matchList(patterns, against: context.host)
        case .match(let condition, _, _):
            return matches(condition: condition, context: context)
        }
    }

    private func matches(condition: MatchCondition, context: ResolutionContext) -> Bool {
        switch condition {
        case .all:
            return true
        case .host(let patterns):
            return Pattern.matchList(patterns, against: context.host)
        case .originalHost(let patterns):
            return Pattern.matchList(patterns, against: context.originalHost)
        case .user(let patterns):
            guard let user = context.user else { return false }
            return Pattern.matchList(patterns, against: user)
        case .localUser(let patterns):
            return Pattern.matchList(patterns, against: context.localUser)
        case .unsupported:
            // TODO: support Match exec, final, canonical.
            return false
        }
    }
}
