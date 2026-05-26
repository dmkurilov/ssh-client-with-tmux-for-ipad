import Foundation

/// A terminal color scheme: the 16 ANSI colors plus the UI colors a
/// terminal emulator needs (foreground, background, cursor, selection).
/// All colors are stored in their source color space — conversion (e.g.
/// to display P3 for rendering) happens in a platform layer.
public struct ColorScheme: Equatable, Sendable {
    public let name: String
    /// Always exactly 16 entries, indexed 0 … 15 (standard ANSI).
    public let ansi: [SchemeColor]
    public let foreground: SchemeColor
    public let background: SchemeColor
    public let cursor: SchemeColor
    public let cursorText: SchemeColor
    public let selection: SchemeColor
    public let selectedText: SchemeColor
    public let bold: SchemeColor?
    public let link: SchemeColor?

    public init(
        name: String,
        ansi: [SchemeColor],
        foreground: SchemeColor,
        background: SchemeColor,
        cursor: SchemeColor,
        cursorText: SchemeColor,
        selection: SchemeColor,
        selectedText: SchemeColor,
        bold: SchemeColor? = nil,
        link: SchemeColor? = nil
    ) {
        self.name = name
        self.ansi = ansi
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.cursorText = cursorText
        self.selection = selection
        self.selectedText = selectedText
        self.bold = bold
        self.link = link
    }
}

public struct SchemeColor: Equatable, Sendable {
    public let red: Double     // 0.0 … 1.0
    public let green: Double   // 0.0 … 1.0
    public let blue: Double    // 0.0 … 1.0
    public let alpha: Double   // 0.0 … 1.0
    public let colorSpace: SchemeColorSpace

    public init(
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double = 1.0,
        colorSpace: SchemeColorSpace = .sRGB
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.colorSpace = colorSpace
    }
}

/// Color-space tag carried through from the source file. The importer
/// does not convert; consumers decide how to interpret (typically via
/// UIColor / CGColor APIs on the client).
public enum SchemeColorSpace: Equatable, Sendable {
    case sRGB
    case calibratedRGB
    case genericRGB
    case displayP3
    case other(String)

    public init(rawValue: String?) {
        switch rawValue {
        case nil, "", "sRGB", "kCGColorSpaceSRGB":
            self = .sRGB
        case "Calibrated", "NSCalibratedRGBColorSpace":
            self = .calibratedRGB
        case "Generic RGB", "NSDeviceRGBColorSpace", "kCGColorSpaceGenericRGB":
            self = .genericRGB
        case "P3", "Display P3", "kCGColorSpaceDisplayP3":
            self = .displayP3
        case let other?:
            self = .other(other)
        }
    }
}
