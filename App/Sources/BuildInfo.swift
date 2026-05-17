import Foundation

/// Hand-bumped build signature so the user can confirm a code
/// change actually made it from the working repo to their device.
/// Update on every meaningful change; the value shows up in the
/// app's main Settings sheet.
///
/// Format: `<date> <time> — <one-line tag>`. Time is wall clock
/// of when the change was authored.
enum BuildInfo {
    static let signature = "2026-05-14c — soft keyboard removed; HW keys only (custom keyboard returns later)"
}
