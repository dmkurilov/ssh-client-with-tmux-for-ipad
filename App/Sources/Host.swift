import Foundation

/// One saved SSH host. UUID-keyed so renames don't break navigation.
struct Host: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var user: String

    init(id: UUID = UUID(), name: String, host: String, port: Int = 22, user: String) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
    }
}
