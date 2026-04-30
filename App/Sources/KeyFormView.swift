import SwiftUI
import SSHCore

/// Sheet used to add a new SSH key. Two modes:
///   - **Generate**: in-app Ed25519. After save we show the OpenSSH
///     public key for the user to paste into a remote `authorized_keys`.
///   - **Paste**: the user pastes an existing OpenSSH PEM private key
///     (the same format `ssh-keygen` writes by default).
struct KeyFormView: View {
    let store: KeyStore
    let onDone: () -> Void

    @State private var mode: Mode = .generate
    @State private var name: String = ""
    @State private var pastedPrivateKey: String = ""
    @State private var generatedPublicKey: String?
    @State private var errorMessage: String?

    enum Mode: String, CaseIterable, Identifiable {
        case generate = "Generate"
        case paste = "Paste"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Key name") {
                    TextField("e.g. work-laptop", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if mode == .paste {
                    Section("Private key (OpenSSH PEM)") {
                        TextEditor(text: $pastedPrivateKey)
                            .font(.caption.monospaced())
                            .frame(minHeight: 180)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }

                if let pub = generatedPublicKey {
                    Section("Public key (paste into authorized_keys)") {
                        Text(pub)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        ShareLink(item: pub) {
                            Label("Share public key", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New SSH key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDone)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .generate ? "Generate" : "Save", action: save)
                        .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        switch mode {
        case .generate:
            return generatedPublicKey == nil   // not yet saved
        case .paste:
            return !pastedPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch mode {
            case .generate:
                let gen = SSHKeyGenerator.generateEd25519(comment: trimmed)
                let meta = KeyMetadata(
                    name: trimmed,
                    format: .ed25519Raw,
                    publicKeyOpenSSH: gen.openSSHPublicKey
                )
                try store.add(meta, data: gen.rawPrivateKey)
                generatedPublicKey = gen.openSSHPublicKey
                // Stay on the sheet so the user can copy the public key.
            case .paste:
                let pem = pastedPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)
                let meta = KeyMetadata(
                    name: trimmed,
                    format: .openSSHPEM,
                    publicKeyOpenSSH: nil
                )
                try store.add(meta, data: Data(pem.utf8))
                onDone()
            }
        } catch {
            errorMessage = "save failed: \(error)"
        }
    }
}
