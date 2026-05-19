#if canImport(UIKit)
import SwiftUI
import SSHCore

/// Wrapper that opens an SSH connection + interactive shell and
/// renders the result with `SessionView` in `.single` mode (no
/// tabs, no panes, no split-related shortcuts). Replaces the
/// legacy `RemoteShellView` for the "Open shell" entry — same
/// SSH machinery underneath, but the chrome matches the
/// demo/tmux flows pixel-for-pixel.
///
/// Lifecycle mirrors `TmuxBackendSessionView`: connect on `.task`,
/// tear down on close, reconnect when the scene returns to active
/// after the SSH socket dropped during background.
struct SSHBackendSessionView: View {
    let host: Host
    let tofu: TOFUCoordinator
    let settings: SettingsStore
    let keyStore: KeyStore

    @State private var connection: SSHConnection?
    @State private var shell: SSHShellSession?
    @State private var backend: SSHSessionBackend?
    @State private var statusMessage: String = "Connecting…"
    @State private var errorMessage: String?
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
                // Identity tied to the backend instance — a
                // reconnect builds a fresh backend and forces
                // SwiftUI to drop the prior view's `@State` (any
                // stale per-window cache, gridReady flag, etc.).
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
        .task { await connect() }
        .onAppear {
            FileLogger.shared.log("SSHBackendView.onAppear (host=\(host.host):\(host.port) user=\(host.user))")
        }
        .onDisappear {
            FileLogger.shared.log("SSHBackendView.onDisappear")
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            FileLogger.shared.log("SSHBackendView.scenePhase \(oldPhase) → \(newPhase)")
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

    private func close() async {
        FileLogger.shared.log("SSHBackendView.close")
        isClosing = true
        await backend?.disconnect()
        await shell?.close()
        await connection?.disconnect()
        dismiss()
    }

    private func reconnectIfNeeded() async {
        let stale = ["disconnected", "stream ended", "cancelled"].contains(statusMessage)
        guard stale else { return }
        FileLogger.shared.log("SSHBackendView.reconnectIfNeeded: status=\(statusMessage)")
        await shell?.close()
        await connection?.disconnect()
        shell = nil
        connection = nil
        backend = nil
        statusMessage = "reconnecting…"
        await connect()
    }

    private func connect() async {
        FileLogger.shared.log("SSHBackendView.connect: begin")
        let endpoint = SSHEndpoint(host: host.host, port: host.port, user: host.user)
        let verifier = KnownHostsVerifier(
            knownHostsURL: KnownHostsLocation.url,
            prompter: { [tofu] prompt in
                await tofu.awaitDecision(for: prompt)
            }
        )
        do {
            let creds = try await loadCredentials()
            let conn = try await SSHConnection.connect(
                endpoint: endpoint,
                credentials: creds,
                hostKeyVerifier: verifier
            )
            await MainActor.run {
                self.connection = conn
                self.statusMessage = "opening shell"
            }
            let openedShell = try await conn.openShell()
            await MainActor.run {
                self.shell = openedShell
                self.backend = SSHSessionBackend(
                    host: host.host,
                    user: host.user,
                    shell: openedShell
                )
                self.statusMessage = "connected"
            }
            FileLogger.shared.log("SSHBackendView.connect: shell open")
        } catch {
            FileLogger.shared.log("SSHBackendView.connect: error \(error)")
            await MainActor.run {
                self.errorMessage = "connect failed: \(error)"
                self.statusMessage = "disconnected"
            }
        }
    }

    private func loadCredentials() async throws -> Credentials {
        let id = host.keyID ?? keyStore.keys.first?.id
        guard let id else {
            throw NSError(
                domain: "SSHBackendSessionView",
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
