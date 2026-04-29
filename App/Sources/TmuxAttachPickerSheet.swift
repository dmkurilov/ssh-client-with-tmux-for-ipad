import SwiftUI

/// Pre-attach picker: shown when there's no remembered tmux session
/// (or the remembered one no longer exists). User picks an existing
/// session to attach to, or creates a new one with a name.
///
/// All the heavy lifting (sending `tmux -CC attach`/`new-session`)
/// happens in the caller — this view is purely UI + choice.
struct TmuxAttachPickerSheet: View {
    let sessions: [TmuxSessionInfo]
    let onAttach: (String) -> Void          // existing session name
    let onCreate: (String?) -> Void         // nil → tmux picks a name
    let onCancel: () -> Void

    @State private var creating = false
    @State private var newName: String = ""

    var body: some View {
        NavigationStack {
            List {
                if !sessions.isEmpty {
                    Section("Existing") {
                        ForEach(sessions) { s in
                            Button {
                                onAttach(s.name)
                            } label: {
                                row(s)
                            }
                        }
                    }
                }
                Section("New") {
                    if creating {
                        HStack {
                            TextField("session name (optional)", text: $newName)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.go)
                                .onSubmit { submitNew() }
                            Button("Create") { submitNew() }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        Button {
                            creating = true
                            newName = defaultNewName
                        } label: {
                            Label("New session", systemImage: "plus.rectangle")
                        }
                    }
                }
            }
            .navigationTitle("Attach to tmux")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    private func row(_ s: TmuxSessionInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name)
                    .font(.body.weight(.medium))
                Text("\(s.windowCount) window\(s.windowCount == 1 ? "" : "s")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if s.attached {
                Text("attached")
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private func submitNew() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(trimmed.isEmpty ? nil : trimmed)
    }

    /// Pick the first unused `ipad-N` so multi-create doesn't collide.
    private var defaultNewName: String {
        let existing = Set(sessions.map(\.name))
        for n in 1...99 where !existing.contains("ipad-\(n)") {
            return "ipad-\(n)"
        }
        return "ipad-\(Int.random(in: 100...9999))"
    }
}
