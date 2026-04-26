import SwiftUI
import SSHCore
import TmuxCC

/// Crude interactive shell for proving SSHShellSession works end-to-end.
/// Raw bytes drop into a scrolling text view. The same bytes are also
/// fed through a `TmuxCCParser`; any emitted `TmuxEvent`s are listed
/// in a second panel below — empty until the user types
/// `tmux -CC new-session …` and the DCS envelope kicks in.
/// TerminalKit (SwiftTerm) replaces the raw-text rendering in a later step.
struct ShellSmokeView: View {
    let config: SmokeTestConfig
    let keyData: Data

    @State private var connection: SSHConnection?
    @State private var session: SSHShellSession?
    @State private var output: String = ""
    @State private var events: [String] = []
    @State private var input: String = ""
    @State private var statusMessage: String = "Connecting…"
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            rawOutputPanel
                .frame(maxHeight: .infinity)

            Divider()

            eventsPanel
                .frame(height: 240)

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

    private var rawOutputPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelLabel("raw output")
            ScrollViewReader { proxy in
                ScrollView {
                    Text(output.isEmpty ? "(no output yet)" : output)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("output-end")
                }
                .onChange(of: output) {
                    withAnimation(.linear(duration: 0.05)) {
                        proxy.scrollTo("output-end", anchor: .bottom)
                    }
                }
            }
            .background(Color(.secondarySystemBackground))
        }
    }

    private var eventsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelLabel("parsed tmux events")
            ScrollViewReader { proxy in
                ScrollView {
                    if events.isEmpty {
                        Text("(no tmux -CC events yet — try: tmux -CC new-session -s ipad-test)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(10)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(events.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(10)
                        .id("events-end")
                    }
                }
                .onChange(of: events.count) {
                    withAnimation(.linear(duration: 0.05)) {
                        proxy.scrollTo("events-end", anchor: .bottom)
                    }
                }
            }
            .background(Color(.tertiarySystemBackground))
        }
    }

    private func panelLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            // Drain output → append to the text view AND feed through
            // TmuxCCParser, whose emitted events go to the events panel.
            Task {
                var parser = TmuxCCParser()
                do {
                    for try await data in shell.output {
                        let chunk = String(decoding: data, as: UTF8.self)
                        let newEventLines = parser.feed(data).map { String(describing: $0) }
                        await MainActor.run {
                            output += chunk
                            if !newEventLines.isEmpty {
                                events.append(contentsOf: newEventLines)
                            }
                        }
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
