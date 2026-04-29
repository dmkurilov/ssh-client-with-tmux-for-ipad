import SwiftUI
import SSHCore

/// Per-host detail screen with the action buttons (uname / shell /
/// tmux). Pushed from `HostListView`.
struct HostDetailView: View {
    let host: Host
    let store: HostStore
    let tofu: TOFUCoordinator
    let settings: SettingsStore
    let keyData: Data?

    @State private var output: String = ""
    @State private var errorMessage: String?
    @State private var isRunning = false
    @State private var showingEdit = false

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Host", value: host.host)
                LabeledContent("Port", value: "\(host.port)")
                LabeledContent("User", value: host.user)
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
                .disabled(isRunning || keyData == nil)

                NavigationLink {
                    if let keyData {
                        RemoteShellView(host: host, keyData: keyData, tofu: tofu, settings: settings)
                    } else {
                        Text("No private key configured.")
                    }
                } label: {
                    Text("Open shell")
                }
                .disabled(keyData == nil)

                NavigationLink {
                    if let keyData {
                        TmuxSessionView(
                            host: host,
                            keyData: keyData,
                            tofu: tofu,
                            settings: settings,
                            store: store
                        )
                    } else {
                        Text("No private key configured.")
                    }
                } label: {
                    Text("Open tmux")
                }
                .disabled(keyData == nil)
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

            if keyData == nil {
                Section {
                    Text("Add `private-key` to `~/.ssh-client-tmux-smoke/` and rebuild to enable connections.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
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
                HostFormView(initial: host) { updated in
                    store.update(updated)
                    showingEdit = false
                } onCancel: {
                    showingEdit = false
                }
            }
        }
    }

    private func runUname() async {
        guard let keyData else { return }
        isRunning = true
        output = ""
        errorMessage = nil
        defer { isRunning = false }

        let endpoint = SSHEndpoint(host: host.host, port: host.port, user: host.user)
        let verifier = KnownHostsVerifier(
            knownHostsURL: KnownHostsLocation.url,
            prompter: { [tofu] prompt in
                await tofu.awaitDecision(for: prompt)
            }
        )
        do {
            let connection = try await SSHConnection.connect(
                endpoint: endpoint,
                credentials: .privateKey(keyData),
                hostKeyVerifier: verifier
            )
            let result = try await connection.exec("uname -a")
            output = String(decoding: result.stdout, as: UTF8.self)
            await connection.disconnect()
        } catch {
            errorMessage = "\(error)"
        }
    }
}
