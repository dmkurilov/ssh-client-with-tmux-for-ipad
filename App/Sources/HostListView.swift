import SwiftUI

/// Root list of saved hosts. Tap to push the detail screen; toolbar
/// "+" presents the add-host sheet; swipe-to-delete works on rows.
struct HostListView: View {
    let store: HostStore
    let tofu: TOFUCoordinator
    let settings: SettingsStore
    let keyStore: KeyStore

    @State private var showingAdd = false
    @State private var showingSettings = false
    @State private var sharingLog = false
    @State private var importingConfig = false

    var body: some View {
        List {
            ForEach(store.hosts) { host in
                NavigationLink {
                    HostDetailView(
                        host: host,
                        store: store,
                        tofu: tofu,
                        settings: settings,
                        keyStore: keyStore
                    )
                } label: {
                    HostRow(host: host)
                }
            }
            .onDelete { offsets in
                store.remove(at: offsets)
            }
        }
        .overlay {
            if store.hosts.isEmpty {
                ContentUnavailableView(
                    "No hosts yet",
                    systemImage: "server.rack",
                    description: Text("Tap + to add your first SSH host.")
                )
            }
        }
        .navigationTitle("Hosts")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    sharingLog = true
                } label: {
                    Image(systemName: "ladybug")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    importingConfig = true
                } label: {
                    Image(systemName: "square.and.arrow.down.on.square")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                HostFormView(initial: nil, keyStore: keyStore) { newHost in
                    store.add(newHost)
                    showingAdd = false
                } onCancel: {
                    showingAdd = false
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(settings: settings, keyStore: keyStore) {
                showingSettings = false
            }
        }
        .sheet(isPresented: $sharingLog) {
            DebugLogShareSheet(url: FileLogger.shared.url) {
                sharingLog = false
            }
        }
        .sheet(isPresented: $importingConfig) {
            SSHConfigImportSheet(store: store) {
                importingConfig = false
            }
        }
    }
}

private struct HostRow: View {
    let host: Host

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(host.name)
                .font(.body.weight(.medium))
            Text(connectionString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var connectionString: String {
        let portSuffix = host.port == 22 ? "" : ":\(host.port)"
        return "\(host.user)@\(host.host)\(portSuffix)"
    }
}
