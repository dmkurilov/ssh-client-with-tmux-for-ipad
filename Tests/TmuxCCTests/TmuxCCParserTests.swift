import XCTest
@testable import TmuxCC

final class TmuxCCParserTests: XCTestCase {

    // MARK: - DCS framing

    func test_dcsIntroDetected() {
        var parser = TmuxCCParser()
        let events = parser.feed(Data([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]))
        XCTAssertEqual(events, [.dcsBegin])
    }

    func test_dcsIntroSplitAcrossFeeds() {
        var parser = TmuxCCParser()
        XCTAssertEqual(parser.feed(Data([0x1B, 0x50, 0x31])), [])
        XCTAssertEqual(parser.feed(Data([0x30, 0x30])), [])
        XCTAssertEqual(parser.feed(Data([0x30, 0x70])), [.dcsBegin])
    }

    func test_dcsEndDetected() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        let events = parser.feed(Data([0x1B, 0x5C]))
        XCTAssertEqual(events, [.dcsEnd])
    }

    func test_bytesBeforeDCSIntroAreDiscarded() {
        var parser = TmuxCCParser()
        let garbage = Data("random noise before the protocol".utf8)
        XCTAssertEqual(parser.feed(garbage), [])
        XCTAssertEqual(parser.feed(Data([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])), [.dcsBegin])
    }

    func test_escInsideDCSThatIsntST_preservedInLine() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        // ESC followed by a non-'\' byte should be kept as part of the line.
        let events = parser.feed(Data([0x1B, 0x41, 0x0A]))  // ESC A \n
        XCTAssertEqual(events.count, 1)
        if case .responseLine(let s) = events[0] {
            XCTAssertEqual(s, "\u{1B}A")
        } else {
            XCTFail("expected .responseLine, got \(events)")
        }
    }

    // MARK: - Response bracketing

    func test_beginEnd() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        let events = parser.feed("""
        %begin 1700000000 42 0
        %end 1700000000 42 0

        """)
        XCTAssertEqual(events, [
            .begin(time: 1700000000, number: 42, flags: 0),
            .end(time: 1700000000, number: 42, flags: 0)
        ])
    }

    func test_beginError() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        let events = parser.feed("""
        %begin 1700000000 7 1
        oops something broke
        %error 1700000000 7 1

        """)
        XCTAssertEqual(events, [
            .begin(time: 1700000000, number: 7, flags: 1),
            .responseLine("oops something broke"),
            .responseError(time: 1700000000, number: 7, flags: 1)
        ])
    }

    func test_malformedBeginProducesUnknown() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        let events = parser.feed("%begin not a number\n")
        XCTAssertEqual(events, [.unknown("not a number")])
    }

    // MARK: - Notifications

    func test_sessionsChanged() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        XCTAssertEqual(parser.feed("%sessions-changed\n"), [.sessionsChanged])
    }

    func test_sessionChanged() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        XCTAssertEqual(
            parser.feed("%session-changed $3 myses\n"),
            [.sessionChanged(sessionID: 3, name: "myses")]
        )
    }

    func test_sessionRenamed() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        XCTAssertEqual(
            parser.feed("%session-renamed $0 new-name\n"),
            [.sessionRenamed(sessionID: 0, name: "new-name")]
        )
    }

    func test_sessionWindowChanged() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        XCTAssertEqual(
            parser.feed("%session-window-changed $0 @5\n"),
            [.sessionWindowChanged(sessionID: 0, windowID: 5)]
        )
    }

    func test_windowAdd() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        XCTAssertEqual(parser.feed("%window-add @0\n"), [.windowAdd(windowID: 0)])
    }

    func test_windowClose() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        XCTAssertEqual(parser.feed("%window-close @7\n"), [.windowClose(windowID: 7)])
    }

    func test_windowRenamed() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        XCTAssertEqual(
            parser.feed("%window-renamed @0 editor\n"),
            [.windowRenamed(windowID: 0, name: "editor")]
        )
    }

    func test_windowPaneChanged() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        XCTAssertEqual(
            parser.feed("%window-pane-changed @0 %1\n"),
            [.windowPaneChanged(windowID: 0, paneID: 1)]
        )
    }

    func test_layoutChange_allFields() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        let line = "%layout-change @0 abcd,80x24,0,0 abcd,80x24,0,0 *\n"
        XCTAssertEqual(parser.feed(line), [
            .layoutChange(
                windowID: 0,
                layout: "abcd,80x24,0,0",
                visibleLayout: "abcd,80x24,0,0",
                flags: "*"
            )
        ])
    }

    func test_layoutChange_layoutOnly() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        XCTAssertEqual(
            parser.feed("%layout-change @0 abcd,80x24,0,0\n"),
            [.layoutChange(windowID: 0, layout: "abcd,80x24,0,0", visibleLayout: nil, flags: nil)]
        )
    }

    func test_paneModeChanged() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        XCTAssertEqual(
            parser.feed("%pane-mode-changed %3\n"),
            [.paneModeChanged(paneID: 3)]
        )
    }

    func test_clientSessionChanged() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        XCTAssertEqual(
            parser.feed("%client-session-changed /dev/ttys001 $0 cc-record\n"),
            [.clientSessionChanged(client: "/dev/ttys001", sessionID: 0, name: "cc-record")]
        )
    }

    func test_subscriptionChanged() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        XCTAssertEqual(
            parser.feed("%subscription-changed sub1 $0 @0 %0 0 1 value\n"),
            [.subscriptionChanged(raw: "sub1 $0 @0 %0 0 1 value")]
        )
    }

    func test_pauseAndContinue() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        let events = parser.feed("""
        %pause %2
        %continue %2

        """)
        XCTAssertEqual(events, [.pause(paneID: 2), .continuePane(paneID: 2)])
    }

    func test_exit_noReason() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        XCTAssertEqual(parser.feed("%exit\n"), [.exit(reason: nil)])
    }

    func test_exit_withReason() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        XCTAssertEqual(
            parser.feed("%exit server shutdown\n"),
            [.exit(reason: "server shutdown")]
        )
    }

    // MARK: - %output

    func test_output_plainText() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        let events = parser.feed("%output %1 hello\n")
        XCTAssertEqual(events, [.output(paneID: 1, data: Data("hello".utf8))])
    }

    func test_output_withOctalEscapes() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        // "ls\r\n" as the pane output — CR and LF get escaped to \015 and \012.
        let events = parser.feed("%output %0 ls\\015\\012\n")
        XCTAssertEqual(events, [
            .output(paneID: 0, data: Data([0x6C, 0x73, 0x0D, 0x0A]))
        ])
    }

    // MARK: - Unknown

    func test_unknownKeyword() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        let events = parser.feed("%future-feature-we-dont-know arg1 arg2\n")
        XCTAssertEqual(events, [.unknown("%future-feature-we-dont-know arg1 arg2")])
    }

    // MARK: - Incremental feed

    func test_lineSplitAcrossFeedCalls() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        XCTAssertEqual(parser.feed("%window-add"), [])
        XCTAssertEqual(parser.feed(" @4"), [])
        XCTAssertEqual(parser.feed("\n"), [.windowAdd(windowID: 4)])
    }

    func test_finishFlushesTrailingLine() {
        var parser = TmuxCCParser(expectDCSFraming: false)
        XCTAssertEqual(parser.feed("%window-add @9"), [])
        XCTAssertEqual(parser.finish(), [.windowAdd(windowID: 9)])
    }
}
