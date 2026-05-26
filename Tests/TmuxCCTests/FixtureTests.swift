import XCTest
@testable import TmuxCC

/// End-to-end: feed a real captured `-CC` session through the parser
/// and assert the full event sequence.
final class FixtureTests: XCTestCase {

    func test_session01_producesExpectedEventSequence() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "session-01",
                withExtension: "cc-log",
                subdirectory: "Fixtures"
            ),
            "session-01.cc-log fixture missing from bundle"
        )
        let data = try Data(contentsOf: url)

        var parser = TmuxCCParser(expectDCSFraming: false)
        var events = parser.feed(data)
        events.append(contentsOf: parser.finish())

        XCTAssertEqual(events, [
            .begin(time: 1776537123, number: 271, flags: 0),
            .end(time: 1776537123, number: 271, flags: 0),
            .windowAdd(windowID: 0),
            .sessionsChanged,
            .sessionChanged(sessionID: 0, name: "cc-record"),
            .begin(time: 1776537123, number: 277, flags: 1),
            .responseLine("parse error: unknown command: new-window"),
            .responseError(time: 1776537123, number: 277, flags: 1),
            .begin(time: 1776537123, number: 278, flags: 1),
            .end(time: 1776537123, number: 278, flags: 1),
            .begin(time: 1776537123, number: 279, flags: 1),
            .end(time: 1776537123, number: 279, flags: 1),
            .begin(time: 1776537123, number: 280, flags: 1),
            .end(time: 1776537123, number: 280, flags: 1),
            .windowPaneChanged(windowID: 0, paneID: 1),
            .layoutChange(
                windowID: 0,
                layout: "8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}",
                visibleLayout: "8205,80x24,0,0{40x24,0,0,0,39x24,41,0,1}",
                flags: "*"
            ),
            .sessionsChanged,
            .exit(reason: nil),
        ])
    }
}
