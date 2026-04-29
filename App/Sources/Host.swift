import Foundation

/// One saved SSH host. UUID-keyed so renames don't break navigation.
struct Host: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var user: String
    /// Most recent tmux session name attached on this host. Used to
    /// skip the picker on subsequent connects when the session still
    /// exists. Optional in JSON for back-compat with older host files.
    var lastTmuxSession: String?

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        user: String,
        lastTmuxSession: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.lastTmuxSession = lastTmuxSession
    }
}
