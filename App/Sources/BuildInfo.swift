import Foundation

/// Hand-bumped build signature so the user can confirm a code
/// change actually made it from the working repo to their device.
/// Update on every meaningful change; the value shows up in the
/// app's main Settings sheet.
///
/// Format: `<date> <time> — <one-line tag>`. Time is wall clock
/// of when the change was authored.
enum BuildInfo {
    static let signature = "2026-05-06 — nav-blink-v12 + isolate-SwiftTerm"
}
