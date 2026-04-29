import SwiftUI
import ColorSchemes

/// App-wide settings sheet. Currently just a color-scheme picker —
/// will grow as we add hotkeys, transcripts, etc.
struct SettingsSheet: View {
    @Bindable var settings: SettingsStore
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Color scheme") {
                    Picker("Scheme", selection: schemeBinding) {
                        ForEach(BuiltInSchemes.all, id: \.name) { scheme in
                            Text(scheme.name).tag(scheme.name)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }

    private var schemeBinding: Binding<String> {
        Binding(
            get: { settings.selectedScheme.name },
            set: { newName in
                if let next = BuiltInSchemes.all.first(where: { $0.name == newName }) {
                    settings.selectedScheme = next
                }
            }
        )
    }
}
