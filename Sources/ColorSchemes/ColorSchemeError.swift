import Foundation

/// Reasons a `.itermcolors` file can fail to import. Every case carries
/// enough context for the error message to tell the user (a) what
/// exactly was wrong and (b) how to fix it.
public struct ColorSchemeError: LocalizedError, CustomStringConvertible, Sendable {
    public enum Kind: Equatable, Sendable {
        case notAPlist(underlying: String)
        case notADictionary
        case missingKeys([String])
        case colorNotADictionary(key: String)
        case colorMissingComponents(key: String, missing: [String])
        case colorMalformedComponent(key: String, component: String)
        case colorComponentOutOfRange(key: String, component: String, value: Double)
    }

    public let kind: Kind
    /// Optional source identifier (file path, URL, or test name) included
    /// in the formatted message to help locate the bad file.
    public let source: String?

    public init(kind: Kind, source: String? = nil) {
        self.kind = kind
        self.source = source
    }

    public var errorDescription: String? { description }

    public var description: String {
        var msg = body(for: kind)
        if let source {
            msg += "\nFile: \(source)"
        }
        return msg
    }

    private func body(for kind: Kind) -> String {
        switch kind {
        case .notAPlist(let underlying):
            return
                "This isn't a valid .itermcolors file — plist parsing failed (\(underlying)). " +
                "Export a scheme from iTerm2 via Preferences → Profiles → Colors → Color Presets → Export, " +
                "or check that the file is a well-formed XML or binary plist."

        case .notADictionary:
            return
                "The .itermcolors root must be a dictionary of color keys, but it isn't. " +
                "Re-export the scheme from iTerm2."

        case .missingKeys(let keys):
            let list = keys.joined(separator: ", ")
            return
                "Missing required color keys: \(list). " +
                "A complete .itermcolors must define all 16 ANSI colors (Ansi 0 Color … Ansi 15 Color) " +
                "plus Foreground Color, Background Color, Cursor Color, Cursor Text Color, " +
                "Selection Color, and Selected Text Color. " +
                "Open the scheme in iTerm2, assign every slot, and re-export."

        case .colorNotADictionary(let key):
            return
                "Color \"\(key)\" is not a dictionary. " +
                "Each color slot must be a dict with Red Component, Green Component, Blue Component. " +
                "Re-export from iTerm2."

        case .colorMissingComponents(let key, let missing):
            let list = missing.joined(separator: ", ")
            return
                "Color \"\(key)\" is missing components: \(list). " +
                "Every color must contain Red Component, Green Component, and Blue Component " +
                "(Alpha Component is optional and defaults to 1.0). " +
                "Re-export the scheme from iTerm2 to regenerate complete color dictionaries."

        case .colorMalformedComponent(let key, let component):
            return
                "Color \"\(key)\" has a non-numeric \(component). " +
                "Components must be real numbers between 0.0 and 1.0 " +
                "(e.g. 0.5 for mid-grey). Re-export from iTerm2, or edit the file to fix the value."

        case .colorComponentOutOfRange(let key, let component, let value):
            return
                "Color \"\(key)\" has \(component) = \(value), but components must be in range 0.0 … 1.0. " +
                "Re-export from iTerm2, or edit the value by hand to sit within that range."
        }
    }
}
