import SwiftUI

/// Pre-attach picker: shown when there's no remembered tmux session
/// (or the remembered one no longer exists). User picks an existing
/// session to attach to, or creates a new one with a name.
///
/// All the heavy lifting (sending `tmux -CC attach`/`new-session`)
/// happens in the caller — this view is purely UI + choice.
struct TmuxAttachPickerSheet: View {
    let sessions: [TmuxSessionInfo]
    let onAttach: (_ name: String, _ forceDetach: Bool) -> Void
    let onCreate: (String?) -> Void         // nil → tmux picks a name
    let onRename: (_ oldName: String, _ newName: String) -> Void
    let onCancel: () -> Void

    @State private var creating = false
    @State private var newName: String = ""
    @State private var detachConfirmFor: TmuxSessionInfo?
    @State private var renamingSession: TmuxSessionInfo?
    @State private var renameText: String = ""

    var body: some View {
        NavigationStack {
            List {
                if !sessions.isEmpty {
                    Section("Existing") {
                        ForEach(sessions) { s in
                            row(s)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if s.attached {
                                        detachConfirmFor = s
                                    } else {
                                        onAttach(s.name, false)
                                    }
                                }
                                .onLongPressGesture { beginRename(s) }
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
            .alert(
                "Session is attached elsewhere",
                isPresented: Binding(
                    get: { detachConfirmFor != nil },
                    set: { if !$0 { detachConfirmFor = nil } }
                ),
                presenting: detachConfirmFor
            ) { target in
                Button("Force detach", role: .destructive) {
                    let name = target.name
                    detachConfirmFor = nil
                    onAttach(name, true)
                }
                Button("Attach without detaching", role: .none) {
                    let name = target.name
                    detachConfirmFor = nil
                    onAttach(name, false)
                }
                Button("Cancel", role: .cancel) {
                    detachConfirmFor = nil
                }
            } message: { target in
                Text("'\(target.name)' is attached by another client. Force-detaching gives this device the session at iPad size; attaching without detaching shares the session and forces both clients to the smaller terminal size.")
            }
            .alert(
                renamingSession.map { "Rename session $\($0.id)" } ?? "Rename session",
                isPresented: Binding(
                    get: { renamingSession != nil },
                    set: { if !$0 { renamingSession = nil; renameText = "" } }
                )
            ) {
                TextField("Name", text: $renameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {
                    renamingSession = nil
                    renameText = ""
                }
                Button("Rename", action: commitRename)
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
            Button {
                beginRename(s)
            } label: {
                Image(systemName: "pencil")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }

    private func beginRename(_ s: TmuxSessionInfo) {
        renameText = s.name
        renamingSession = s
    }

    private func commitRename() {
        guard let s = renamingSession else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingSession = nil
        renameText = ""
        guard !trimmed.isEmpty, trimmed != s.name else { return }
        onRename(s.name, trimmed)
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
