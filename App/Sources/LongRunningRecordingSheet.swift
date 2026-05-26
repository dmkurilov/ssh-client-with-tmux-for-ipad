import SwiftUI

/// Shown on app foreground (or while running, via the 5s poll) when
/// recording consent has been outstanding for more than `staleAfter`.
/// Lists every recording the user can manage, lets them keep the
/// ones they want, and revokes consent on the rest.
struct LongRunningRecordingSheet: View {
    let onDismiss: () -> Void

    @Bindable private var fileLogger = FileLogger.shared
    @Bindable private var transcripts = TranscriptStore.shared

    /// Default-on for whatever's currently recording — the user
    /// already opted in, we just nudge them to confirm.
    @State private var keepDebugLog: Bool
    @State private var keepTranscripts: Bool

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        _keepDebugLog = State(initialValue: FileLogger.shared.enabled)
        _keepTranscripts = State(initialValue: TranscriptStore.shared.enabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("These recordings have been running for a while. Pick which ones to keep — the rest will be turned off.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if fileLogger.enabled {
                    Section("Debug log") {
                        Toggle("Keep recording", isOn: $keepDebugLog)
                    }
                }

                if transcripts.enabled {
                    Section("Session transcripts") {
                        Toggle("Keep recording", isOn: $keepTranscripts)
                    }
                }

                Section {
                    Button(action: apply) {
                        Text(applyLabel)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Still recording?")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var applyLabel: String {
        let keepingNothing = (!fileLogger.enabled || !keepDebugLog)
            && (!transcripts.enabled || !keepTranscripts)
        return keepingNothing ? "Turn off" : "Apply"
    }

    private func apply() {
        if fileLogger.enabled, !keepDebugLog { fileLogger.enabled = false }
        if transcripts.enabled, !keepTranscripts { transcripts.enabled = false }
        // If anything's still on, the user reaffirmed consent.
        if FileLogger.shared.enabled || TranscriptStore.shared.enabled {
            RecordingConsent.shared.extend()
        }
        onDismiss()
    }

    /// Re-consent window. Currently 1 hour — short enough that we
    /// don't quietly leave recording on for days, long enough that
    /// it doesn't interrupt a normal coding session.
    static let staleAfter: TimeInterval = 60 * 60

    @MainActor
    static func shouldShow(now: Date = Date()) -> Bool {
        RecordingConsent.shared.isStale(staleAfter: staleAfter, now: now)
    }
}

/// Format `secondsRemaining` for display. Caller is responsible for
/// handling the expired-or-zero case before calling this — we only
/// format positive durations.
func formatExpiry(_ secondsRemaining: TimeInterval) -> String {
    let total = Int(max(0, secondsRemaining))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%dh %dm %ds", h, m, s) }
    if m > 0 { return String(format: "%dm %ds", m, s) }
    return String(format: "%ds", s)
}
