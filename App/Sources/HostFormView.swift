import SwiftUI

/// Add / edit a host. Pass `initial: nil` for create, an existing
/// `Host` for edit. The id is preserved on edit so the navigation
/// state (and saved associations) survive.
struct HostFormView: View {
    let initial: Host?
    let onSave: (Host) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var user: String

    init(
        initial: Host?,
        onSave: @escaping (Host) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initial = initial
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: initial?.name ?? "")
        _host = State(initialValue: initial?.host ?? "")
        _port = State(initialValue: String(initial?.port ?? 22))
        _user = State(initialValue: initial?.user ?? "")
    }

    private var canSave: Bool {
        !host.isEmpty && !user.isEmpty && Int(port) != nil
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
                        user: user
                    )
                    onSave(saved)
                }
                .disabled(!canSave)
            }
        }
    }
}
