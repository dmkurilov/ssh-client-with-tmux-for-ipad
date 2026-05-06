import SwiftUI

@main
struct SSHClientTmuxApp: App {
    init() {
        // Touch the HW-keyboard observer at app launch so its
        // `GCKeyboard.coalesced` lookup runs early and the
        // `GCKeyboardDidConnect` notification has time to fire
        // before any view reads `isAttached` for an initial
        // default. Without this, the very first open of the
        // demo terminal saw `isAttached == false` even with HW
        // connected, because GameController hadn't yet dispatched
        // the connect event for the singleton's lazy init.
        _ = HardwareKeyboardObserver.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
