import Foundation
import Observation

/// In-memory store of saved hosts, persisted as JSON in the app's
/// Documents folder. On first launch with no `hosts.json`, seeds from
/// the bundled smoke-test `config.json` if present, otherwise starts
/// empty.
@MainActor
@Observable
final class HostStore {
    private(set) var hosts: [Host]

    init() {
        if let loaded = try? Self.load() {
            self.hosts = loaded
        } else if let seed = SmokeTestConfig.shared {
            let host = Host(
                name: seed.host,
                host: seed.host,
                port: seed.port,
                user: seed.user
            )
            self.hosts = [host]
            try? Self.save([host])
        } else {
            self.hosts = []
        }
    }

    func add(_ host: Host) {
        hosts.append(host)
        persist()
    }

    func update(_ host: Host) {
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[idx] = host
        persist()
    }

    /// Save the last-attached tmux session name for a host. No-op if
    /// the host is no longer in the store (deleted while connected).
    func updateLastTmuxSession(hostID: UUID, name: String?) {
        guard let idx = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        guard hosts[idx].lastTmuxSession != name else { return }
        hosts[idx].lastTmuxSession = name
        persist()
    }

    func remove(at offsets: IndexSet) {
        hosts.remove(atOffsets: offsets)
        persist()
    }

    func remove(id: UUID) {
        hosts.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        try? Self.save(hosts)
    }

    // MARK: - Disk

    private static var fileURL: URL {
        let docs = try! FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return docs.appendingPathComponent("hosts.json")
    }

    private static func load() throws -> [Host] {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([Host].self, from: data)
    }

    private static func save(_ hosts: [Host]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(hosts)
        try data.write(to: fileURL, options: .atomic)
    }
}
