import SwiftUI
import SSHCore
import TmuxCC

/// Live tmux `-CC` session screen. Opens its own SSH shell channel,
/// runs `tmux -CC new-session -A -s ipad-tmux` on it, feeds output
/// through `TmuxCCParser`, and renders a tab strip from the resulting
/// `[TmuxEvent]`s. No SwiftTerm in this path — pane content rendering
/// arrives in step B'.
struct TmuxSessionView: View {
    let config: SmokeTestConfig
    let keyData: Data

    @State private var connection: SSHConnection?
    @State private var shell: SSHShellSession?
    @State private var session = TmuxSession()
    @State private var statusMessage: String = "Connecting…"
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            tabStrip
                .frame(height: 44)
                .background(Color(.secondarySystemBackground))
            Divider()
            content
        }
        .navigationTitle(session.sessionName.map { "tmux: \($0)" } ?? "tmux")
        .navigationBarTitleDisplayMode(.inline)
        .task { await connect() }
        .onDisappear {
            Task {
                await shell?.close()
                await connection?.disconnect()
            }
        }
    }

    private var statusBar: some View {
        HStack {
            Text(statusMessage)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            if let id = session.sessionID, let name = session.sessionName {
                Text("$\(id) \(name)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if session.windows.isEmpty {
                    Text("(waiting for windowAdd events)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                } else {
                    ForEach(session.windows) { window in
                        tabButton(window)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func tabButton(_ window: TmuxWindow) -> some View {
        let isActive = window.id == session.activeWindowID
        let label = window.name.map { "@\(window.id) · \($0)" } ?? "@\(window.id)"
        return Text(label)
            .font(.caption.monospaced())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var content: some View {
        VStack(spacing: 12) {
            Spacer()
            if let id = session.activeWindowID {
                Text("Window @\(id)")
                    .font(.title2.weight(.semibold))
                if let activePane = activePaneID(for: id) {
                    Text("active pane %\(activePane)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text("Pane content rendering — TODO (step B').")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Text("No active window")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            if let line = session.lastResponseLine {
                Text("last response: \(line)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func activePaneID(for windowID: Int) -> Int? {
        session.windows.first(where: { $0.id == windowID })?.activePaneID
    }

    private func connect() async {
        let endpoint = SSHEndpoint(host: config.host, port: config.port, user: config.user)
        do {
            let conn = try await SSHConnection.connect(
                endpoint: endpoint,
                credentials: .privateKey(keyData)
            )
            let shellSession = try await conn.openShell()
            await MainActor.run {
                self.connection = conn
                self.shell = shellSession
                self.statusMessage = "starting tmux -CC"
            }

            // Kick off tmux -CC. `-A` makes new-session attach to an
            // existing session with the same name instead of failing
            // with "duplicate session".
            try await shellSession.write(
                Data("tmux -CC new-session -A -s ipad-tmux\n".utf8)
            )

            // Pump output → parser → state.
            Task {
                var parser = TmuxCCParser()
                do {
                    for try await data in shellSession.output {
                        let events = parser.feed(data)
                        await MainActor.run {
                            for event in events {
                                self.session.handle(event)
                            }
                            if self.session.isAttached, self.statusMessage != "attached" {
                                self.statusMessage = "attached"
                            }
                        }
                    }
                    await MainActor.run { self.statusMessage = "stream ended" }
                } catch {
                    await MainActor.run {
                        self.errorMessage = "stream error: \(error)"
                        self.statusMessage = "disconnected"
                    }
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "connect failed: \(error)"
                self.statusMessage = "disconnected"
            }
        }
    }
}
