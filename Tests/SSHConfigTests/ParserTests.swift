import XCTest
@testable import SSHConfig

final class ParserTests: XCTestCase {
    private func parse(_ text: String) throws -> [Block] {
        // These tests don't use Include, so the loader is never invoked.
        let parser = Parser(loader: DiskFileLoader())
        return try parser.parse(text: text, source: nil)
    }

    func test_globalDirectivesOnly() throws {
        let blocks = try parse("""
        User alice
        Port 22
        """)
        XCTAssertEqual(blocks.count, 1)
        guard case .global(let directives) = blocks[0] else {
            return XCTFail("expected global block")
        }
        XCTAssertEqual(directives.map(\.normalizedKeyword), ["user", "port"])
    }

    func test_singleHostBlock() throws {
        let blocks = try parse("""
        Host example.com
            HostName 10.0.0.1
            User bob
        """)
        XCTAssertEqual(blocks.count, 1)
        guard case .host(let patterns, let directives, _) = blocks[0] else {
            return XCTFail("expected host block")
        }
        XCTAssertEqual(patterns.map(\.pattern), ["example.com"])
        XCTAssertEqual(directives.count, 2)
    }

    func test_multipleHostBlocks() throws {
        let blocks = try parse("""
        Host a
            User u1
        Host b
            User u2
        """)
        XCTAssertEqual(blocks.count, 2)
    }

    func test_globalFollowedByHost() throws {
        let blocks = try parse("""
        User fallback

        Host special
            User specialuser
        """)
        XCTAssertEqual(blocks.count, 2)
        guard case .global(let d) = blocks[0] else { return XCTFail() }
        XCTAssertEqual(d.count, 1)
        guard case .host = blocks[1] else { return XCTFail() }
    }

    func test_commentsAndBlankLinesIgnored() throws {
        let blocks = try parse("""

        # this is a comment
        Host example.com

        # another
            User bob
        """)
        guard case .host(_, let d, _) = blocks[0] else {
            return XCTFail()
        }
        XCTAssertEqual(d.count, 1)
    }

    func test_hostWithMultiplePatterns() throws {
        let blocks = try parse("""
        Host a b !c *.d
            User u
        """)
        guard case .host(let patterns, _, _) = blocks[0] else {
            return XCTFail()
        }
        XCTAssertEqual(patterns.map(\.pattern), ["a", "b", "c", "*.d"])
        XCTAssertEqual(patterns.map(\.negated), [false, false, true, false])
    }

    func test_matchAll() throws {
        let blocks = try parse("""
        Match all
            User mu
        """)
        guard case .match(let cond, _, _) = blocks[0] else {
            return XCTFail()
        }
        if case .all = cond {} else { XCTFail("expected .all") }
    }

    func test_matchHost() throws {
        let blocks = try parse("""
        Match host *.example.com
            User bob
        """)
        guard case .match(let cond, _, _) = blocks[0] else {
            return XCTFail()
        }
        if case .host(let patterns) = cond {
            XCTAssertEqual(patterns.map(\.pattern), ["*.example.com"])
        } else {
            XCTFail("expected .host condition")
        }
    }

    func test_matchUnsupportedKeyword() throws {
        let blocks = try parse("""
        Match exec /bin/true
            User bob
        """)
        guard case .match(let cond, _, _) = blocks[0] else {
            return XCTFail()
        }
        if case .unsupported(let keyword, _) = cond {
            XCTAssertEqual(keyword, "exec")
        } else {
            XCTFail("expected .unsupported")
        }
    }

    func test_missingHostPatternThrows() {
        XCTAssertThrowsError(try parse("Host\nUser x")) { error in
            guard case .missingArgument(let k) = (error as? SSHConfigError)?.kind,
                  k == "Host" else {
                return XCTFail("expected missingArgument(Host), got \(error)")
            }
        }
    }

    func test_missingMatchConditionThrows() {
        XCTAssertThrowsError(try parse("Match\nUser x"))
    }

    func test_crlfLineEndings() throws {
        let blocks = try parse("Host foo\r\n    User u\r\n")
        XCTAssertEqual(blocks.count, 1)
        guard case .host(_, let d, _) = blocks[0] else { return XCTFail() }
        XCTAssertEqual(d.first?.arguments, ["u"])
    }
}
