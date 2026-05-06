import SwiftUI

/// Slim accessory bar for terminal panes. Replaces SwiftTerm's
/// stock `TerminalAccessory` and our earlier UIKit
/// `TerminalAccessoryBar` (which docked via `inputAccessoryView`
/// but rendered as an invisible grey strip on iPad — see the
/// keyboard saga in `docs/05-ui-vision.md` §4).
///
/// Now a plain SwiftUI sibling: the parent puts it at the bottom
/// of the view tree and SwiftUI's keyboard avoidance pushes it up
/// when the SW keyboard appears. iOS's input system isn't involved.
///
/// Bytes are dispatched via `onKey` — the parent wires that to
/// the same `onInput` path that SwiftTerm's natural typing uses,
/// so accessory keys round-trip to the remote indistinguishably
/// from real keystrokes.
struct AccessoryBar: View {
    var onKey: (Data) -> Void

    /// Keys per `docs/05-ui-vision.md` §4.1. F-keys deliberately
    /// excluded; sticky `Ctrl` modifier is a future TODO. Tmux
    /// prefix is hard-coded to `Ctrl-B` for now (also a TODO to
    /// make configurable).
    private static let keys: [(label: String, bytes: [UInt8])] = [
        ("esc",  [0x1B]),
        ("tab",  [0x09]),
        ("←",    [0x1B, 0x5B, 0x44]),
        ("↑",    [0x1B, 0x5B, 0x41]),
        ("↓",    [0x1B, 0x5B, 0x42]),
        ("→",    [0x1B, 0x5B, 0x43]),
        ("|",    [0x7C]),
        ("⌃B",   [0x02]),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<Self.keys.count, id: \.self) { idx in
                let key = Self.keys[idx]
                Button {
                    onKey(Data(key.bytes))
                } label: {
                    Text(key.label)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
    }
}

#Preview {
    VStack {
        Spacer()
        AccessoryBar(onKey: { _ in })
    }
}
