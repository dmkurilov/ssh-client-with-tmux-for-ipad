import XCTest
@testable import TmuxCC

final class TmuxLayoutTests: XCTestCase {

    func test_singlePane() throws {
        let l = try TmuxLayout.parse("abc1,80x24,0,0,0")
        XCTAssertEqual(l.cols, 80)
        XCTAssertEqual(l.rows, 24)
        XCTAssertEqual(l.x, 0)
        XCTAssertEqual(l.y, 0)
        XCTAssertEqual(l.node, .leaf(paneID: 0))
        XCTAssertEqual(l.paneIDs, [0])
    }

    func test_horizontalSplit() throws {
        let l = try TmuxLayout.parse("abc1,80x24,0,0{40x24,0,0,1,40x24,40,0,2}")
        guard case .horizontal(let kids) = l.node else {
            XCTFail("expected horizontal split, got \(l.node)")
            return
        }
        XCTAssertEqual(kids.count, 2)
        XCTAssertEqual(kids[0].cols, 40)
        XCTAssertEqual(kids[0].x, 0)
        XCTAssertEqual(kids[0].node, .leaf(paneID: 1))
        XCTAssertEqual(kids[1].cols, 40)
        XCTAssertEqual(kids[1].x, 40)
        XCTAssertEqual(kids[1].node, .leaf(paneID: 2))
        XCTAssertEqual(l.paneIDs, [1, 2])
    }

    func test_verticalSplit() throws {
        let l = try TmuxLayout.parse("abc1,80x24,0,0[80x12,0,0,3,80x12,0,12,4]")
        guard case .vertical(let kids) = l.node else {
            XCTFail("expected vertical split, got \(l.node)")
            return
        }
        XCTAssertEqual(kids.count, 2)
        XCTAssertEqual(kids[0].rows, 12)
        XCTAssertEqual(kids[0].node, .leaf(paneID: 3))
        XCTAssertEqual(kids[1].rows, 12)
        XCTAssertEqual(kids[1].y, 12)
        XCTAssertEqual(kids[1].node, .leaf(paneID: 4))
        XCTAssertEqual(l.paneIDs, [3, 4])
    }

    func test_nestedSplit_horizontalContainingVertical() throws {
        // Left pane (40x24) and right column split into top/bottom.
        let s = "abc1,80x24,0,0{40x24,0,0,1,40x24,40,0[40x12,40,0,2,40x12,40,12,3]}"
        let l = try TmuxLayout.parse(s)
        guard case .horizontal(let kids) = l.node else {
            return XCTFail("expected horizontal root")
        }
        XCTAssertEqual(kids.count, 2)
        XCTAssertEqual(kids[0].node, .leaf(paneID: 1))
        guard case .vertical(let inner) = kids[1].node else {
            return XCTFail("expected vertical inner, got \(kids[1].node)")
        }
        XCTAssertEqual(inner.map(\.node), [.leaf(paneID: 2), .leaf(paneID: 3)])
        XCTAssertEqual(l.paneIDs, [1, 2, 3])
    }

    func test_threeWaySplit() throws {
        // tmux flattens 3 side-by-side panes into one `{}` list.
        let s = "abc1,90x24,0,0{30x24,0,0,1,30x24,30,0,2,30x24,60,0,3}"
        let l = try TmuxLayout.parse(s)
        guard case .horizontal(let kids) = l.node else {
            return XCTFail("expected horizontal split")
        }
        XCTAssertEqual(kids.map(\.node), [.leaf(paneID: 1), .leaf(paneID: 2), .leaf(paneID: 3)])
    }

    func test_emptyStringRejected() {
        XCTAssertThrowsError(try TmuxLayout.parse("")) { err in
            XCTAssertEqual(err as? TmuxLayout.ParseError, .empty)
        }
    }

    func test_missingChecksumCommaRejected() {
        XCTAssertThrowsError(try TmuxLayout.parse("abc180x24")) { err in
            XCTAssertEqual(err as? TmuxLayout.ParseError, .missingChecksumComma)
        }
    }

    func test_garbageAfterDimensionsRejected() {
        XCTAssertThrowsError(try TmuxLayout.parse("abc1,80x24,0,0?"))
    }
}
