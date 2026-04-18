import Foundation

final class Parser {
    private let loader: FileLoader
    private let maxIncludeDepth: Int

    init(loader: FileLoader, maxIncludeDepth: Int = 16) {
        self.loader = loader
        self.maxIncludeDepth = maxIncludeDepth
    }

    func parse(
        text: String,
        source: URL?,
        includeDepth: Int = 0,
        visited: Set<URL> = []
    ) throws -> [Block] {
        if includeDepth > maxIncludeDepth {
            throw SSHConfigError(kind: .includeDepthExceeded)
        }
        if let src = source, visited.contains(src) {
            throw SSHConfigError(kind: .includeCycle(src))
        }
        var newVisited = visited
        if let src = source { newVisited.insert(src) }

        var blocks: [Block] = []
        var currentBlock: PartialBlock = .global(directives: [])

        // Normalize line endings. Swift's Character model treats `\r\n` as a
        // single extended grapheme cluster, so splitting on `\n` alone misses
        // CRLF. Normalize to LF first, then split.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
        var lineNumber = 0

        for rawLine in lines {
            lineNumber += 1
            let lineStr = String(rawLine)

            guard let lexed = try Lexer.lex(line: lineStr, lineNumber: lineNumber, file: source) else {
                continue
            }

            let kw = lexed.keyword.lowercased()
            switch kw {
            case "host":
                flush(&currentBlock, into: &blocks)
                let patterns = lexed.arguments.map(HostPattern.init)
                if patterns.isEmpty {
                    throw SSHConfigError(
                        kind: .missingArgument(keyword: "Host"),
                        source: lexed.source
                    )
                }
                currentBlock = .host(patterns: patterns, directives: [], source: lexed.source)

            case "match":
                flush(&currentBlock, into: &blocks)
                let condition = try parseMatchCondition(lexed.arguments, source: lexed.source)
                currentBlock = .match(condition: condition, directives: [], source: lexed.source)

            case "include":
                if lexed.arguments.isEmpty {
                    throw SSHConfigError(
                        kind: .missingArgument(keyword: "Include"),
                        source: lexed.source
                    )
                }
                for pattern in lexed.arguments {
                    let urls: [URL]
                    do {
                        urls = try loader.resolveIncludes(pattern: pattern, relativeTo: source)
                    } catch let e as SSHConfigError {
                        throw e
                    } catch {
                        throw SSHConfigError(
                            kind: .includeResolutionFailed(pattern: pattern, underlying: "\(error)"),
                            source: lexed.source
                        )
                    }
                    for url in urls {
                        let content = try loader.read(url)
                        let subBlocks = try parse(
                            text: content,
                            source: url,
                            includeDepth: includeDepth + 1,
                            visited: newVisited
                        )
                        splice(included: subBlocks, into: &currentBlock, appendingTo: &blocks)
                    }
                }

            default:
                let directive = Directive(
                    keyword: lexed.keyword,
                    arguments: lexed.arguments,
                    source: lexed.source
                )
                append(directive: directive, to: &currentBlock)
            }
        }

        flush(&currentBlock, into: &blocks)
        return blocks
    }

    private func append(directive d: Directive, to block: inout PartialBlock) {
        switch block {
        case .global(var ds):
            ds.append(d)
            block = .global(directives: ds)
        case .host(let p, var ds, let s):
            ds.append(d)
            block = .host(patterns: p, directives: ds, source: s)
        case .match(let c, var ds, let s):
            ds.append(d)
            block = .match(condition: c, directives: ds, source: s)
        }
    }

    private func flush(_ block: inout PartialBlock, into blocks: inout [Block]) {
        switch block {
        case .global(let d):
            if !d.isEmpty { blocks.append(.global(directives: d)) }
        case .host(let p, let d, let s):
            blocks.append(.host(patterns: p, directives: d, source: s))
        case .match(let c, let d, let s):
            blocks.append(.match(condition: c, directives: d, source: s))
        }
        block = .global(directives: [])
    }

    /// Splice the blocks parsed from an included file into the current parse
    /// state. Global directives from the include get appended to the current
    /// block; Host/Match blocks from the include are appended as top-level
    /// blocks and the outer context is reset to a fresh global.
    private func splice(
        included subBlocks: [Block],
        into currentBlock: inout PartialBlock,
        appendingTo blocks: inout [Block]
    ) {
        var sawStructural = false
        for sub in subBlocks {
            if sawStructural {
                blocks.append(sub)
                continue
            }
            switch sub {
            case .global(let directives):
                for d in directives {
                    append(directive: d, to: &currentBlock)
                }
            case .host, .match:
                sawStructural = true
                flush(&currentBlock, into: &blocks)
                blocks.append(sub)
            }
        }
    }

    private func parseMatchCondition(_ args: [String], source: SourceLocation?) throws -> MatchCondition {
        guard !args.isEmpty else {
            throw SSHConfigError(kind: .malformedMatch("empty"), source: source)
        }
        let first = args[0].lowercased()
        if first == "all" {
            return .all
        }
        guard args.count >= 2 else {
            throw SSHConfigError(
                kind: .malformedMatch("keyword '\(first)' needs an argument"),
                source: source
            )
        }
        let patterns = Pattern.splitList(args[1])
        switch first {
        case "host":
            return .host(patterns: patterns)
        case "originalhost":
            return .originalHost(patterns: patterns)
        case "user":
            return .user(patterns: patterns)
        case "localuser":
            return .localUser(patterns: patterns)
        default:
            return .unsupported(keyword: first, argument: args[1])
        }
    }

    private enum PartialBlock {
        case global(directives: [Directive])
        case host(patterns: [HostPattern], directives: [Directive], source: SourceLocation?)
        case match(condition: MatchCondition, directives: [Directive], source: SourceLocation?)
    }
}
