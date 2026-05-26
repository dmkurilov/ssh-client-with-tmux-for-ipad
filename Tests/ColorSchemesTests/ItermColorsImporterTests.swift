import XCTest
@testable import ColorSchemes

final class ItermColorsImporterTests: XCTestCase {

    // MARK: - Happy path

    func test_fullyValidScheme_parses() throws {
        let data = try serialize(makeFullyValidSchemeDict())
        let scheme = try ItermColorsImporter.parse(data, name: "Test")

        XCTAssertEqual(scheme.name, "Test")
        XCTAssertEqual(scheme.ansi.count, 16)
        XCTAssertEqual(scheme.foreground.red, 1.0)
        XCTAssertEqual(scheme.background.red, 0.0)
        XCTAssertEqual(scheme.cursor.red, 1.0)
        XCTAssertEqual(scheme.selection.red, 0.5)
    }

    func test_ansiIndexing() throws {
        var dict = makeFullyValidSchemeDict()
        dict["Ansi 5 Color"] = color(r: 0.25, g: 0.5, b: 0.75)

        let data = try serialize(dict)
        let scheme = try ItermColorsImporter.parse(data, name: "t")

        XCTAssertEqual(scheme.ansi[5].red,   0.25)
        XCTAssertEqual(scheme.ansi[5].green, 0.5)
        XCTAssertEqual(scheme.ansi[5].blue,  0.75)
    }

    func test_alphaDefaultsToOneWhenOmitted() throws {
        var dict = makeFullyValidSchemeDict()
        dict["Foreground Color"] = [
            "Red Component":   Double(0.1),
            "Green Component": Double(0.2),
            "Blue Component":  Double(0.3),
            "Color Space":     "sRGB",
        ]
        let data = try serialize(dict)
        let scheme = try ItermColorsImporter.parse(data, name: "t")

        XCTAssertEqual(scheme.foreground.alpha, 1.0)
    }

    func test_boldAndLinkAreOptional() throws {
        let data = try serialize(makeFullyValidSchemeDict())
        let scheme = try ItermColorsImporter.parse(data, name: "t")
        XCTAssertNil(scheme.bold)
        XCTAssertNil(scheme.link)
    }

    func test_boldAndLinkWhenPresent() throws {
        var dict = makeFullyValidSchemeDict()
        dict["Bold Color"] = color(r: 0.9, g: 0.9, b: 0.9)
        dict["Link Color"] = color(r: 0,   g: 0,   b: 1)

        let data = try serialize(dict)
        let scheme = try ItermColorsImporter.parse(data, name: "t")

        XCTAssertNotNil(scheme.bold)
        XCTAssertEqual(scheme.bold?.red, 0.9)
        XCTAssertEqual(scheme.link?.blue, 1.0)
    }

    // MARK: - Color space mapping

    func test_colorSpace_sRGB() throws {
        var dict = makeFullyValidSchemeDict()
        dict["Foreground Color"] = color(r: 1, g: 1, b: 1, space: "sRGB")
        let data = try serialize(dict)
        let scheme = try ItermColorsImporter.parse(data, name: "t")
        XCTAssertEqual(scheme.foreground.colorSpace, .sRGB)
    }

    func test_colorSpace_calibratedRGB() throws {
        var dict = makeFullyValidSchemeDict()
        dict["Foreground Color"] = color(r: 1, g: 1, b: 1, space: "Calibrated")
        let data = try serialize(dict)
        let scheme = try ItermColorsImporter.parse(data, name: "t")
        XCTAssertEqual(scheme.foreground.colorSpace, .calibratedRGB)
    }

    func test_colorSpace_displayP3() throws {
        var dict = makeFullyValidSchemeDict()
        dict["Foreground Color"] = color(r: 1, g: 1, b: 1, space: "Display P3")
        let data = try serialize(dict)
        let scheme = try ItermColorsImporter.parse(data, name: "t")
        XCTAssertEqual(scheme.foreground.colorSpace, .displayP3)
    }

    func test_colorSpace_unknown_preservedAsOther() throws {
        var dict = makeFullyValidSchemeDict()
        dict["Foreground Color"] = color(r: 1, g: 1, b: 1, space: "LabColorSpace")
        let data = try serialize(dict)
        let scheme = try ItermColorsImporter.parse(data, name: "t")
        XCTAssertEqual(scheme.foreground.colorSpace, .other("LabColorSpace"))
    }

    func test_colorSpace_missing_defaultsToSRGB() throws {
        var dict = makeFullyValidSchemeDict()
        dict["Foreground Color"] = color(r: 1, g: 1, b: 1, space: nil)
        let data = try serialize(dict)
        let scheme = try ItermColorsImporter.parse(data, name: "t")
        XCTAssertEqual(scheme.foreground.colorSpace, .sRGB)
    }

    // MARK: - Error paths

    func test_notAPlist() {
        let garbage = Data("not a plist at all".utf8)
        XCTAssertThrowsError(try ItermColorsImporter.parse(garbage, name: "t")) { error in
            guard case .notAPlist = (error as? ColorSchemeError)?.kind else {
                return XCTFail("expected .notAPlist, got \(error)")
            }
        }
    }

    func test_notADictionary() throws {
        // A plist that serializes as an array, not a dict.
        let data = try PropertyListSerialization.data(
            fromPropertyList: [1, 2, 3] as [Any],
            format: .xml,
            options: 0
        )
        XCTAssertThrowsError(try ItermColorsImporter.parse(data, name: "t")) { error in
            guard case .notADictionary = (error as? ColorSchemeError)?.kind else {
                return XCTFail("expected .notADictionary, got \(error)")
            }
        }
    }

    func test_missingKeys_reportsAllMissing() throws {
        var dict = makeFullyValidSchemeDict()
        dict["Ansi 5 Color"]      = nil
        dict["Foreground Color"]  = nil
        dict["Selection Color"]   = nil

        let data = try serialize(dict)
        XCTAssertThrowsError(try ItermColorsImporter.parse(data, name: "t")) { error in
            guard case .missingKeys(let keys) = (error as? ColorSchemeError)?.kind else {
                return XCTFail("expected .missingKeys, got \(error)")
            }
            XCTAssertEqual(
                Set(keys),
                Set(["Ansi 5 Color", "Foreground Color", "Selection Color"])
            )
        }
    }

    func test_colorNotADictionary() throws {
        var dict = makeFullyValidSchemeDict()
        dict["Background Color"] = "not a dict"
        let data = try serialize(dict)
        XCTAssertThrowsError(try ItermColorsImporter.parse(data, name: "t")) { error in
            guard case .colorNotADictionary(let key) = (error as? ColorSchemeError)?.kind,
                  key == "Background Color"
            else { return XCTFail("expected .colorNotADictionary(Background Color), got \(error)") }
        }
    }

    func test_missingComponents() throws {
        var dict = makeFullyValidSchemeDict()
        dict["Background Color"] = [
            "Red Component": 0.5,
            "Color Space":   "sRGB",
        ] as [String: Any]

        let data = try serialize(dict)
        XCTAssertThrowsError(try ItermColorsImporter.parse(data, name: "t")) { error in
            guard case .colorMissingComponents(let key, let missing) = (error as? ColorSchemeError)?.kind,
                  key == "Background Color"
            else { return XCTFail("expected .colorMissingComponents, got \(error)") }
            XCTAssertEqual(Set(missing), Set(["Green Component", "Blue Component"]))
        }
    }

    func test_malformedComponent_nonNumeric() throws {
        var dict = makeFullyValidSchemeDict()
        dict["Foreground Color"] = [
            "Red Component":   "not a number",
            "Green Component": 0.5,
            "Blue Component":  0.5,
        ] as [String: Any]

        let data = try serialize(dict)
        XCTAssertThrowsError(try ItermColorsImporter.parse(data, name: "t")) { error in
            guard case .colorMalformedComponent(let key, let component) = (error as? ColorSchemeError)?.kind,
                  key == "Foreground Color",
                  component == "Red Component"
            else { return XCTFail("expected .colorMalformedComponent, got \(error)") }
        }
    }

    func test_componentOutOfRange_tooHigh() throws {
        var dict = makeFullyValidSchemeDict()
        dict["Cursor Color"] = color(r: 1.5, g: 0.5, b: 0.5)
        let data = try serialize(dict)
        XCTAssertThrowsError(try ItermColorsImporter.parse(data, name: "t")) { error in
            guard case .colorComponentOutOfRange(let key, let component, let value) = (error as? ColorSchemeError)?.kind
            else { return XCTFail("expected .colorComponentOutOfRange, got \(error)") }
            XCTAssertEqual(key, "Cursor Color")
            XCTAssertEqual(component, "Red Component")
            XCTAssertEqual(value, 1.5)
        }
    }

    func test_componentOutOfRange_negative() throws {
        var dict = makeFullyValidSchemeDict()
        dict["Cursor Color"] = color(r: -0.1, g: 0.5, b: 0.5)
        let data = try serialize(dict)
        XCTAssertThrowsError(try ItermColorsImporter.parse(data, name: "t"))
    }

    // MARK: - Error messages include fix guidance

    func test_errorMessageMentionsReExport() {
        let err = ColorSchemeError(
            kind: .missingKeys(["Ansi 5 Color"]),
            source: "/tmp/example.itermcolors"
        )
        let msg = err.description
        XCTAssertTrue(msg.contains("Ansi 5 Color"))
        XCTAssertTrue(msg.contains("iTerm2"))
        XCTAssertTrue(msg.contains("/tmp/example.itermcolors"))
    }

    func test_errorMessageMentionsRange() {
        let err = ColorSchemeError(
            kind: .colorComponentOutOfRange(key: "Foreground Color", component: "Red Component", value: 1.7)
        )
        let msg = err.description
        XCTAssertTrue(msg.contains("Foreground Color"))
        XCTAssertTrue(msg.contains("Red Component"))
        XCTAssertTrue(msg.contains("1.7"))
        XCTAssertTrue(msg.contains("0.0"))
    }
}
