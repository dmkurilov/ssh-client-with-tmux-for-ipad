import Foundation
import Observation
import SSHCore

/// Bridges between the SSH layer's async `KnownHostsVerifier.Prompter`
/// callback and the SwiftUI sheet that asks the user to trust or
/// reject. Held as `@State` on the top-level view so it survives
/// navigation pushes.
@MainActor
@Observable
final class TOFUCoordinator {
    var pendingPrompt: KnownHostsPrompt?

    @ObservationIgnored
    private var continuation: CheckedContinuation<KnownHostsDecision, Never>?

    /// Awaitable version of "show this prompt and wait for a
    /// decision". Use as the `prompter` for `KnownHostsVerifier`.
    func awaitDecision(for prompt: KnownHostsPrompt) async -> KnownHostsDecision {
        await withCheckedContinuation { cont in
            // Defensive: if a prior prompt was somehow still pending,
            // reject it before taking over the slot. Two prompts
            // racing is an app bug, not a normal flow.
            if let existing = continuation {
                existing.resume(returning: .reject)
            }
            continuation = cont
            pendingPrompt = prompt
        }
    }

    /// Called by the SwiftUI sheet's button handlers.
    func resolve(_ decision: KnownHostsDecision) {
        let cont = continuation
        continuation = nil
        pendingPrompt = nil
        cont?.resume(returning: decision)
    }
}
