import SwiftUI
import SSHCore

/// Per-host detail screen with the action buttons (uname / shell /
/// tmux). Pushed from `HostListView`.
struct HostDetailView: View {
    let host: Host
    let store: HostStore
    let tofu: TOFUCoordinator
    let settings: SettingsStore
    let keyStore: KeyStore

    @State private var output: String = ""
    @State private var errorMessage: String?
    @State private var isRunning = false
    @State private var showingEdit = false
    @State private var confirmingDelete = false

    @Environment(\.dismiss) private var dismiss

    private var hasKey: Bool {
        host.keyID != nil || !keyStore.keys.isEmpty
    }

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Host", value: host.host)
                LabeledContent("Port", value: "\(host.port)")
                LabeledContent("User", value: host.user)
                if let kid = host.keyID,
                   let meta = keyStore.keys.first(where: { $0.id == kid })
                {
                    LabeledContent("Key", value: meta.name)
                } else if let first = keyStore.keys.first {
                    LabeledContent("Key", value: "\(first.name) (default)")
                }
            }

            Section("Actions") {
                Button {
                    Task { await runUname() }
                } label: {
                    HStack {
                        if isRunning { ProgressView() }
                        Text(isRunning ? "Connecting…" : "Run `uname -a`")
                    }
                }
                .disabled(isRunning || !hasKey)

                NavigationLink {
                    SSHBackendSessionView(host: host, tofu: tofu, settings: settings, keyStore: keyStore)
                } label: {
                    Text("Open shell")
                }
                .disabled(!hasKey)

                NavigationLink {
                    TmuxBackendSessionView(
                        host: host,
                        tofu: tofu,
                        settings: settings,
                        store: store,
                        keyStore: keyStore
                    )
                } label: {
                    Text("Open tmux")
                }
                .disabled(!hasKey)

                NavigationLink {
                    TmuxBackendSessionView(
                        host: host,
                        tofu: tofu,
                        settings: settings,
                        store: store,
                        keyStore: keyStore,
                        forceShowPicker: true
                    )
                } label: {
                    Text("List tmux sessions")
                }
                .disabled(!hasKey)
            }

            if !output.isEmpty {
                Section("Output") {
                    Text(output)
                        .font(.body.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            if !hasKey {
                Section {
                    Text("No SSH key configured. Add one in Settings → SSH keys.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete host", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .confirmationDialog(
            "Delete \(host.name)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                store.remove(id: host.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the host record only. Your SSH key and remote tmux sessions are unaffected.")
        }
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") {
                    showingEdit = true
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            NavigationStack {
                HostFormView(initial: host, keyStore: keyStore) { updated in
                    store.update(updated)
                    showingEdit = false
                } onCancel: {
                    showingEdit = false
                }
            }
        }
    }

    private func runUname() async {
        isRunning = true
        output = ""
        errorMessage = nil
        defer { isRunning = false }
        do {
            let creds = try await loadCredentials()
            let endpoint = SSHEndpoint(host: host.host, port: host.port, user: host.user)
            let verifier = KnownHostsVerifier(
                knownHostsURL: KnownHostsLocation.url,
                prompter: { [tofu] prompt in
                    await tofu.awaitDecision(for: prompt)
                }
            )
            let connection = try await SSHConnection.connect(
                endpoint: endpoint,
                credentials: creds,
                hostKeyVerifier: verifier
            )
            let result = try await connection.exec("uname -a")
            output = String(decoding: result.stdout, as: UTF8.self)
            await connection.disconnect()
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func loadCredentials() async throws -> Credentials {
        guard let id = keyStore.resolveKeyID(preferred: host.keyID) else {
            throw NoKeyError()
        }
        let (meta, data) = try await keyStore.load(
            id,
            prompt: "Authenticate to use SSH key for \(host.name)"
        )
        return KeyStore.credentials(for: meta, data: data)
    }
}

private struct NoKeyError: LocalizedError {
    var errorDescription: String? { "No SSH key configured for this host." }
}
