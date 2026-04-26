import SwiftUI
import ColorSchemes
import SSHCore

struct ContentView: View {
    @State private var output: String = ""
    @State private var errorMessage: String?
    @State private var isRunning: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("SSH Client + Tmux")
                    .font(.largeTitle.weight(.semibold))

                smokeTestPanel

                Spacer()

                VStack(spacing: 4) {
                    Text("Bundled color schemes: \(BuiltInSchemes.all.count)")
                    Text("Smoke test config: \(SmokeTestConfig.isReady ? "ready" : "missing")")
                }
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            }
            .padding()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var smokeTestPanel: some View {
        if let config = SmokeTestConfig.shared, let keyData = SmokeTestConfig.privateKeyData {
            VStack(spacing: 12) {
                Button {
                    Task { await runSmokeTest(config: config, keyData: keyData) }
                } label: {
                    HStack {
                        if isRunning { ProgressView() }
                        Text(isRunning ? "Connecting…" : "Run `uname -a` on \(config.host)")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)

                NavigationLink {
                    RemoteShellView(config: config, keyData: keyData)
                } label: {
                    Text("Open shell on \(config.host)")
                }
                .buttonStyle(.bordered)

                NavigationLink {
                    TmuxSessionView(config: config, keyData: keyData)
                } label: {
                    Text("Open tmux on \(config.host)")
                }
                .buttonStyle(.bordered)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal)
                }

                if !output.isEmpty {
                    ScrollView {
                        Text(output)
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 240)
                    .background(Color.gray.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: 520)
            .padding()
        } else {
            VStack(spacing: 8) {
                Text("Smoke test not configured")
                    .font(.headline)
                Text("Create `~/.ssh-client-tmux-smoke/config.json` and `private-key`, then rebuild.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: 520)
        }
    }

    private func runSmokeTest(config: SmokeTestConfig, keyData: Data) async {
        isRunning = true
        output = ""
        errorMessage = nil
        defer { isRunning = false }

        let endpoint = SSHEndpoint(host: config.host, port: config.port, user: config.user)
        let credentials = Credentials.privateKey(keyData)

        do {
            let connection = try await SSHConnection.connect(
                endpoint: endpoint,
                credentials: credentials
            )
            let result = try await connection.exec("uname -a")
            output = String(decoding: result.stdout, as: UTF8.self)
            await connection.disconnect()
        } catch {
            errorMessage = "\(error)"
        }
    }
}

#Preview {
    ContentView()
}
