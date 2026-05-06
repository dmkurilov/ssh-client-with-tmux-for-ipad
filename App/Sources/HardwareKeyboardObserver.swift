#if canImport(UIKit)
import Foundation
import GameController
import Observation

/// Observes whether any hardware keyboard (Magic Keyboard, Smart
/// Keyboard Folio, BT, USB-C) is currently attached. Drives the
/// "auto" branch of the keyboard mode picker (see
/// `docs/05-ui-vision.md` §4.3 and `project_decision_keyboard_modes`).
///
/// Singleton because HW state is process-wide; views observe via
/// `@Bindable` (or just by reading `.shared.isAttached` in their
/// body — `@Observable` tracks the access).
@MainActor
@Observable
final class HardwareKeyboardObserver {
    static let shared = HardwareKeyboardObserver()

    /// `true` when at least one HW keyboard is currently attached.
    var isAttached: Bool

    private init() {
        // `GCKeyboard.coalesced` returns a single keyboard object
        // that represents *any* HW keyboard currently attached.
        // Nil ↔ none.
        self.isAttached = GCKeyboard.coalesced != nil
        FileLogger.shared.log("HWKeyboard init isAttached=\(isAttached)")

        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { _ in
            Task { @MainActor in
                Self.shared.isAttached = true
                FileLogger.shared.log("HWKeyboard: connected")
            }
        }
        nc.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { _ in
            Task { @MainActor in
                Self.shared.isAttached = GCKeyboard.coalesced != nil
                FileLogger.shared.log("HWKeyboard: disconnected (now isAttached=\(Self.shared.isAttached))")
            }
        }
    }
}
#endif
