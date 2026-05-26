import Foundation

struct LexedLine: Equatable {
    let keyword: String
    let arguments: [String]
    let source: SourceLocation
}

enum Lexer {
    /// Lex a single line of an ssh_config file.
    /// Returns `nil` for blank lines and lines whose first non-whitespace
    /// character is `#`. Throws on unterminated quotes or empty keywords.
    static func lex(
        line: String,
        lineNumber: Int,
        file: URL?
    ) throws -> LexedLine? {
        let chars = Array(line)
        var i = 0

        func isSpace(_ c: Character) -> Bool { c == " " || c == "\t" }
        func skipSpaces() {
            while i < chars.count, isSpace(chars[i]) { i += 1 }
        }

        skipSpaces()
        if i == chars.count { return nil }
        if chars[i] == "#" { return nil }

        let keywordStart = i
        while i < chars.count, !isSpace(chars[i]), chars[i] != "=" {
            i += 1
        }
        let keyword = String(chars[keywordStart..<i])
        if keyword.isEmpty {
            throw SSHConfigError(
                kind: .emptyKeyword,
                source: SourceLocation(file: file, line: lineNumber, column: 1)
            )
        }

        // Optional whitespace then an optional single '='.
        skipSpaces()
        if i < chars.count, chars[i] == "=" {
            i += 1
            skipSpaces()
        }

        var args: [String] = []
        while i < chars.count {
            if chars[i] == "\"" {
                let argColumn = i + 1
                i += 1
                var buf = ""
                var terminated = false
                while i < chars.count {
                    let c = chars[i]
                    if c == "\\", i + 1 < chars.count,
                       chars[i + 1] == "\"" || chars[i + 1] == "\\" {
                        buf.append(chars[i + 1])
                        i += 2
                        continue
                    }
                    if c == "\"" {
                        terminated = true
                        i += 1
                        break
                    }
                    buf.append(c)
                    i += 1
                }
                if !terminated {
                    throw SSHConfigError(
                        kind: .unterminatedQuote,
                        source: SourceLocation(file: file, line: lineNumber, column: argColumn)
                    )
                }
                args.append(buf)
            } else {
                let argStart = i
                while i < chars.count, !isSpace(chars[i]) {
                    i += 1
                }
                args.append(String(chars[argStart..<i]))
            }
            skipSpaces()
        }

        return LexedLine(
            keyword: keyword,
            arguments: args,
            source: SourceLocation(file: file, line: lineNumber, column: keywordStart + 1)
        )
    }
}
