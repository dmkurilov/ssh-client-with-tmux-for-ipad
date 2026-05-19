#if canImport(UIKit)
import SwiftUI
import UIKit
import SSHCore
import TmuxCC
import TerminalKit

/// New-chrome tmux session view. Owns the SSH/tmux connection
/// lifecycle and renders the same `SessionView`-style chrome
/// (top toolbar with fs/tb/kb, tab strip with rename + drag-drop,
/// per-pane control bar, custom soft keyboard, ⌘⌥+arrow nav, etc.)
/// against a real `TmuxSessionBackend`.
///
/// Sits beside `TmuxSessionView` (the original) — both are reachable
/// from `HostDetailView`. Once parity is verified the original can
/// retire. Until then the duplication is deliberate; we don't want
/// to refactor the connection layer in the same change that
/// introduces the new UI path.
struct TmuxBackendSessionView: View {
    let host: Host
    let tofu: TOFUCoordinator
    let settings: SettingsStore
    let store: HostStore
    let keyStore: KeyStore
    var forceShowPicker: Bool = false

    @State private var connection: SSHConnection?
    @State private var shell: SSHShellSession?
    @State private var session = TmuxSession()
    @State private var backend: TmuxSessionBackend?
    @State private var statusMessage: String = "Connecting…"
    @State private var errorMessage: String?
    @State private var availableSessions: [TmuxSessionInfo] = []
    @State private var showingAttachPicker = false
    @State private var pendingResize: Task<Void, Never>?
    @State private var lastAppliedSize: (cols: Int, rows: Int)?
    /// Set to true when the user explicitly closes the screen so
    /// the pump's stream-end / `.exit` handler doesn't fight the
    /// dismiss by re-presenting the picker.
    @State private var isClosing = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let backend {
                SessionView(
                    backend: backend,
                    scheme: settings.selectedScheme,
                    showFakeBadge: false,
                    onClose: { Task { await close() } }
                )
                // Tie the view's SwiftUI identity to the backend
                // *instance*. A reconnect creates a fresh
                // `TmuxSessionBackend`, which forces SwiftUI to
                // tear down and re-mount the inner view — so
                // `@State` (including `layoutCache`) starts clean
                // for every (re)attach. Without this, SwiftUI may
                // reuse the previous view's identity and carry
                // stale per-window caches into the new session.
                .id(ObjectIdentifier(backend))
            } else {
                connectingView
            }
        }
        .alert(
            "Connection error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            presenting: errorMessage
        ) { _ in
            Button("OK") {
                errorMessage = nil
                dismiss()
            }
        } message: { msg in
            Text(msg)
        }
        .sheet(isPresented: $showingAttachPicker) {
            TmuxAttachPickerSheet(
                sessions: availableSessions,
                onAttach: { name, forceDetach in
                    showingAttachPicker = false
                    Task { await attach(.existing(name: name, forceDetach: forceDetach)) }
                },
                onCreate: { name in
                    showingAttachPicker = false
                    Task { await attach(.new(name)) }
                },
                onRename: { oldName, newName in
                    Task { await renameSessionViaExec(old: oldName, new: newName) }
                },
                onCancel: {
                    FileLogger.shared.log("TmuxBackendView: picker cancelled → dismiss")
                    showingAttachPicker = false
                    statusMessage = "cancelled"
                    dismiss()
                }
            )
            .interactiveDismissDisabled()
        }
        .task { await connect() }
        .onAppear {
            FileLogger.shared.log("TmuxBackendView.onAppear (host=\(host.host):\(host.port) user=\(host.user) lastTmux=\(host.lastTmuxSession ?? "nil") forcePicker=\(forceShowPicker))")
        }
        .onDisappear {
            FileLogger.shared.log("TmuxBackendView.onDisappear (sessionName=\(session.sessionName ?? "nil"))")
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            FileLogger.shared.log("TmuxBackendView.scenePhase \(oldPhase) → \(newPhase)")
            if newPhase == .active {
                Task { await reconnectIfNeeded() }
            }
        }
    }

    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(statusMessage)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Connecting")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Lifecycle

    private func close() async {
        FileLogger.shared.log("TmuxBackendView.close")
        isClosing = true
        await backend?.disconnect()
        await shell?.close()
        await connection?.disconnect()
        if let name = session.sessionName {
            store.updateLastTmuxSession(hostID: host.id, name: name)
            TranscriptStore.shared.close(host: host.host, session: name)
        }
        dismiss()
    }

    /// Called when the active session ended (last window closed).
    /// Drops the shell + backend, refreshes the session list via
    /// SSH `exec`, and pops the attach picker back up so the user
    /// can pick another existing session or create a new one.
    private func reshowPicker() async {
        FileLogger.shared.log("TmuxBackend: session ended — re-showing picker")
        await shell?.close()
        shell = nil
        backend = nil
        session.reset()
        statusMessage = "session ended — pick another"

        guard let conn = connection else {
            // Can't recover without a connection — pop back.
            dismiss()
            return
        }
        let sessions = (try? await probeSessions(conn: conn)) ?? []
        await MainActor.run {
            self.availableSessions = sessions
            self.showingAttachPicker = true
        }
    }

    private func reconnectIfNeeded() async {
        let stale = ["disconnected", "stream ended", "cancelled"].contains(statusMessage)
        FileLogger.shared.log("TmuxBackendView.reconnectIfNeeded: status=\(statusMessage) stale=\(stale)")
        guard stale else { return }
        await shell?.close()
        await connection?.disconnect()
        shell = nil
        connection = nil
        session.reset()
        backend = nil
        lastAppliedSize = nil
        statusMessage = "reconnecting…"
        await connect()
    }

    // MARK: - Connect / attach (mirrors TmuxSessionView)

    private enum AttachChoice {
        case existing(name: String, forceDetach: Bool)
        case new(String?)
    }

    private func connect() async {
        FileLogger.shared.log("TmuxBackendView.connect: begin")
        let endpoint = SSHEndpoint(host: host.host, port: host.port, user: host.user)
        let verifier = KnownHostsVerifier(
            knownHostsURL: KnownHostsLocation.url,
            prompter: { [tofu] prompt in
                await tofu.awaitDecision(for: prompt)
            }
        )
        do {
            FileLogger.shared.log("TmuxBackendView.connect: loading credentials")
            let creds = try await loadCredentials()
            FileLogger.shared.log("TmuxBackendView.connect: credentials loaded; opening SSH")
            let conn = try await SSHConnection.connect(
                endpoint: endpoint,
                credentials: creds,
                hostKeyVerifier: verifier
            )
            FileLogger.shared.log("TmuxBackendView.connect: SSH open; probing tmux sessions")
            await MainActor.run {
                self.connection = conn
                self.statusMessage = "probing tmux sessions"
            }
            let sessions = try await probeSessions(conn: conn)
            FileLogger.shared.log("TmuxBackendView.connect: probe got \(sessions.count) sessions: \(sessions.map { "\($0.name)\($0.attached ? "*" : "")" }.joined(separator: ","))")
            await MainActor.run { self.availableSessions = sessions }

            if !forceShowPicker,
               let remembered = host.lastTmuxSession,
               let match = sessions.first(where: { $0.name == remembered }),
               !match.attached
            {
                FileLogger.shared.log("TmuxBackendView.connect: auto-attaching remembered '\(remembered)'")
                await attach(.existing(name: remembered, forceDetach: false))
            } else {
                FileLogger.shared.log("TmuxBackendView.connect: showing picker (forcePicker=\(forceShowPicker), lastTmux=\(host.lastTmuxSession ?? "nil"))")
                await MainActor.run {
                    self.statusMessage = "choose tmux session"
                    self.showingAttachPicker = true
                }
            }
        } catch {
            FileLogger.shared.log("TmuxBackendView.connect: FAILED \(error)")
            await MainActor.run {
                self.errorMessage = "Connect failed: \(error)"
                self.statusMessage = "disconnected"
            }
        }
    }

    private func renameSessionViaExec(old: String, new: String) async {
        guard let conn = connection else { return }
        let oldEsc = shellEscape(old)
        let newEsc = shellEscape(new)
        let inner = "tmux rename-session -t \(oldEsc) \(newEsc) 2>/dev/null; true"
        _ = try? await conn.exec("$SHELL -lc '\(inner)'")
        if let refreshed = try? await probeSessions(conn: conn) {
            await MainActor.run { self.availableSessions = refreshed }
        }
    }

    private func probeSessions(conn: SSHConnection) async throws -> [TmuxSessionInfo] {
        // `tmux ls` exits 1 when the server has zero sessions —
        // that's not an error from our perspective (it just means
        // "show only the New section"), so we swallow the exit
        // code with `; true` to keep `conn.exec` from throwing.
        let format = "#{session_id}\t#{session_name}\t#{session_windows}\t#{session_attached}"
        let inner = "tmux ls -F \"\(format)\" 2>/dev/null; true"
        let cmd = "$SHELL -lc '\(inner)'"
        let result = try await conn.exec(cmd)
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        return stdout
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { TmuxSessionInfo.parse(String($0)) }
    }

    private func attach(_ choice: AttachChoice) async {
        let label: String = {
            switch choice {
            case .existing(let n, let f): return "existing(\(n) forceDetach=\(f))"
            case .new(let n): return "new(\(n ?? "<unnamed>"))"
            }
        }()
        FileLogger.shared.log("TmuxBackendView.attach: \(label)")
        guard let conn = connection else {
            FileLogger.shared.log("TmuxBackendView.attach: no connection — abort")
            return
        }
        do {
            if case .existing(let name, true) = choice {
                FileLogger.shared.log("TmuxBackendView.attach: pre-detach existing client of '\(name)'")
                let escaped = shellEscape(name)
                let inner = "tmux detach-client -s \(escaped) 2>/dev/null; true"
                _ = try? await conn.exec("$SHELL -lc '\(inner)'")
            }
            FileLogger.shared.log("TmuxBackendView.attach: opening shell")
            let shellSession = try await conn.openShell()
            FileLogger.shared.log("TmuxBackendView.attach: shell open")
            let cmd: String
            switch choice {
            case .existing(let name, _):
                cmd = "tmux -CC attach-session -t \(shellEscape(name))\n"
            case .new(let maybeName):
                if let name = maybeName, !name.isEmpty {
                    cmd = "tmux -CC new-session -A -s \(shellEscape(name))\n"
                } else {
                    cmd = "tmux -CC\n"
                }
            }

            // Build the backend AFTER the shell exists, so the
            // backend's first `attachShell` has a real handle.
            let newBackend = TmuxSessionBackend(tmux: session)
            newBackend.attachShell(shellSession)
            newBackend.onActivePaneResize = { cols, rows in
                scheduleResize(cols: cols, rows: rows)
            }

            await MainActor.run {
                self.shell = shellSession
                self.backend = newBackend
                self.statusMessage = "starting tmux -CC"
            }

            FileLogger.shared.log("TmuxBackendView.attach: write \(cmd.trimmingCharacters(in: .newlines))")
            try await shellSession.write(Data(cmd.utf8))
            FileLogger.shared.log("TmuxBackendView.attach: pump starting")

            Task { await pumpEvents(shell: shellSession, backend: newBackend) }
        } catch {
            FileLogger.shared.log("TmuxBackendView.attach: FAILED \(error)")
            await MainActor.run {
                self.errorMessage = "Attach failed: \(error)"
                self.statusMessage = "disconnected"
            }
        }
    }

    /// Read the SSH stream, parse `-CC` events, hand them to
    /// `TmuxSession.handle` and then `backend.didHandle` to keep
    /// `SessionState` in sync. Mirrors `TmuxSessionView`'s pump.
    private func pumpEvents(shell: SSHShellSession, backend: TmuxSessionBackend) async {
        var parser = TmuxCCParser()
        do {
            outer: for try await data in shell.output {
                let events = parser.feed(data)
                let sawExit: Bool = await MainActor.run { () -> Bool in
                    var exit = false
                    for event in events {
                        self.session.handle(event)
                        backend.didHandle(event)
                        if case .exit = event { exit = true }
                        if case .output(let pid, let payload) = event {
                            // Hex-log small output bursts and any
                            // burst containing CR (0x0D) — that's
                            // the byte that moves cursor to col 0,
                            // which is the cursor-jump symptom we're
                            // chasing. Big bursts (vim screen
                            // renders, etc.) are skipped to keep
                            // the log readable.
                            let hasCR = payload.contains(0x0D)
                            if hasCR || payload.count <= 32 {
                                let prefix = payload.prefix(64)
                                let hex = prefix
                                    .map { String(format: "%02x", $0) }
                                    .joined()
                                let suffix = payload.count > 64 ? "…" : ""
                                FileLogger.shared.log(
                                    "out %\(pid) \(payload.count)B hex=\(hex)\(suffix)\(hasCR ? " [CR]" : "")"
                                )
                            }
                            TranscriptStore.shared.feed(
                                host: self.host.host,
                                session: self.session.sessionName ?? "default",
                                windowID: self.session.windowID(forPane: pid),
                                paneID: pid,
                                data: payload
                            )
                        }
                    }
                    if self.session.isAttached, self.statusMessage != "attached" {
                        self.statusMessage = "attached"
                        Task { await self.bootstrapWindows() }
                    }
                    return exit
                }
                if sawExit { break outer }
            }
            // Stream ended (gracefully via `%exit` or because the
            // shell EOF'd). Unless the user explicitly closed the
            // screen, this means the tmux session went away — pop
            // the picker back up so they can attach to another or
            // start a new one.
            await MainActor.run {
                if self.isClosing {
                    self.statusMessage = "stream ended"
                } else {
                    Task { await self.reshowPicker() }
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Stream error: \(error)"
                self.statusMessage = "disconnected"
            }
        }
    }

    /// Enumerate windows via `list-windows` so the chrome (tabs +
    /// active pane) has something to draw against. Per-pane content
    /// is *not* fetched here anymore — `SessionView` triggers
    /// `backend.applyGrid` once it knows its pane-area pixel size,
    /// and that's the single chokepoint that owns capture-pane (via
    /// the new suspend / `feedSnapshot` / resume sequencing). Doing
    /// it here too produced the "two prompts" duplication users saw
    /// at screen-93: capture replayed bytes that live `%output` had
    /// already pushed.
    private func bootstrapWindows() async {
        guard let shell else { return }
        let format = "#{window_id}\t#{window_active}\t#{window_name}\t#{window_layout}"
        do {
            let lines = try await session.runCommand(
                "list-windows -F \"\(format)\"\n",
                write: { try await shell.write($0) }
            )
            let snaps = lines.compactMap(parseWindowSnapshot)
            session.bootstrap(windows: snaps)
            backend?.syncState()
        } catch {
            // Best-effort.
        }
    }

    // MARK: - Resize debounce

    private func scheduleResize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if let last = lastAppliedSize, last.cols == cols, last.rows == rows {
            return
        }
        pendingResize?.cancel()
        pendingResize = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            await applyResize(cols: cols, rows: rows)
        }
    }

    private func applyResize(cols: Int, rows: Int) async {
        guard let shell else { return }
        do {
            try await shell.resize(cols: cols, rows: rows)
            await MainActor.run {
                self.lastAppliedSize = (cols, rows)
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Resize failed: \(error)"
            }
        }
    }

    // MARK: - Helpers

    private func parseWindowSnapshot(_ line: String) -> TmuxSession.WindowSnapshot? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return nil }
        let rawID = parts[0]
        guard rawID.first == "@", let id = Int(rawID.dropFirst()) else { return nil }
        let isActive = parts[1] == "1"
        let name = parts[2].isEmpty ? nil : String(parts[2])
        let layout = parts[3].isEmpty ? nil : String(parts[3])
        return TmuxSession.WindowSnapshot(
            id: id,
            name: name,
            isActive: isActive,
            layout: layout
        )
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func loadCredentials() async throws -> Credentials {
        let id = host.keyID ?? keyStore.keys.first?.id
        guard let id else {
            throw NSError(
                domain: "TmuxBackendSessionView",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No SSH key configured for this host."]
            )
        }
        let (meta, data) = try await keyStore.load(
            id,
            prompt: "Authenticate to use SSH key for \(host.name)"
        )
        return KeyStore.credentials(for: meta, data: data)
    }
}
#endif
