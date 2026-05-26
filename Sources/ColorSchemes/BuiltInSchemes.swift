import Foundation

/// Curated built-in schemes. Values are taken from each theme's canonical
/// iTerm2 preset (Solarized by Ethan Schoonover, Dracula by the Dracula
/// Theme org, Tomorrow by Chris Kempson) and stored as sRGB.
public enum BuiltInSchemes {

    public static let solarizedDark = ColorScheme(
        name: "Solarized Dark",
        ansi: [
            .hex(0x073642),  //  0  black         (base02)
            .hex(0xdc322f),  //  1  red
            .hex(0x859900),  //  2  green
            .hex(0xb58900),  //  3  yellow
            .hex(0x268bd2),  //  4  blue
            .hex(0xd33682),  //  5  magenta
            .hex(0x2aa198),  //  6  cyan
            .hex(0xeee8d5),  //  7  white         (base2)
            .hex(0x002b36),  //  8  bright black  (base03)
            .hex(0xcb4b16),  //  9  bright red    (orange)
            .hex(0x586e75),  // 10  bright green  (base01)
            .hex(0x657b83),  // 11  bright yellow (base00)
            .hex(0x839496),  // 12  bright blue   (base0)
            .hex(0x6c71c4),  // 13  bright magenta(violet)
            .hex(0x93a1a1),  // 14  bright cyan   (base1)
            .hex(0xfdf6e3),  // 15  bright white  (base3)
        ],
        foreground:   .hex(0x839496),
        background:   .hex(0x002b36),
        cursor:       .hex(0x839496),
        cursorText:   .hex(0x002b36),
        selection:    .hex(0x073642),
        selectedText: .hex(0x93a1a1),
        bold:         .hex(0x93a1a1),
        link:         nil
    )

    public static let solarizedLight = ColorScheme(
        name: "Solarized Light",
        ansi: [
            .hex(0x073642),  //  0  black
            .hex(0xdc322f),  //  1  red
            .hex(0x859900),  //  2  green
            .hex(0xb58900),  //  3  yellow
            .hex(0x268bd2),  //  4  blue
            .hex(0xd33682),  //  5  magenta
            .hex(0x2aa198),  //  6  cyan
            .hex(0xeee8d5),  //  7  white
            .hex(0x002b36),  //  8  bright black
            .hex(0xcb4b16),  //  9  bright red
            .hex(0x586e75),  // 10  bright green
            .hex(0x657b83),  // 11  bright yellow
            .hex(0x839496),  // 12  bright blue
            .hex(0x6c71c4),  // 13  bright magenta
            .hex(0x93a1a1),  // 14  bright cyan
            .hex(0xfdf6e3),  // 15  bright white
        ],
        foreground:   .hex(0x657b83),  // base00
        background:   .hex(0xfdf6e3),  // base3
        cursor:       .hex(0x657b83),
        cursorText:   .hex(0xfdf6e3),
        selection:    .hex(0xeee8d5),  // base2
        selectedText: .hex(0x586e75),  // base01
        bold:         .hex(0x586e75),
        link:         nil
    )

    public static let dracula = ColorScheme(
        name: "Dracula",
        ansi: [
            .hex(0x262626),  //  0  black
            .hex(0xff5555),  //  1  red
            .hex(0x50fa7b),  //  2  green
            .hex(0xf1fa8c),  //  3  yellow
            .hex(0xbd93f9),  //  4  blue
            .hex(0xff79c6),  //  5  magenta
            .hex(0x8be9fd),  //  6  cyan
            .hex(0xbbbbbb),  //  7  white
            .hex(0x44475a),  //  8  bright black
            .hex(0xff6e6e),  //  9  bright red
            .hex(0x69ff94),  // 10  bright green
            .hex(0xffffa5),  // 11  bright yellow
            .hex(0xd6acff),  // 12  bright blue
            .hex(0xff92df),  // 13  bright magenta
            .hex(0xa4ffff),  // 14  bright cyan
            .hex(0xffffff),  // 15  bright white
        ],
        foreground:   .hex(0xf8f8f2),
        background:   .hex(0x282a36),
        cursor:       .hex(0xf8f8f2),
        cursorText:   .hex(0x282a36),
        selection:    .hex(0x44475a),
        selectedText: .hex(0xf8f8f2),
        bold:         .hex(0xffffff),
        link:         .hex(0x8be9fd)
    )

    public static let tomorrow = ColorScheme(
        name: "Tomorrow",
        ansi: [
            .hex(0x000000),  //  0  black
            .hex(0xc82829),  //  1  red
            .hex(0x718c00),  //  2  green
            .hex(0xeab700),  //  3  yellow
            .hex(0x4271ae),  //  4  blue
            .hex(0x8959a8),  //  5  magenta
            .hex(0x3e999f),  //  6  cyan
            .hex(0xffffff),  //  7  white
            .hex(0x000000),  //  8  bright black
            .hex(0xc82829),  //  9  bright red
            .hex(0x718c00),  // 10  bright green
            .hex(0xeab700),  // 11  bright yellow
            .hex(0x4271ae),  // 12  bright blue
            .hex(0x8959a8),  // 13  bright magenta
            .hex(0x3e999f),  // 14  bright cyan
            .hex(0xffffff),  // 15  bright white
        ],
        foreground:   .hex(0x4d4d4c),
        background:   .hex(0xffffff),
        cursor:       .hex(0xaeafad),
        cursorText:   .hex(0xffffff),
        selection:    .hex(0xd6d6d6),
        selectedText: .hex(0x4d4d4c),
        bold:         nil,
        link:         nil
    )

    /// All built-in schemes in a stable order.
    public static let all: [ColorScheme] = [
        solarizedDark,
        solarizedLight,
        dracula,
        tomorrow,
    ]
}

private extension SchemeColor {
    /// Convenience constructor from a packed 24-bit sRGB hex value.
    static func hex(_ rgb: Int) -> SchemeColor {
        SchemeColor(
            red:   Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >>  8) & 0xFF) / 255.0,
            blue:  Double( rgb        & 0xFF) / 255.0,
            alpha: 1.0,
            colorSpace: .sRGB
        )
    }
}
