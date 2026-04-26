import SwiftUI
import SSHCore
import TmuxCC
import TerminalKit

/// Live SSH shell screen: SwiftTerm renders the bytes; the events
/// panel below shows what `TmuxCCParser` sees on the same stream.
/// The events panel will move behind a debug toggle once we have a
/// proper tab UI; for now it earns its keep as the canary for tmux
/// state work.
struct RemoteShellView: View {
    let config: SmokeTestConfig
    let keyData: Data

    @State private var connection: SSHConnection?
    @State private var session: SSHShellSession?
    @State private var events: [String] = []
    @State private var statusMessage: String = "Connecting…"
    @State private var errorMessage: String?

    @State private var driver = TerminalDriver()

    var body: some View {
        VStack(spacing: 0) {
            header

            terminalPanel
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

    private var terminalPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelLabel("terminal")
            SwiftTermView(
                driver: driver,
                onInput: { data in
                    handleInput(data)
                },
                onSizeChange: { cols, rows in
                    // TODO: wire to SSHShellSession.resize once Citadel's
                    // changeSize is reachable from withPTY's closure scope.
                    _ = (cols, rows)
                }
            )
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
            // Pump output: drive SwiftTerm AND the tmux parser from the
            // same byte stream.
            Task {
                var parser = TmuxCCParser()
                do {
                    for try await data in shell.output {
                        let newEventLines = parser.feed(data).map { String(describing: $0) }
                        await MainActor.run {
                            driver.feed(data)
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

    private func handleInput(_ data: Data) {
        guard let session else { return }
        Task {
            do {
                try await session.write(data)
            } catch {
                await MainActor.run {
                    errorMessage = "write failed: \(error)"
                }
            }
        }
    }
}
