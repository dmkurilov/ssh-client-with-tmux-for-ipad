import Foundation

/// Single source of truth for where the iPad app keeps its
/// `known_hosts`. Lives in the app's Documents folder so the user
/// can inspect / clear it via the Files app, and so it survives
/// across launches.
enum KnownHostsLocation {
    static let url: URL = {
        let docs = try! FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return docs.appendingPathComponent("known_hosts")
    }()
}
