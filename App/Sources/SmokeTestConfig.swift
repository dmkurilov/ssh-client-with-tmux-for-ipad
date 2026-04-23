import Foundation

/// Loads `config.json` and `private-key` from `App/Resources/SmokeTest/`.
struct SmokeTestConfig: Decodable {
    let host: String
    let port: Int
    let user: String

    static let shared: SmokeTestConfig? = loadConfig()
    static let privateKeyData: Data? = loadPrivateKey()

    static var isReady: Bool { shared != nil && privateKeyData != nil }

    private static func loadConfig() -> SmokeTestConfig? {
        dumpBundleDiagnostics()  // runs once

        guard let url = resolveResource(named: "config.json") else {
            print("[SmokeTestConfig] ✗ config.json NOT FOUND")
            return nil
        }
        print("[SmokeTestConfig] ✓ config.json at \(url.path)")
        do {
            return try JSONDecoder().decode(
                SmokeTestConfig.self,
                from: try Data(contentsOf: url)
            )
        } catch {
            print("[SmokeTestConfig] ✗ decode failed: \(error)")
            return nil
        }
    }

    private static func loadPrivateKey() -> Data? {
        guard let url = resolveResource(named: "private-key") else {
            print("[SmokeTestConfig] ✗ private-key NOT FOUND")
            return nil
        }
        print("[SmokeTestConfig] ✓ private-key at \(url.path)")
        return try? Data(contentsOf: url)
    }

    private static func resolveResource(named filename: String) -> URL? {
        let bundle = Bundle.main
        let split = filename.split(separator: ".", maxSplits: 1)
        let name = String(split[0])
        let ext: String? = split.count == 2 ? String(split[1]) : nil

        let attempts: [(String, () -> URL?)] = [
            ("url(forResource:\(name), withExtension:\(ext ?? "nil"), subdirectory:SmokeTest)",
             { bundle.url(forResource: name, withExtension: ext, subdirectory: "SmokeTest") }),
            ("url(forResource:\(name), withExtension:\(ext ?? "nil"))",
             { bundle.url(forResource: name, withExtension: ext) }),
            ("resourceURL/SmokeTest/\(filename)",
             { bundle.resourceURL?.appendingPathComponent("SmokeTest/\(filename)") }),
            ("resourceURL/\(filename)",
             { bundle.resourceURL?.appendingPathComponent(filename) }),
            ("bundleURL/SmokeTest/\(filename)",
             { bundle.bundleURL.appendingPathComponent("SmokeTest/\(filename)") }),
            ("bundleURL/\(filename)",
             { bundle.bundleURL.appendingPathComponent(filename) }),
        ]

        for (description, probe) in attempts {
            if let url = probe() {
                let exists = FileManager.default.fileExists(atPath: url.path)
                print("[SmokeTestConfig]   try \(description): \(exists ? "EXISTS" : "-") [\(url.path)]")
                if exists { return url }
            } else {
                print("[SmokeTestConfig]   try \(description): returned nil")
            }
        }
        return nil
    }

    private static var hasDumped = false
    private static func dumpBundleDiagnostics() {
        guard !hasDumped else { return }
        hasDumped = true

        print("[SmokeTestConfig] ─── bundle diagnostics ───")
        print("[SmokeTestConfig] bundlePath:   \(Bundle.main.bundlePath)")
        print("[SmokeTestConfig] bundleURL:    \(Bundle.main.bundleURL.path)")
        print("[SmokeTestConfig] resourcePath: \(Bundle.main.resourcePath ?? "nil")")
        print("[SmokeTestConfig] resourceURL:  \(Bundle.main.resourceURL?.path ?? "nil")")

        // Try a few targeted Bundle APIs.
        let jsons = Bundle.main.paths(forResourcesOfType: "json", inDirectory: nil)
        print("[SmokeTestConfig] paths(forResourcesOfType:json): \(jsons)")
        let jsonsInSub = Bundle.main.paths(forResourcesOfType: "json", inDirectory: "SmokeTest")
        print("[SmokeTestConfig] paths(forResourcesOfType:json, inDir:SmokeTest): \(jsonsInSub)")

        // Full recursive tree of the bundle (depth-limited, skipping enormous NIO dylibs).
        if let root = Bundle.main.resourceURL {
            print("[SmokeTestConfig] recursive listing of \(root.lastPathComponent):")
            walk(root, prefix: "  ", depth: 0, maxDepth: 4)
        }
        print("[SmokeTestConfig] ────────────────────────")
    }

    private static func walk(_ url: URL, prefix: String, depth: Int, maxDepth: Int) {
        guard depth <= maxDepth else {
            print("\(prefix)… (depth limit)")
            return
        }
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            print("\(prefix)<list error: \(error)>")
            return
        }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            print("\(prefix)\(entry.lastPathComponent)\(isDir ? "/" : "")")
            if isDir {
                // Skip the big SPM/NIO bundles to keep the log readable.
                let name = entry.lastPathComponent
                if name.hasPrefix("swift-crypto_") || name.hasPrefix("swift-nio_") {
                    print("\(prefix)  …(skipped)")
                    continue
                }
                walk(entry, prefix: prefix + "  ", depth: depth + 1, maxDepth: maxDepth)
            }
        }
    }
}
