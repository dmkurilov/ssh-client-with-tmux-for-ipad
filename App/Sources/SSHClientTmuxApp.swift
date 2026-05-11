import SwiftUI
import TerminalKit

@main
struct SSHClientTmuxApp: App {
    init() {
        _ = HardwareKeyboardObserver.shared
        // Build-version stamp at the top of every debug.log run —
        // gated on the user's consent toggle so the file stays
        // empty until they explicitly opt in. Lets future bug
        // reports match logs to a specific build.
        FileLogger.shared.log("Build: \(BuildInfo.signature)")
        // Bridge TerminalKit's CellMetrics measurement diagnostic
        // into the shared file logger so the cellW/cellH values we
        // compute show up next to the SwiftTerm `sizeChanged` lines
        // that will (or won't) report a grid MISMATCH afterwards.
        CellMetrics.log = { msg in FileLogger.shared.log(msg) }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
