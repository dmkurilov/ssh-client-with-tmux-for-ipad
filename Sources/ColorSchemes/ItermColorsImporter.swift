import Foundation

/// Parses iTerm2 `.itermcolors` plist files into `ColorScheme` values.
///
/// The importer is strict: any missing required color, missing RGB
/// component, or component outside 0.0 … 1.0 throws a
/// `ColorSchemeError` with a message telling the caller what's wrong
/// and how to fix it. Consumers get the benefit of failing loudly on
/// malformed schemes instead of silently substituting defaults.
public enum ItermColorsImporter {

    /// Parse an `.itermcolors` file from in-memory bytes.
    /// - Parameter name: Display name for the resulting scheme.
    /// - Parameter source: Optional path/URL for error messages.
    public static func parse(
        _ data: Data,
        name: String,
        source: String? = nil
    ) throws -> ColorScheme {
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw ColorSchemeError(
                kind: .notAPlist(underlying: error.localizedDescription),
                source: source
            )
        }
        guard let dict = plist as? [String: Any] else {
            throw ColorSchemeError(kind: .notADictionary, source: source)
        }
        return try parseDictionary(dict, name: name, source: source)
    }

    /// Parse an `.itermcolors` file at a URL. If `name` is nil, the file's
    /// basename (minus the extension) is used.
    public static func parse(
        contentsOf url: URL,
        name: String? = nil
    ) throws -> ColorScheme {
        let data = try Data(contentsOf: url)
        return try parse(
            data,
            name: name ?? url.deletingPathExtension().lastPathComponent,
            source: url.path
        )
    }

    // MARK: - Private

    private static let ansiKeys: [String] = (0...15).map { "Ansi \($0) Color" }

    private static let requiredUIKeys: [String] = [
        "Foreground Color",
        "Background Color",
        "Cursor Color",
        "Cursor Text Color",
        "Selection Color",
        "Selected Text Color",
    ]

    private static func parseDictionary(
        _ dict: [String: Any],
        name: String,
        source: String?
    ) throws -> ColorScheme {
        let required = ansiKeys + requiredUIKeys
        let missing = required.filter { dict[$0] == nil }
        guard missing.isEmpty else {
            throw ColorSchemeError(kind: .missingKeys(missing), source: source)
        }

        var ansi: [SchemeColor] = []
        ansi.reserveCapacity(16)
        for key in ansiKeys {
            ansi.append(try parseColor(dict[key], key: key, source: source))
        }

        return ColorScheme(
            name: name,
            ansi: ansi,
            foreground:   try parseColor(dict["Foreground Color"],    key: "Foreground Color",    source: source),
            background:   try parseColor(dict["Background Color"],    key: "Background Color",    source: source),
            cursor:       try parseColor(dict["Cursor Color"],        key: "Cursor Color",        source: source),
            cursorText:   try parseColor(dict["Cursor Text Color"],   key: "Cursor Text Color",   source: source),
            selection:    try parseColor(dict["Selection Color"],     key: "Selection Color",     source: source),
            selectedText: try parseColor(dict["Selected Text Color"], key: "Selected Text Color", source: source),
            bold:         try parseOptionalColor(dict["Bold Color"],  key: "Bold Color",          source: source),
            link:         try parseOptionalColor(dict["Link Color"],  key: "Link Color",          source: source)
        )
    }

    private static func parseOptionalColor(
        _ value: Any?,
        key: String,
        source: String?
    ) throws -> SchemeColor? {
        guard value != nil else { return nil }
        return try parseColor(value, key: key, source: source)
    }

    private static func parseColor(
        _ value: Any?,
        key: String,
        source: String?
    ) throws -> SchemeColor {
        guard let colorDict = value as? [String: Any] else {
            throw ColorSchemeError(kind: .colorNotADictionary(key: key), source: source)
        }

        let required = ["Red Component", "Green Component", "Blue Component"]
        let missing = required.filter { colorDict[$0] == nil }
        guard missing.isEmpty else {
            throw ColorSchemeError(
                kind: .colorMissingComponents(key: key, missing: missing),
                source: source
            )
        }

        let red   = try requireComponent(colorDict["Red Component"],   key: key, component: "Red Component",   source: source)
        let green = try requireComponent(colorDict["Green Component"], key: key, component: "Green Component", source: source)
        let blue  = try requireComponent(colorDict["Blue Component"],  key: key, component: "Blue Component",  source: source)
        let alpha = try optionalComponent(colorDict["Alpha Component"], key: key, component: "Alpha Component", source: source) ?? 1.0

        let space = SchemeColorSpace(rawValue: colorDict["Color Space"] as? String)
        return SchemeColor(red: red, green: green, blue: blue, alpha: alpha, colorSpace: space)
    }

    private static func requireComponent(
        _ value: Any?,
        key: String,
        component: String,
        source: String?
    ) throws -> Double {
        guard let d = toDouble(value) else {
            throw ColorSchemeError(
                kind: .colorMalformedComponent(key: key, component: component),
                source: source
            )
        }
        if d < 0 || d > 1 {
            throw ColorSchemeError(
                kind: .colorComponentOutOfRange(key: key, component: component, value: d),
                source: source
            )
        }
        return d
    }

    private static func optionalComponent(
        _ value: Any?,
        key: String,
        component: String,
        source: String?
    ) throws -> Double? {
        guard value != nil else { return nil }
        return try requireComponent(value, key: key, component: component, source: source)
    }

    private static func toDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}
