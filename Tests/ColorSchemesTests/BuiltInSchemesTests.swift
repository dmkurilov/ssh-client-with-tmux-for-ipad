import XCTest
@testable import ColorSchemes

final class BuiltInSchemesTests: XCTestCase {

    func test_allSchemesHaveCompleteShape() {
        for scheme in BuiltInSchemes.all {
            XCTAssertFalse(scheme.name.isEmpty, "scheme missing name")
            XCTAssertEqual(scheme.ansi.count, 16, "scheme \(scheme.name) does not have 16 ANSI colors")
        }
    }

    func test_allSchemesHaveDistinctNames() {
        let names = BuiltInSchemes.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "duplicate scheme names: \(names)")
    }

    func test_allComponentsInRange() {
        for scheme in BuiltInSchemes.all {
            let all: [SchemeColor] = scheme.ansi + [
                scheme.foreground,
                scheme.background,
                scheme.cursor,
                scheme.cursorText,
                scheme.selection,
                scheme.selectedText,
            ] + [scheme.bold, scheme.link].compactMap { $0 }

            for color in all {
                assertInRange(color.red,   in: scheme.name)
                assertInRange(color.green, in: scheme.name)
                assertInRange(color.blue,  in: scheme.name)
                assertInRange(color.alpha, in: scheme.name)
            }
        }
    }

    func test_solarizedDark_base03Background() {
        // base03 = #002b36 → (0, 43/255, 54/255)
        let bg = BuiltInSchemes.solarizedDark.background
        XCTAssertEqual(bg.red,   0.0,         accuracy: 0.005)
        XCTAssertEqual(bg.green, 43.0 / 255,  accuracy: 0.005)
        XCTAssertEqual(bg.blue,  54.0 / 255,  accuracy: 0.005)
    }

    func test_solarizedLight_base3Background() {
        // base3 = #fdf6e3
        let bg = BuiltInSchemes.solarizedLight.background
        XCTAssertEqual(bg.red,   253.0 / 255, accuracy: 0.005)
        XCTAssertEqual(bg.green, 246.0 / 255, accuracy: 0.005)
        XCTAssertEqual(bg.blue,  227.0 / 255, accuracy: 0.005)
    }

    func test_dracula_background() {
        // #282a36
        let bg = BuiltInSchemes.dracula.background
        XCTAssertEqual(bg.red,   40.0 / 255, accuracy: 0.005)
        XCTAssertEqual(bg.green, 42.0 / 255, accuracy: 0.005)
        XCTAssertEqual(bg.blue,  54.0 / 255, accuracy: 0.005)
    }

    func test_tomorrow_whiteBackground() {
        let bg = BuiltInSchemes.tomorrow.background
        XCTAssertEqual(bg.red,   1.0, accuracy: 0.001)
        XCTAssertEqual(bg.green, 1.0, accuracy: 0.001)
        XCTAssertEqual(bg.blue,  1.0, accuracy: 0.001)
    }

    func test_allSchemesDeclaredInAll() {
        // Guard against someone adding a scheme but forgetting to list it.
        XCTAssertTrue(BuiltInSchemes.all.contains(BuiltInSchemes.solarizedDark))
        XCTAssertTrue(BuiltInSchemes.all.contains(BuiltInSchemes.solarizedLight))
        XCTAssertTrue(BuiltInSchemes.all.contains(BuiltInSchemes.dracula))
        XCTAssertTrue(BuiltInSchemes.all.contains(BuiltInSchemes.tomorrow))
    }

    private func assertInRange(_ v: Double, in scheme: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(v >= 0 && v <= 1, "\(scheme): component \(v) outside [0,1]", file: file, line: line)
    }
}
