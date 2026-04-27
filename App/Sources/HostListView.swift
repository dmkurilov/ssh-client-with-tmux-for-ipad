import SwiftUI

/// Root list of saved hosts. Tap to push the detail screen; toolbar
/// "+" presents the add-host sheet; swipe-to-delete works on rows.
struct HostListView: View {
    let store: HostStore
    let tofu: TOFUCoordinator
    let keyData: Data?

    @State private var showingAdd = false

    var body: some View {
        List {
            ForEach(store.hosts) { host in
                NavigationLink {
                    HostDetailView(
                        host: host,
                        store: store,
                        tofu: tofu,
                        keyData: keyData
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
                HostFormView(initial: nil) { newHost in
                    store.add(newHost)
                    showingAdd = false
                } onCancel: {
                    showingAdd = false
                }
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
