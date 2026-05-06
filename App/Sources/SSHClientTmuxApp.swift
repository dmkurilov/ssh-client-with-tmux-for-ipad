import SwiftUI

@main
struct SSHClientTmuxApp: App {
    init() {
        _ = HardwareKeyboardObserver.shared
        // forceLog: writes regardless of toggle (diagnostic only).
        FileLogger.shared.forceLog("App launched, build=\(BuildInfo.signature)")
        // Regular log: writes only when consent / toggle is on, so
        // the user sees the build-version in their normal logs and
        // can match a debug.log to a specific build.
        FileLogger.shared.log("Build: \(BuildInfo.signature)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
