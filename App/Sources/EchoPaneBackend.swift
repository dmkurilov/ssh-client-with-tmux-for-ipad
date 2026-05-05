#if canImport(UIKit)
import Foundation
import TerminalKit

/// Pane backend that echoes everything you send back to the driver
/// after a delay. Used by `FakeSessionBackend` for development,
/// SwiftUI previews, and tests so we can iterate on UI without a
/// live remote.
///
/// The echo runs on its own `Task`; cancelling the pane (deinit)
/// cancels in-flight echoes so a closed pane doesn't keep "typing"
/// after the fact.
@MainActor
final class EchoPaneBackend: PaneBackend {
    let id: Int
    let driver: TerminalDriver
    let echoDelay: Duration
    private var pendingTasks: [Task<Void, Never>] = []

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

    // No `deinit`: `Task { [weak self] }` already drops cleanly when
    // the pane is released, and `FileLogger.shared` is `@MainActor`-
    // isolated so it isn't reachable from deinit anyway.

    func send(_ data: Data) async {
        FileLogger.shared.log("EchoPane[%\(id)].send \(data.count)B")
        let echoed = data
        let id = self.id
        let delay = echoDelay
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.driver.feed(echoed)
            FileLogger.shared.log("EchoPane[%\(id)].echo \(echoed.count)B")
        }
        pendingTasks.append(task)
    }

    func resize(cols: Int, rows: Int) async {
        FileLogger.shared.log("EchoPane[%\(id)].resize \(cols)x\(rows)")
    }
}
#endif
