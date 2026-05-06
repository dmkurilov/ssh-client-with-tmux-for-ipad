import Foundation
import Observation

/// Opt-in append-only debug log. When `enabled`, every
/// `session.logDebug` call also lands in `Documents/debug.log` so we
/// can ship traces home for analysis. Off by default — the in-memory
/// overlay (the ladybug toggle inside a tmux view) keeps working
/// regardless because it lives in `TmuxSession.debugLog`.
@MainActor
@Observable
final class FileLogger {
    static let shared = FileLogger()

    let url: URL
    private let formatter: DateFormatter

    private static let enabledKey = "DebugLogEnabled"

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            RecordingConsent.shared.reconcile()
        }
    }

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
        self.enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func log(_ message: String) {
        guard enabled else { return }
        writeLine("[\(formatter.string(from: Date()))] \(message)\n")
    }

    /// Bypass the `enabled` toggle. Reserved for diagnostics where
    /// we need evidence even when the user hasn't (yet) flipped the
    /// switch — e.g. proving a hotkey actually fires. Use sparingly;
    /// the toggle exists for a reason (privacy of pane content).
    func forceLog(_ message: String) {
        writeLine("[\(formatter.string(from: Date()))] [FORCE] \(message)\n")
    }

    private func writeLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
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
