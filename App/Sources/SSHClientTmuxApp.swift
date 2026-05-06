import SwiftUI

@main
struct SSHClientTmuxApp: App {
    init() {
        _ = HardwareKeyboardObserver.shared
        // Build-version stamp at the top of every debug.log run —
        // gated on the user's consent toggle so the file stays
        // empty until they explicitly opt in. Lets future bug
        // reports match logs to a specific build.
        FileLogger.shared.log("Build: \(BuildInfo.signature)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
