import SwiftUI
import SSHCore

/// Crude interactive shell for proving SSHShellSession works end-to-end.
/// No ANSI rendering, no colors, no cursor positioning — raw bytes drop
/// into a scrolling text view, and a text field sends a line at a time.
/// TerminalKit (SwiftTerm) replaces this in a later step.
struct ShellSmokeView: View {
    let config: SmokeTestConfig
    let keyData: Data

    @State private var connection: SSHConnection?
    @State private var session: SSHShellSession?
    @State private var output: String = ""
    @State private var input: String = ""
    @State private var statusMessage: String = "Connecting…"
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    Text(output.isEmpty ? "(no output yet)" : output)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("end")
                }
                .onChange(of: output) {
                    withAnimation(.linear(duration: 0.05)) {
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                }
            }
            .background(Color(.secondarySystemBackground))

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
                    .padding(8)
            }

            inputRow
        }
        .navigationTitle(config.host)
        .navigationBarTitleDisplayMode(.inline)
        .task { await openShell() }
        .onDisappear {
            Task {
                await session?.close()
                await connection?.disconnect()
            }
        }
    }

    private var header: some View {
        HStack {
            Text(statusMessage)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("type a command, press return", text: $input)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { sendLine() }
                .disabled(session == nil)
            Button("Send") { sendLine() }
                .disabled(session == nil || input.isEmpty)
        }
        .padding(10)
    }

    private func openShell() async {
        let endpoint = SSHEndpoint(host: config.host, port: config.port, user: config.user)
        do {
            let conn = try await SSHConnection.connect(
                endpoint: endpoint,
                credentials: .privateKey(keyData)
            )
            let shell = try await conn.openShell()
            await MainActor.run {
                self.connection = conn
                self.session = shell
                self.statusMessage = "connected"
            }
            // Drain output → append to the text view.
            Task {
                do {
                    for try await data in shell.output {
                        let chunk = String(decoding: data, as: UTF8.self)
                        await MainActor.run { output += chunk }
                    }
                    await MainActor.run { statusMessage = "session ended" }
                } catch {
                    await MainActor.run {
                        errorMessage = "stream error: \(error)"
                        statusMessage = "disconnected"
                    }
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "connect failed: \(error)"
                statusMessage = "disconnected"
            }
        }
    }

    private func sendLine() {
        guard let session else { return }
        let line = input + "\n"
        input = ""
        Task {
            do {
                try await session.write(Data(line.utf8))
            } catch {
                await MainActor.run {
                    errorMessage = "write failed: \(error)"
                }
            }
        }
    }
}
