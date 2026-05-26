import Foundation
import SSHConfig

/// Parses an `ssh_config` text into Host records (and reasons for the
/// ones we can't import). Pure logic — the SwiftUI side calls this
/// once it has the file contents from the document picker.
enum SSHConfigImporter {

    /// One row in the preview list.
    ///
    /// `skipReason` is only set for things we truly can't translate
    /// (wildcard patterns). Everything else is imported best-effort:
    /// supported directives populate the `Host`, unsupported ones are
    /// listed in `ignoredDirectives` so the user can see what was
    /// dropped and reconfigure manually.
    struct ParsedHost: Identifiable, Hashable {
        let id = UUID()
        let pattern: String           // the literal pattern from `Host …`
        let host: Host?               // nil if `skipReason != nil`
        let identityFile: String?     // informational; not auto-linked
        let ignoredDirectives: [String]   // e.g. ["ProxyJump", "LocalForward"]
        let skipReason: String?
    }

    /// Directives that we can't reasonably reproduce yet. We still
    /// import the host (best-effort), but surface these so the user
    /// knows what was dropped on the floor.
    private static let unsupportedKeywords: Set<String> = [
        "proxyjump",
        "proxycommand",
        "localforward",
        "remoteforward",
        "dynamicforward",
        "controlmaster",
        "controlpath",
        "controlpersist",
        "tunnel",
        "forwardagent",
        "forwardx11",
        "bindaddress",
        "bindinterface",
    ]

    static func parse(text: String) throws -> [ParsedHost] {
        let config = try SSHConfig(text: text)
        var result: [ParsedHost] = []
        for block in config.blocks {
            guard case .host(let patterns, let directives, _) = block else { continue }
            // A `Host` block can list several patterns (`Host foo bar`);
            // each becomes its own row so the user can see what would
            // land in the host list.
            for hp in patterns where !hp.negated {
                result.append(buildRow(pattern: hp.pattern, directives: directives))
            }
        }
        return result
    }

    private static func buildRow(pattern: String, directives: [Directive]) -> ParsedHost {
        // ssh_config patterns with glob chars are wildcard rules
        // (e.g. `Host *.example.com`) — they don't represent a
        // single host record, so we skip them.
        if pattern.contains(where: { "*?[".contains($0) }) {
            return ParsedHost(
                pattern: pattern,
                host: nil,
                identityFile: nil,
                ignoredDirectives: [],
                skipReason: "wildcard pattern"
            )
        }

        var hostName = pattern
        var port = 22
        var user = ""
        var identityFile: String?
        var ignored: [String] = []

        for d in directives {
            switch d.normalizedKeyword {
            case "hostname":
                if let v = d.arguments.first { hostName = v }
            case "port":
                if let raw = d.arguments.first, let p = Int(raw) { port = p }
            case "user":
                if let v = d.arguments.first { user = v }
            case "identityfile":
                identityFile = d.arguments.first
            default:
                if unsupportedKeywords.contains(d.normalizedKeyword) {
                    if !ignored.contains(d.keyword) {
                        ignored.append(d.keyword)
                    }
                }
            }
        }

        // Best-effort: missing User just stays empty — the form
        // shows it, the user can fill it in via Edit if needed.
        let host = Host(
            name: pattern,
            host: hostName,
            port: port,
            user: user
        )
        return ParsedHost(
            pattern: pattern,
            host: host,
            identityFile: identityFile,
            ignoredDirectives: ignored,
            skipReason: nil
        )
    }
}
