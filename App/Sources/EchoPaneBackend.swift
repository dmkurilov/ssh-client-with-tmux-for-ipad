#if canImport(UIKit)
import Foundation
import TerminalKit

/// Pane backend that echoes everything you send back to the driver
/// after a delay. Used by `FakeSessionBackend` for development,
/// SwiftUI previews, and tests so we can iterate on UI without a
/// live remote.
///
/// Each echo runs on a fire-and-forget `Task` with a `[weak self]`
/// capture, so when the pane is released the queued echoes become
/// no-ops once their sleep elapses. We don't track the tasks (an
/// earlier version did but only appended, never pruned — that
/// turned every keystroke into a permanent Task reference for the
/// pane's lifetime).
@MainActor
final class EchoPaneBackend: PaneBackend {
    let id: Int
    let driver: TerminalDriver
    let echoDelay: Duration

    init(id: Int, echoDelay: Duration = .seconds(1)) {
        self.id = id
        self.driver = TerminalDriver()
        self.echoDelay = echoDelay
        FileLogger.shared.log("EchoPane[%\(id)] created (delay=\(echoDelay))")
        // Print a banner so a freshly mounted pane has *something*
        // visible before the user types anything.
        let banner = "\u{1B}[36m[demo pane %\(id)]\u{1B}[0m type something — echoes after \(echoDelay)\r\n"
        driver.feed(Data(banner.utf8))
    }

    func send(_ data: Data) async {
        FileLogger.shared.log("EchoPane[%\(id)].send \(data.count)B")
        // Translate CR → CRLF on echo. Enter sends `0x0D`; in a
        // real shell, line discipline (or the shell itself) echoes
        // back `\r\n` so the cursor advances to the next line.
        // Without this, hitting Enter just returns the cursor to
        // the start of the same line.
        let echoed = Self.expandCarriageReturns(data)
        let id = self.id
        let delay = echoDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.driver.feed(echoed)
            FileLogger.shared.log("EchoPane[%\(id)].echo \(echoed.count)B")
        }
    }

    private static func expandCarriageReturns(_ data: Data) -> Data {
        guard data.contains(0x0D) else { return data }
        var out = Data()
        out.reserveCapacity(data.count + 1)
        for byte in data {
            out.append(byte)
            if byte == 0x0D {
                out.append(0x0A)
            }
        }
        return out
    }

    func resize(cols: Int, rows: Int) async {
        FileLogger.shared.log("EchoPane[%\(id)].resize \(cols)x\(rows)")
    }
}
#endif
