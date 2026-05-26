import Foundation
import Observation

/// Single source of truth for "when was the last time the user
/// agreed to record stuff." Both `FileLogger.enabled` and
/// `TranscriptStore.enabled` share this timestamp — flip either one
/// on for the first time and the consent timer starts; flip both
/// off and the timer is cleared. Extending consent (via the
/// re-consent sheet) resets the same shared timestamp.
@MainActor
@Observable
final class RecordingConsent {
    static let shared = RecordingConsent()

    private static let key = "RecordingConsentGrantedAt"

    /// `nil` means no recording is on, or the user hasn't started
    /// recording yet. A non-nil `Date` is when consent was last
    /// granted or refreshed.
    var grantedAt: Date? {
        didSet {
            if let date = grantedAt {
                UserDefaults.standard.set(date, forKey: Self.key)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.key)
            }
        }
    }

    /// UI flag — observed by both the root scene and the Settings
    /// sheet so the re-consent prompt can come up regardless of
    /// which one is foreground when consent expires. Set by the
    /// 5-second poll in `ContentView`, cleared on Apply / dismiss.
    var pendingPrompt: Bool = false

    private init() {
        self.grantedAt = UserDefaults.standard.object(forKey: Self.key) as? Date
    }

    /// Called by `FileLogger`/`TranscriptStore` after their `enabled`
    /// state changes. Idempotent — safe to call from any toggle path.
    func reconcile() {
        let anyEnabled = FileLogger.shared.enabled || TranscriptStore.shared.enabled
        if anyEnabled, grantedAt == nil {
            grantedAt = Date()
        } else if !anyEnabled {
            grantedAt = nil
        }
    }

    /// Refresh the timer: user explicitly chose to keep recording on
    /// the re-consent sheet.
    func extend() {
        grantedAt = Date()
    }

    /// Whether consent is past the `staleAfter` window AND at least
    /// one recording is still on.
    func isStale(staleAfter: TimeInterval, now: Date = Date()) -> Bool {
        guard let granted = grantedAt,
              FileLogger.shared.enabled || TranscriptStore.shared.enabled
        else { return false }
        return now.timeIntervalSince(granted) > staleAfter
    }
}
