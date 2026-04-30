import SwiftUI

/// Top-level scene: holds the host store and TOFU coordinator,
/// presents the host list inside a NavigationStack, and hosts the
/// single TOFU sheet that all child views drive.
///
/// Programmatic navigation via `path` so `ssh://` URLs can push a
/// host detail screen without going through the list. The list's
/// `NavigationLink(value: host.id)` plus our `navigationDestination`
/// keeps tap-driven navigation working.
struct ContentView: View {
    @State private var store = HostStore()
    @State private var tofu = TOFUCoordinator()
    @State private var settings = SettingsStore()
    @State private var keyStore = KeyStore()

    @State private var path: [UUID] = []
    @State private var prefillForNewHost: Host?
    @Bindable private var consent = RecordingConsent.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            HostListView(
                store: store,
                settings: settings,
                keyStore: keyStore
            )
            .navigationDestination(for: UUID.self) { hostID in
                if let host = store.hosts.first(where: { $0.id == hostID }) {
                    HostDetailView(
                        host: host,
                        store: store,
                        tofu: tofu,
                        settings: settings,
                        keyStore: keyStore
                    )
                } else {
                    Text("Host not found")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { tofu.pendingPrompt != nil },
                set: { _ in /* dismiss only via button → resolve */ }
            )
        ) {
            if let prompt = tofu.pendingPrompt {
                TOFUPromptSheet(prompt: prompt) { tofu.resolve($0) }
            }
        }
        .sheet(item: $prefillForNewHost) { prefill in
            NavigationStack {
                HostFormView(
                    initial: nil,
                    prefill: prefill,
                    keyStore: keyStore
                ) { newHost in
                    store.add(newHost)
                    prefillForNewHost = nil
                    path = [newHost.id]
                } onCancel: {
                    prefillForNewHost = nil
                }
            }
        }
        .onOpenURL(perform: handleIncomingURL)
        .task {
            // Poll while the app is alive so the prompt fires even
            // if the user never backgrounds. The check is essentially
            // free; the sheet only appears when staleness flips on.
            while !Task.isCancelled {
                checkStaleRecordings()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { checkStaleRecordings() }
        }
        .sheet(isPresented: $consent.pendingPrompt) {
            LongRunningRecordingSheet { consent.pendingPrompt = false }
        }
    }

    private func checkStaleRecordings() {
        if LongRunningRecordingSheet.shouldShow() {
            consent.pendingPrompt = true
        }
    }

    /// `ssh://[user@]host[:port]` → either push the existing host's
    /// detail screen or pop the "new host" sheet pre-filled with the
    /// URL's components.
    private func handleIncomingURL(_ url: URL) {
        guard let parsed = SSHURL.parse(url) else { return }
        let port = parsed.port ?? 22
        let user = parsed.user ?? ""
        // Existing match: same host:port + (user matches if URL gave one).
        let match = store.hosts.first { h in
            h.host == parsed.host
                && h.port == port
                && (parsed.user == nil || h.user == user)
        }
        if let match {
            path = [match.id]
        } else {
            prefillForNewHost = Host(
                name: parsed.host,
                host: parsed.host,
                port: port,
                user: user
            )
        }
    }
}

#Preview {
    ContentView()
}
