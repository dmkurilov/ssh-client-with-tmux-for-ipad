import SwiftUI
import SSHCore

/// Sheet UI for an unknown-host (TOFU) or mismatch host-key prompt.
struct TOFUPromptSheet: View {
    let prompt: KnownHostsPrompt
    let onResolve: (KnownHostsDecision) -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch prompt {
            case let .unknown(host, port, keyType, fingerprint):
                unknownBody(host: host, port: port, keyType: keyType, fingerprint: fingerprint)
            case let .mismatch(host, port, keyType, newFp, oldFp):
                mismatchBody(
                    host: host,
                    port: port,
                    keyType: keyType,
                    newFingerprint: newFp,
                    existingFingerprint: oldFp
                )
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private func unknownBody(host: String, port: Int, keyType: String, fingerprint: String) -> some View {
        Text("First-time connection")
            .font(.title2.weight(.semibold))

        hostBlock(host: host, port: port, keyType: keyType)

        labelledMono(label: "fingerprint", value: fingerprint)

        Text("Trust this host's identity? You won't be asked again unless its key changes.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

        HStack(spacing: 12) {
            Button("Reject") { onResolve(.reject) }
                .buttonStyle(.bordered)
            Button("Trust") { onResolve(.accept) }
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func mismatchBody(
        host: String,
        port: Int,
        keyType: String,
        newFingerprint: String,
        existingFingerprint: String
    ) -> some View {
        Text("⚠️ Host key changed")
            .font(.title2.weight(.semibold))
            .foregroundStyle(.red)

        Text("This may be a man-in-the-middle attack. Only proceed if you're sure the server's key was rotated for a legitimate reason.")
            .font(.callout)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)

        hostBlock(host: host, port: port, keyType: keyType)

        labelledMono(label: "stored fingerprint", value: existingFingerprint)
        labelledMono(label: "new fingerprint", value: newFingerprint)

        HStack(spacing: 12) {
            Button("Reject") { onResolve(.reject) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            Button("Replace anyway") { onResolve(.accept) }
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func hostBlock(host: String, port: Int, keyType: String) -> some View {
        VStack(spacing: 4) {
            Text("\(host):\(port)")
                .font(.body.monospaced())
            Text("key type: \(keyType)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func labelledMono(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .multilineTextAlignment(.center)
        }
    }
}
