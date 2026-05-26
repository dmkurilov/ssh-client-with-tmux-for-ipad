import Foundation

/// Parsed tmux layout tree. tmux emits layout strings on
/// `%layout-change` and they look like:
///
///     abc1,80x24,0,0{40x24,0,0,1,40x24,40,0,2}
///     ^    ^      ^^ ^
///     |    |      || └── children (`{}` = side-by-side, `[]` = stacked)
///     |    |      └── X,Y position in cells
///     |    └── cols x rows
///     └── 16-bit checksum (4 hex chars), discarded
///
/// Leaves carry the pane ID; branches carry orientation + children.
public struct TmuxLayout: Equatable, Sendable {
    public let cols: Int
    public let rows: Int
    public let x: Int
    public let y: Int
    public let node: Node

    public indirect enum Node: Equatable, Sendable {
        case leaf(paneID: Int)
        /// Children placed left-to-right (tmux `{}`, vertical split lines).
        case horizontal([TmuxLayout])
        /// Children stacked top-to-bottom (tmux `[]`, horizontal split lines).
        case vertical([TmuxLayout])
    }

    public enum ParseError: Error, Equatable, Sendable {
        case empty
        case missingChecksumComma
        case unexpectedCharacter(expected: String, got: String)
        case unexpectedEnd
        case invalidInteger
    }

    /// Parse a tmux layout string into a tree.
    public static func parse(_ string: String) throws -> TmuxLayout {
        var parser = LayoutParser(s: Substring(string))
        return try parser.parseRoot()
    }

    /// All pane IDs referenced by leaves, in left-to-right tree order.
    public var paneIDs: [Int] {
        switch node {
        case .leaf(let id):
            return [id]
        case .horizontal(let kids), .vertical(let kids):
            return kids.flatMap { $0.paneIDs }
        }
    }
}

private struct LayoutParser {
    var s: Substring

    mutating func parseRoot() throws -> TmuxLayout {
        guard !s.isEmpty else { throw TmuxLayout.ParseError.empty }
        // Strip the 4-hex-char checksum prefix and the comma after it.
        guard let comma = s.firstIndex(of: ",") else {
            throw TmuxLayout.ParseError.missingChecksumComma
        }
        s = s[s.index(after: comma)...]
        return try parseNode()
    }

    mutating func parseNode() throws -> TmuxLayout {
        let cols = try parseInt()
        try expect("x")
        let rows = try parseInt()
        try expect(",")
        let x = try parseInt()
        try expect(",")
        let y = try parseInt()

        switch s.first {
        case "{":
            s.removeFirst()
            let children = try parseChildren()
            try expect("}")
            return TmuxLayout(cols: cols, rows: rows, x: x, y: y, node: .horizontal(children))
        case "[":
            s.removeFirst()
            let children = try parseChildren()
            try expect("]")
            return TmuxLayout(cols: cols, rows: rows, x: x, y: y, node: .vertical(children))
        case ",":
            s.removeFirst()
            let paneID = try parseInt()
            return TmuxLayout(cols: cols, rows: rows, x: x, y: y, node: .leaf(paneID: paneID))
        case .none:
            throw TmuxLayout.ParseError.unexpectedEnd
        case .some(let c):
            throw TmuxLayout.ParseError.unexpectedCharacter(
                expected: "{, [, or ,",
                got: String(c)
            )
        }
    }

    mutating func parseChildren() throws -> [TmuxLayout] {
        var result: [TmuxLayout] = [try parseNode()]
        while s.first == "," {
            s.removeFirst()
            result.append(try parseNode())
        }
        return result
    }

    mutating func parseInt() throws -> Int {
        var end = s.startIndex
        while end < s.endIndex, s[end].isASCII, s[end].isNumber {
            end = s.index(after: end)
        }
        guard end > s.startIndex, let value = Int(s[s.startIndex..<end]) else {
            throw TmuxLayout.ParseError.invalidInteger
        }
        s = s[end...]
        return value
    }

    mutating func expect(_ ch: Character) throws {
        guard let first = s.first else {
            throw TmuxLayout.ParseError.unexpectedEnd
        }
        guard first == ch else {
            throw TmuxLayout.ParseError.unexpectedCharacter(
                expected: String(ch),
                got: String(first)
            )
        }
        s.removeFirst()
    }
}
