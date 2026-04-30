import SwiftUI
import SSHCore

/// Row parsed out of `tmux list-sessions -F '#{session_id}\t…'`.
struct TmuxSessionInfo: Identifiable, Hashable {
    let id: Int               // numeric part of `$<id>`
    let name: String
    let windowCount: Int
    let attached: Bool
}

/// Sheet that asks tmux for its session list, lets the user tap one,
/// and `switch-client`s the existing control connection over to it.
struct TmuxSessionsSheet: View {
    let session: TmuxSession
    let shell: SSHShellSession
    let onDismiss: () -> Void

    @State private var sessions: [TmuxSessionInfo] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var renamingSessionID: Int?
    @State private var renameText: String = ""
    @State private var detachConfirmFor: TmuxSessionInfo?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("tmux sessions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDismiss)
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { Task { await refresh() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(loading)
                    }
                }
                .task { await refresh() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text(errorMessage)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await refresh() } }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(sessions) { s in
                    sessionRow(s)
                        .contentShape(Rectangle())
                        .onTapGesture { handleTap(s) }
                        .onLongPressGesture { beginRename(s) }
                }
            }
            .overlay {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No sessions",
                        systemImage: "rectangle.stack",
                        description: Text("tmux returned an empty list.")
                    )
                }
            }
            .alert(
                renamingSessionID.map { "Rename session $\($0)" } ?? "Rename session",
                isPresented: Binding(
                    get: { renamingSessionID != nil },
                    set: { if !$0 { renamingSessionID = nil; renameText = "" } }
                )
            ) {
                TextField("Name", text: $renameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {
                    renamingSessionID = nil
                    renameText = ""
                }
                Button("Rename") {
                    Task { await commitRename() }
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
                    let id = target.id
                    detachConfirmFor = nil
                    Task { await switchToWithForceDetach(id) }
                }
                Button("Attach without detaching", role: .none) {
                    let id = target.id
                    detachConfirmFor = nil
                    Task { await switchTo(id) }
                }
                Button("Cancel", role: .cancel) {
                    detachConfirmFor = nil
                }
            } message: { target in
                Text("'\(target.name)' is attached by another client. Force-detaching gives this device the session at iPad size; attaching without detaching shares the session and forces both clients to the smaller of the two terminal sizes.")
            }
        }
    }

    /// Tap routing: if the user picks a session that's attached
    /// somewhere else (i.e. not by us — we know our session via
    /// `session.sessionID`), prompt before switching.
    private func handleTap(_ s: TmuxSessionInfo) {
        if s.attached, s.id != session.sessionID {
            detachConfirmFor = s
        } else {
            Task { await switchTo(s.id) }
        }
    }

    private func switchToWithForceDetach(_ sessionID: Int) async {
        do {
            _ = try await session.runCommand(
                "detach-client -s $\(sessionID)\n",
                write: { try await shell.write($0) }
            )
        } catch {
            errorMessage = "detach-client failed: \(error)"
            return
        }
        await switchTo(sessionID)
    }

    private func beginRename(_ s: TmuxSessionInfo) {
        renameText = s.name
        renamingSessionID = s.id
    }

    private func commitRename() async {
        guard let sessionID = renamingSessionID else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingSessionID = nil
        renameText = ""
        guard !trimmed.isEmpty else { return }
        let escaped = "'" + trimmed.replacingOccurrences(of: "'", with: "'\\''") + "'"
        do {
            _ = try await session.runCommand(
                "rename-session -t $\(sessionID) \(escaped)\n",
                write: { try await shell.write($0) }
            )
            await refresh()
        } catch {
            errorMessage = "rename failed: \(error)"
        }
    }

    private func sessionRow(_ s: TmuxSessionInfo) -> some View {
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
            if let current = session.sessionID, current == s.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
            Button {
                beginRename(s)
            } label: {
                Image(systemName: "pencil")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }

    private func refresh() async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        // Tab-separated columns we actually need. `\t` is a tmux
        // format escape, not a Swift one — tmux does the substitution.
        let format = "#{session_id}\t#{session_name}\t#{session_windows}\t#{session_attached}"
        do {
            let lines = try await session.runCommand(
                "list-sessions -F \"\(format)\"\n",
                write: { try await shell.write($0) }
            )
            sessions = lines.compactMap(TmuxSessionInfo.parse)
        } catch {
            errorMessage = "list-sessions failed: \(error)"
        }
    }

    private func switchTo(_ sessionID: Int) async {
        do {
            _ = try await session.runCommand(
                "switch-client -t $\(sessionID)\n",
                write: { try await shell.write($0) }
            )
            onDismiss()
        } catch {
            errorMessage = "switch-client failed: \(error)"
        }
    }
}

extension TmuxSessionInfo {
    /// Parse one tab-separated row from the `list-sessions` response.
    /// Format must match the `-F` argument used in `refresh()`.
    /// `#{session_attached}` is the *count* of attached clients, so we
    /// treat `>0` as attached (the original `== "1"` parse missed
    /// sessions with two or more clients).
    static func parse(_ line: String) -> TmuxSessionInfo? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return nil }
        let rawID = parts[0]
        guard rawID.first == "$", let id = Int(rawID.dropFirst()) else { return nil }
        let name = String(parts[1])
        let windowCount = Int(parts[2]) ?? 0
        let attached = (Int(parts[3]) ?? 0) > 0
        return TmuxSessionInfo(id: id, name: name, windowCount: windowCount, attached: attached)
    }
}
