import SwiftUI

/// Add / edit a host. Pass `initial: nil` for create, an existing
/// `Host` for edit. The id is preserved on edit so the navigation
/// state (and saved associations) survive.
struct HostFormView: View {
    let initial: Host?
    let keyStore: KeyStore
    let onSave: (Host) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var user: String
    @State private var keyID: UUID?

    init(
        initial: Host?,
        keyStore: KeyStore,
        onSave: @escaping (Host) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initial = initial
        self.keyStore = keyStore
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: initial?.name ?? "")
        _host = State(initialValue: initial?.host ?? "")
        _port = State(initialValue: String(initial?.port ?? 22))
        _user = State(initialValue: initial?.user ?? "")
        _keyID = State(initialValue: initial?.keyID ?? keyStore.keys.first?.id)
    }

    private var canSave: Bool {
        !host.isEmpty && !user.isEmpty && Int(port) != nil
    }

    private var keyBinding: Binding<UUID?> {
        Binding(
            get: { keyID ?? keyStore.keys.first?.id },
            set: { keyID = $0 }
        )
    }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Display name (optional)", text: $name)
                    .autocorrectionDisabled()
            }
            Section("Connection") {
                TextField("Host", text: $host)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                TextField("User", text: $user)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Section("Authentication") {
                if keyStore.keys.isEmpty {
                    Text("No keys configured. Add one in Settings → SSH keys.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Key", selection: keyBinding) {
                        ForEach(keyStore.keys) { key in
                            Text(key.name).tag(Optional(key.id))
                        }
                    }
                }
            }
        }
        .navigationTitle(initial == nil ? "New Host" : "Edit Host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let saved = Host(
                        id: initial?.id ?? UUID(),
                        name: name.isEmpty ? host : name,
                        host: host,
                        port: Int(port) ?? 22,
                        user: user,
                        lastTmuxSession: initial?.lastTmuxSession,
                        keyID: keyID
                    )
                    onSave(saved)
                }
                .disabled(!canSave)
            }
        }
    }
}
