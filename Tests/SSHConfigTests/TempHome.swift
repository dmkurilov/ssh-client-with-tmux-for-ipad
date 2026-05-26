import Foundation
@testable import SSHConfig

/// A unique temporary directory used as a synthetic home for `DiskFileLoader`
/// in tests. Files written through `write(_:to:)` are placed under this root;
/// the entire tree is cleaned up in `deinit`.
final class TempHome {
    let url: URL

    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sshconfig-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ content: String, to relativePath: String) throws -> URL {
        let dest = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: dest, atomically: true, encoding: .utf8)
        return dest
    }

    /// A `DiskFileLoader` rooted at this temp dir, so `~/` and bare relative
    /// includes resolve inside it.
    var loader: DiskFileLoader {
        DiskFileLoader(homeDirectory: url)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
