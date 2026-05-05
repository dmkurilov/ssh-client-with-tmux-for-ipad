import SwiftUI
import ColorSchemes

/// App-wide settings sheet. Currently just a color-scheme picker —
/// will grow as we add hotkeys, transcripts, etc.
struct SettingsSheet: View {
    @Bindable var settings: SettingsStore
    let keyStore: KeyStore
    let onDone: () -> Void

    @State private var addingKey = false
    @State private var showingDemo = false
    @Bindable private var transcripts = TranscriptStore.shared
    @Bindable private var fileLogger = FileLogger.shared
    @Bindable private var consent = RecordingConsent.shared

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
                    Toggle("Write debug log", isOn: $fileLogger.enabled)
                    if fileLogger.enabled, let granted = consent.grantedAt {
                        consentCountdown(since: granted)
                    }
                    NavigationLink {
                        DebugLogDetailView(fileLogger: fileLogger)
                    } label: {
                        Label("Browse debug log", systemImage: "doc.text")
                    }
                    #if DEBUG
                    // Full-screen cover (rather than a NavigationLink)
                    // so the demo terminal isn't constrained by the
                    // Settings sheet's form-sheet size on iPad — the
                    // pane area gets the whole device.
                    Button {
                        showingDemo = true
                    } label: {
                        Label("Open demo terminal", systemImage: "rectangle.dashed")
                    }
                    #endif
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Off by default. When enabled, every parsed tmux event and outgoing command is appended to `Documents/debug.log`. Useful when reproducing a bug.")
                }

                Section {
                    Toggle("Record transcripts", isOn: $transcripts.enabled)
                    if transcripts.enabled, let granted = consent.grantedAt {
                        consentCountdown(since: granted)
                    }
                    NavigationLink {
                        TranscriptListView(store: transcripts)
                    } label: {
                        Label("Browse transcripts", systemImage: "doc.text")
                    }
                } header: {
                    Text("Transcripts")
                } footer: {
                    Text("Off by default. When enabled, raw pane output is appended to `Documents/transcripts/` per pane. Files contain ANSI escape sequences — terminal output may include secrets. Shares the consent timer with the debug log.")
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
            .sheet(isPresented: $consent.pendingPrompt) {
                LongRunningRecordingSheet {
                    consent.pendingPrompt = false
                }
            }
            #if DEBUG
            .fullScreenCover(isPresented: $showingDemo) {
                DemoSessionView(
                    backend: FakeSessionBackend(echoDelay: .seconds(1), paneCount: 2),
                    scheme: settings.selectedScheme
                )
            }
            #endif
        }
    }

    /// Live countdown that ticks every second. When it hits zero the
    /// foreground poll in `ContentView` raises the re-consent sheet.
    private func consentCountdown(since: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = LongRunningRecordingSheet.staleAfter
                - context.date.timeIntervalSince(since)
            if remaining <= 0 {
                Text("Consent is expired")
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
            } else {
                Text("Consent expires in \(formatExpiry(remaining))")
                    .font(.caption.monospaced())
                    .foregroundStyle(remaining < 60 ? .orange : .secondary)
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
