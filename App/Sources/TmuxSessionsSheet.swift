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
                    Button {
                        Task { await switchTo(s.id) }
                    } label: {
                        sessionRow(s)
                    }
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
    static func parse(_ line: String) -> TmuxSessionInfo? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return nil }
        let rawID = parts[0]
        guard rawID.first == "$", let id = Int(rawID.dropFirst()) else { return nil }
        let name = String(parts[1])
        let windowCount = Int(parts[2]) ?? 0
        let attached = parts[3] == "1"
        return TmuxSessionInfo(id: id, name: name, windowCount: windowCount, attached: attached)
    }
}
