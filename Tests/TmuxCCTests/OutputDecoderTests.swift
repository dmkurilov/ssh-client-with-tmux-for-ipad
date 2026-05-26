import XCTest
@testable import TmuxCC

final class OutputDecoderTests: XCTestCase {

    func test_asciiPassesThrough() {
        XCTAssertEqual(
            OutputDecoder.decode("hello world"),
            Data("hello world".utf8)
        )
    }

    func test_emptyInput() {
        XCTAssertEqual(OutputDecoder.decode(""), Data())
    }

    func test_singleOctalEscape_space() {
        // \040 is octal 40 = 0x20 = ' '
        XCTAssertEqual(
            OutputDecoder.decode("a\\040b"),
            Data("a b".utf8)
        )
    }

    func test_octalEscape_newline() {
        // \012 = 0x0A = '\n'
        XCTAssertEqual(
            OutputDecoder.decode("a\\012b"),
            Data([0x61, 0x0A, 0x62])
        )
    }

    func test_octalEscape_backslash() {
        // \134 = 0x5C = '\'
        XCTAssertEqual(
            OutputDecoder.decode("\\134"),
            Data([0x5C])
        )
    }

    func test_octalEscape_maxValue() {
        // \377 = 0xFF
        XCTAssertEqual(
            OutputDecoder.decode("\\377"),
            Data([0xFF])
        )
    }

    func test_octalOutOfRange_passedThrough() {
        // \400 = 256, out of byte range — treated as literal chars.
        XCTAssertEqual(
            OutputDecoder.decode("\\400"),
            Data("\\400".utf8)
        )
    }

    func test_loneBackslash_passedThrough() {
        XCTAssertEqual(
            OutputDecoder.decode("a\\b"),
            Data("a\\b".utf8)
        )
    }

    func test_backslashWithoutEnoughDigits_passedThrough() {
        XCTAssertEqual(
            OutputDecoder.decode("\\01"),
            Data("\\01".utf8)
        )
    }

    func test_multipleEscapes() {
        // "\033]0;title\007" — typical OSC sequence
        XCTAssertEqual(
            OutputDecoder.decode("\\033]0;title\\007"),
            Data([0x1B, 0x5D, 0x30, 0x3B] + Array("title".utf8) + [0x07])
        )
    }

    func test_highBytesPassThrough() {
        // UTF-8 bytes for "é" (0xC3 0xA9) pass through verbatim.
        XCTAssertEqual(
            OutputDecoder.decode("caf\u{00E9}"),
            Data([0x63, 0x61, 0x66, 0xC3, 0xA9])
        )
    }
}
