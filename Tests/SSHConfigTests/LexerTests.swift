import XCTest
@testable import SSHConfig

final class LexerTests: XCTestCase {
    private func lex(_ line: String) throws -> (String, [String])? {
        guard let r = try Lexer.lex(line: line, lineNumber: 1, file: nil) else { return nil }
        return (r.keyword, r.arguments)
    }

    func test_emptyOrWhitespaceOnlyLinesReturnNil() throws {
        XCTAssertNil(try lex(""))
        XCTAssertNil(try lex("   "))
        XCTAssertNil(try lex("\t\t"))
    }

    func test_commentLinesReturnNil() throws {
        XCTAssertNil(try lex("# comment"))
        XCTAssertNil(try lex("   # indented"))
        XCTAssertNil(try lex("\t# tabbed"))
    }

    func test_simpleDirective() throws {
        let r = try XCTUnwrap(try lex("Host example.com"))
        XCTAssertEqual(r.0, "Host")
        XCTAssertEqual(r.1, ["example.com"])
    }

    func test_equalsSeparatorNoSpaces() throws {
        let r = try XCTUnwrap(try lex("Port=2222"))
        XCTAssertEqual(r.0, "Port")
        XCTAssertEqual(r.1, ["2222"])
    }

    func test_equalsSeparatorWithSpaces() throws {
        let r = try XCTUnwrap(try lex("Port = 2222"))
        XCTAssertEqual(r.0, "Port")
        XCTAssertEqual(r.1, ["2222"])
    }

    func test_multipleArguments() throws {
        let r = try XCTUnwrap(try lex("SendEnv LANG LC_ALL LC_CTYPE"))
        XCTAssertEqual(r.1, ["LANG", "LC_ALL", "LC_CTYPE"])
    }

    func test_quotedArgumentWithSpaces() throws {
        let r = try XCTUnwrap(try lex(#"RemoteCommand "echo hello world""#))
        XCTAssertEqual(r.1, ["echo hello world"])
    }

    func test_quotedArgumentWithEscapes() throws {
        let r = try XCTUnwrap(try lex(#"RemoteCommand "a\"b\\c""#))
        XCTAssertEqual(r.1, [#"a"b\c"#])
    }

    func test_unterminatedQuoteThrows() {
        XCTAssertThrowsError(try lex(#"RemoteCommand "oops"#)) { error in
            guard case .unterminatedQuote = (error as? SSHConfigError)?.kind else {
                return XCTFail("expected unterminatedQuote, got \(error)")
            }
        }
    }

    func test_tabSeparator() throws {
        let r = try XCTUnwrap(try lex("Port\t2222"))
        XCTAssertEqual(r.0, "Port")
        XCTAssertEqual(r.1, ["2222"])
    }

    func test_tabsAndSpacesMixed() throws {
        let r = try XCTUnwrap(try lex("  Host \t *.example.com  "))
        XCTAssertEqual(r.0, "Host")
        XCTAssertEqual(r.1, ["*.example.com"])
    }

    func test_mixedQuotedAndUnquotedArgs() throws {
        let r = try XCTUnwrap(try lex(#"SendEnv LANG "LC with space" LC_ALL"#))
        XCTAssertEqual(r.1, ["LANG", "LC with space", "LC_ALL"])
    }

    func test_hashInsideArgumentIsLiteral() throws {
        // OpenSSH treats '#' as a comment only at the start of a line.
        let r = try XCTUnwrap(try lex("Host foo#bar"))
        XCTAssertEqual(r.1, ["foo#bar"])
    }
}
