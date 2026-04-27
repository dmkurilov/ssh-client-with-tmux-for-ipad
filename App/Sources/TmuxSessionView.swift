import SwiftUI
import SSHCore
import TmuxCC
import TerminalKit

/// Live tmux `-CC` session screen with a tab strip and per-pane
/// SwiftTerm rendering. Tap a tab to switch windows on the server.
/// Typing in the active pane sends each input chunk back to the
/// pane via `send-keys -H -t %<paneID> <hex bytes>` — `-H` lets us
/// pass arbitrary bytes (control chars, escape sequences, UTF-8)
/// without shell-quoting headaches.
struct TmuxSessionView: View {
    let config: SmokeTestConfig
    let keyData: Data
    let tofu: TOFUCoordinator

    @State private var connection: SSHConnection?
    @State private var shell: SSHShellSession?
    @State private var session = TmuxSession()
    @State private var statusMessage: String = "Connecting…"
    @State private var errorMessage: String?
    @State private var pendingResize: Task<Void, Never>?
    @State private var lastAppliedSize: (cols: Int, rows: Int)?

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
        .sheet(
            isPresented: Binding(
                get: { tofu.pendingPrompt != nil },
                set: { _ in }
            )
        ) {
            if let prompt = tofu.pendingPrompt {
                TOFUPromptSheet(prompt: prompt) { tofu.resolve($0) }
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
                Button(action: newWindow) {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(!session.isAttached)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func tabButton(_ window: TmuxWindow) -> some View {
        let isActive = window.id == session.activeWindowID
        let label = window.name.map { "@\(window.id) · \($0)" } ?? "@\(window.id)"
        return Button {
            selectWindow(window.id)
        } label: {
            Text(label)
                .font(.caption.monospaced())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isActive ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            if session.paneIDs.isEmpty {
                VStack(spacing: 8) {
                    Text(session.activeWindowID.map { "Window @\($0)" } ?? "no active window")
                        .font(.title2.weight(.semibold))
                    Text("Waiting for pane output…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                // Every known pane gets its own SwiftTermView; only the
                // active one is visible AND interactive. Stable IDs
                // preserve view identity, so switching tabs doesn't
                // blow away buffers.
                ForEach(session.paneIDs, id: \.self) { paneID in
                    if let driver = session.driver(for: paneID) {
                        let isActive = paneID == currentPaneID
                        SwiftTermView(
                            driver: driver,
                            onInput: { data in
                                sendInput(data, toPaneID: paneID)
                            },
                            onSizeChange: { cols, rows in
                                scheduleResize(cols: cols, rows: rows)
                            }
                        )
                        .opacity(isActive ? 1 : 0)
                        .disabled(!isActive)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            if let line = session.lastResponseLine {
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(8)
            }
        }
        .overlay(alignment: .bottom) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(8)
            }
        }
    }

    private var currentPaneID: Int? {
        // Prefer the active window's known active pane.
        if let wid = session.activeWindowID,
           let pane = session.windows.first(where: { $0.id == wid })?.activePaneID
        {
            return pane
        }
        // Fallback: show any pane that's emitted output. Covers the
        // race where `output(paneID, …)` arrives before `windowAdd`,
        // and the common case of a single-pane session where layout
        // parsing isn't yet available to map panes → windows.
        return session.paneIDs.first
    }

    private func selectWindow(_ id: Int) {
        guard let shell else { return }
        Task {
            try? await shell.write(Data("select-window -t :@\(id)\n".utf8))
        }
    }

    private func newWindow() {
        guard let shell else { return }
        Task {
            try? await shell.write(Data("new-window\n".utf8))
        }
    }

    /// Route one chunk of keyboard input from SwiftTerm to a tmux
    /// pane via `send-keys -H` (hex byte arguments). One command per
    /// chunk — for typed keys that's per-keystroke, for paste it's
    /// one command for the whole burst.
    private func sendInput(_ data: Data, toPaneID paneID: Int) {
        guard let shell, !data.isEmpty else { return }
        let hexBytes = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        let cmd = "send-keys -H -t %\(paneID) \(hexBytes)\n"
        Task {
            try? await shell.write(Data(cmd.utf8))
        }
    }

    /// Debounced resize. Multiple SwiftTermView geometry updates
    /// during a single rotation/reflow collapse to one PTY resize.
    /// Skips when nothing has actually changed.
    private func scheduleResize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if let last = lastAppliedSize, last.cols == cols, last.rows == rows {
            return
        }
        pendingResize?.cancel()
        pendingResize = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
            guard !Task.isCancelled else { return }
            await applyResize(cols: cols, rows: rows)
        }
    }

    private func applyResize(cols: Int, rows: Int) async {
        guard let shell else { return }
        do {
            try await shell.resize(cols: cols, rows: rows)
            await MainActor.run {
                lastAppliedSize = (cols, rows)
            }
        } catch {
            await MainActor.run {
                errorMessage = "resize failed: \(error)"
            }
        }
    }

    private func connect() async {
        let endpoint = SSHEndpoint(host: config.host, port: config.port, user: config.user)
        let verifier = KnownHostsVerifier(
            knownHostsURL: KnownHostsLocation.url,
            prompter: { [tofu] prompt in
                await tofu.awaitDecision(for: prompt)
            }
        )
        do {
            let conn = try await SSHConnection.connect(
                endpoint: endpoint,
                credentials: .privateKey(keyData),
                hostKeyVerifier: verifier
            )
            let shellSession = try await conn.openShell()
            await MainActor.run {
                self.connection = conn
                self.shell = shellSession
                self.statusMessage = "starting tmux -CC"
            }

            try await shellSession.write(
                Data("tmux -CC new-session -A -s ipad-tmux\n".utf8)
            )

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
