import Foundation

/// Loads `config.json` and `private-key` from the app bundle, where
/// they're placed by a post-build script that copies them in from
/// `~/.ssh-client-tmux-smoke/` on the developer's Mac. Returns `nil`
/// from `shared` if the user hasn't placed the files yet; the UI
/// shows an explanatory message and the SSH smoke test is disabled.
struct SmokeTestConfig: Decodable {
    let host: String
    let port: Int
    let user: String

    static let shared: SmokeTestConfig? = loadConfig()
    static let privateKeyData: Data? = loadPrivateKey()

    static var isReady: Bool { shared != nil && privateKeyData != nil }

    private static func loadConfig() -> SmokeTestConfig? {
        guard let url = Bundle.main.url(forResource: "config", withExtension: "json") else {
            print("[SmokeTestConfig] config.json not in bundle — see ~/.ssh-client-tmux-smoke/")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(SmokeTestConfig.self, from: data)
        } catch {
            print("[SmokeTestConfig] failed to decode config.json: \(error)")
            return nil
        }
    }

    private static func loadPrivateKey() -> Data? {
        guard let url = Bundle.main.url(forResource: "private-key", withExtension: nil) else {
            print("[SmokeTestConfig] private-key not in bundle — see ~/.ssh-client-tmux-smoke/")
            return nil
        }
        return try? Data(contentsOf: url)
    }
}
