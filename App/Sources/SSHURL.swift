import Foundation

/// Parsed components of an `ssh://[user@]host[:port][/...]` URL —
/// what we get when iOS hands us a URL via `onOpenURL`.
struct SSHURL: Equatable {
    let user: String?
    let host: String
    let port: Int?

    static func parse(_ url: URL) -> SSHURL? {
        guard url.scheme?.lowercased() == "ssh" else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let host = comps?.host, !host.isEmpty else { return nil }
        return SSHURL(
            user: comps?.user,
            host: host,
            port: comps?.port
        )
    }
}
