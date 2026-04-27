import Foundation

/// Per-test temp directory; auto-cleans on `deinit`. Same shape as
/// the helper in SSHConfigTests, kept independent so each module's
/// tests stand alone.
final class TempHome {
    let url: URL

    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("known-hosts-tests-\(UUID().uuidString)", isDirectory: true)
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

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
