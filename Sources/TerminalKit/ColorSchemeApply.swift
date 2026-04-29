#if canImport(UIKit)
import UIKit
import SwiftTerm
import ColorSchemes

/// Apply a `ColorSchemes.ColorScheme` to a `SwiftTerm.TerminalView`.
///
/// - Installs the 16 ANSI colors via the underlying `Terminal`
///   (SwiftTerm splits its color model: 16-color palette is
///   `Terminal`-level state; UI colors like fg/bg/cursor/selection
///   live on `TerminalView`).
/// - Sets foreground/background/cursor/selection on the view.
///
/// Color spaces from `.itermcolors` are ignored at this layer — we
/// hand the raw RGB to UIKit/SwiftTerm and let them treat it as sRGB.
/// Good enough for v1; a colour-managed path can come later.
enum ColorSchemeApply {

    static func apply(_ scheme: ColorScheme, to view: SwiftTerm.TerminalView) {
        let ansi = scheme.ansi.map(swiftTermColor)
        view.installColors(ansi)

        view.nativeForegroundColor = uiColor(scheme.foreground)
        view.nativeBackgroundColor = uiColor(scheme.background)
        view.caretColor = uiColor(scheme.cursor)
        view.selectedTextBackgroundColor = uiColor(scheme.selection)
    }

    private static func swiftTermColor(_ c: SchemeColor) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red:   UInt16(clamping: Int(c.red   * 65535.0)),
            green: UInt16(clamping: Int(c.green * 65535.0)),
            blue:  UInt16(clamping: Int(c.blue  * 65535.0))
        )
    }

    private static func uiColor(_ c: SchemeColor) -> UIColor {
        UIColor(
            red: CGFloat(c.red),
            green: CGFloat(c.green),
            blue: CGFloat(c.blue),
            alpha: CGFloat(c.alpha)
        )
    }
}
#endif
