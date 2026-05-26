import Foundation
@testable import ColorSchemes

/// Build a fully-valid itermcolors plist dict. Callers mutate the
/// result (remove keys, override colors) to produce malformed variants
/// for error-path tests.
func makeFullyValidSchemeDict() -> [String: Any] {
    var dict: [String: Any] = [:]
    for i in 0...15 {
        let shade = Double(i) / 15.0
        dict["Ansi \(i) Color"] = color(r: shade, g: shade, b: shade)
    }
    dict["Foreground Color"]    = color(r: 1,   g: 1,   b: 1)
    dict["Background Color"]    = color(r: 0,   g: 0,   b: 0)
    dict["Cursor Color"]        = color(r: 1,   g: 0.5, b: 0)
    dict["Cursor Text Color"]   = color(r: 0,   g: 0,   b: 0)
    dict["Selection Color"]     = color(r: 0.5, g: 0.5, b: 0.5)
    dict["Selected Text Color"] = color(r: 1,   g: 1,   b: 1)
    return dict
}

func color(
    r: Double,
    g: Double,
    b: Double,
    a: Double = 1.0,
    space: String? = "sRGB"
) -> [String: Any] {
    var d: [String: Any] = [
        "Red Component":   r,
        "Green Component": g,
        "Blue Component":  b,
        "Alpha Component": a,
    ]
    if let space { d["Color Space"] = space }
    return d
}

func serialize(_ dict: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
}
