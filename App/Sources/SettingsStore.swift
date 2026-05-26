import Foundation
import Observation
import ColorSchemes

/// Persisted user preferences. Backed by `UserDefaults`; one global
/// color scheme for now (per-host overrides can come later).
@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults
    private static let schemeNameKey = "selectedColorSchemeName"

    var selectedScheme: ColorScheme {
        didSet {
            defaults.set(selectedScheme.name, forKey: Self.schemeNameKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.schemeNameKey)
        self.selectedScheme = BuiltInSchemes.all.first { $0.name == stored }
            ?? BuiltInSchemes.solarizedDark
    }
}
