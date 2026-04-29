import Foundation

/// Append-only debug log living in the app's Documents folder so it
/// survives across runs and is reachable from the iOS Files app
/// (under "On My iPad → ssh-client-tmux") and via Xcode's device
/// container browser.
///
/// The file is also exposed by the "Share debug log" button on the
/// host list, which presents the standard share sheet for AirDrop
/// or the Files app.
@MainActor
final class FileLogger {
    static let shared = FileLogger()

    let url: URL
    private let formatter: DateFormatter

    private init() {
        let docs = try! FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        url = docs.appendingPathComponent("debug.log")
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
    }

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Wipe the log. Useful when the user is about to reproduce a
    /// specific bug and wants only the relevant frames.
    func reset() {
        try? "".data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
