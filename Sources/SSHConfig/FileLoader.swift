import Foundation

public protocol FileLoader: Sendable {
    /// Resolve an `Include` pattern (with optional `~/` expansion and glob
    /// wildcards `*`/`?` per path component) to a deterministic, sorted
    /// list of URLs.
    func resolveIncludes(pattern: String, relativeTo base: URL?) throws -> [URL]

    /// Read the contents of a file referenced by a resolved URL.
    func read(_ url: URL) throws -> String
}

public struct DiskFileLoader: FileLoader {
    private let homeDirectory: URL

    public init(homeDirectory: URL? = nil) {
        self.homeDirectory = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private var fileManager: FileManager { .default }

    public func resolveIncludes(pattern: String, relativeTo base: URL?) throws -> [URL] {
        let expanded = expandTilde(pattern)
        let isAbsolute = expanded.hasPrefix("/")

        let anchor: URL
        if isAbsolute {
            anchor = URL(fileURLWithPath: "/")
        } else if let base = base {
            anchor = base.deletingLastPathComponent()
        } else {
            anchor = homeDirectory.appendingPathComponent(".ssh")
        }

        let relativePattern = isAbsolute ? String(expanded.dropFirst()) : expanded
        let components = relativePattern.split(separator: "/").map(String.init)
        let matches = try expand(components: components, startingAt: anchor)
        return matches.sorted { $0.path < $1.path }
    }

    public func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func expandTilde(_ p: String) -> String {
        if p == "~" { return homeDirectory.path }
        if p.hasPrefix("~/") { return homeDirectory.path + String(p.dropFirst()) }
        return p
    }

    private func expand(components: [String], startingAt root: URL) throws -> [URL] {
        var current: [URL] = [root]
        for (idx, comp) in components.enumerated() {
            let isLast = (idx == components.count - 1)
            if comp.contains("*") || comp.contains("?") {
                var next: [URL] = []
                for dir in current {
                    guard let children = try? fileManager.contentsOfDirectory(
                        at: dir,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }
                    for child in children {
                        let name = child.lastPathComponent
                        if Pattern.glob(pattern: comp, candidate: name) {
                            if isLast || isDirectory(child) {
                                next.append(child)
                            }
                        }
                    }
                }
                current = next
            } else {
                current = current.map { $0.appendingPathComponent(comp) }
            }
        }
        return current.filter { fileManager.fileExists(atPath: $0.path) }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

