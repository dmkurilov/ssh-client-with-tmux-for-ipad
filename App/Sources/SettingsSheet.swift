import SwiftUI
import ColorSchemes

/// App-wide settings sheet. Currently just a color-scheme picker —
/// will grow as we add hotkeys, transcripts, etc.
struct SettingsSheet: View {
    @Bindable var settings: SettingsStore
    let keyStore: KeyStore
    let onDone: () -> Void

    @State private var addingKey = false
    @Bindable private var transcripts = TranscriptStore.shared

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

                Section {
                    if keyStore.keys.isEmpty {
                        Text("No keys yet. Tap + to add one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(keyStore.keys) { key in
                            keyRow(key)
                        }
                        .onDelete { offsets in
                            for idx in offsets {
                                try? keyStore.remove(keyStore.keys[idx].id)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("SSH keys")
                        Spacer()
                        Button {
                            addingKey = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }

                Section {
                    Toggle("Record transcripts", isOn: $transcripts.enabled)
                    NavigationLink {
                        TranscriptListView(store: transcripts)
                    } label: {
                        Label("Browse transcripts", systemImage: "doc.text")
                    }
                } header: {
                    Text("Transcripts")
                } footer: {
                    Text("Off by default. When enabled, raw pane output is appended to `Documents/transcripts/` per pane. Files contain ANSI escape sequences — terminal output may include secrets.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
            .sheet(isPresented: $addingKey) {
                KeyFormView(store: keyStore) { addingKey = false }
            }
        }
    }

    private func keyRow(_ key: KeyMetadata) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(key.name)
                    .font(.body.weight(.medium))
                Spacer()
                Text(key.format == .ed25519Raw ? "ed25519" : "OpenSSH PEM")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let pub = key.publicKeyOpenSSH {
                Text(pub)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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
