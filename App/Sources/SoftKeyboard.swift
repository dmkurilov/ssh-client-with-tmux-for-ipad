import SwiftUI

/// Custom on-screen keyboard. Replaces iOS's SW keyboard entirely
/// (we never claim `UIKeyInput`, so iOS won't draw one for us). Six
/// rows: special keys, digits, two QWERTY letter rows, a third
/// letter row with shift / backspace, and a bottom row with the
/// most-used terminal symbols + space + enter.
///
/// Shift is single-shot: tap shift, then a letter, the letter goes
/// out as uppercase and shift clears. Tap shift twice to lock
/// (caps-lock); tap once more to clear.
///
/// All key presses dispatch through `onKey` as raw terminal bytes,
/// joining the same `onInput` path that `TerminalHost.pressesBegan`
/// uses for hardware keys. The destination doesn't know which
/// source the bytes came from.
struct SoftKeyboard: View {
    var onKey: (Data) -> Void

    @State private var shifted: Bool = false
    @State private var capsLocked: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            specialRow
            digitRow
            row1
            row2
            row3
            bottomRow
        }
        .padding(4)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Rows

    private var specialRow: some View {
        HStack(spacing: 4) {
            keyButton("esc", bytes: [0x1B])
            keyButton("tab", bytes: [0x09])
            keyButton("←", bytes: [0x1B, 0x5B, 0x44])
            keyButton("↑", bytes: [0x1B, 0x5B, 0x41])
            keyButton("↓", bytes: [0x1B, 0x5B, 0x42])
            keyButton("→", bytes: [0x1B, 0x5B, 0x43])
            keyButton("|", bytes: [0x7C])
            keyButton("⌃B", bytes: [0x02])
        }
    }

    private var digitRow: some View {
        HStack(spacing: 4) {
            ForEach(Array("1234567890"), id: \.self) { char in
                keyButton(String(char), bytes: Array(String(char).utf8))
            }
        }
    }

    private var row1: some View {
        HStack(spacing: 4) {
            ForEach(Array("qwertyuiop"), id: \.self) { char in
                letterButton(char)
            }
        }
    }

    private var row2: some View {
        HStack(spacing: 4) {
            ForEach(Array("asdfghjkl"), id: \.self) { char in
                letterButton(char)
            }
        }
    }

    private var row3: some View {
        HStack(spacing: 4) {
            shiftButton
            ForEach(Array("zxcvbnm"), id: \.self) { char in
                letterButton(char)
            }
            keyButton("⌫", bytes: [0x7F])
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 4) {
            keyButton("-", bytes: [0x2D])
            keyButton("/", bytes: [0x2F])
            keyButton(":", bytes: [0x3A])
            keyButton(",", bytes: [0x2C])
            keyButton("space", bytes: [0x20])
                .frame(maxWidth: .infinity)
            keyButton(".", bytes: [0x2E])
            keyButton("'", bytes: [0x27])
            keyButton("⏎", bytes: [0x0D])
        }
    }

    // MARK: - Keys

    private func letterButton(_ char: Character) -> some View {
        let upper = shifted || capsLocked
        let label = upper ? String(char).uppercased() : String(char)
        return Button {
            onKey(Data(label.utf8))
            // Single-shot shift clears after one letter (caps-lock
            // does not).
            if shifted, !capsLocked {
                shifted = false
            }
        } label: {
            keyLabel(label)
        }
        .buttonStyle(.plain)
    }

    private var shiftButton: some View {
        Button {
            // Triple-state: off → shift → caps-lock → off.
            // Each tap walks one step.
            if !shifted && !capsLocked {
                shifted = true
            } else if shifted && !capsLocked {
                shifted = false
                capsLocked = true
            } else {
                capsLocked = false
                shifted = false
            }
        } label: {
            Text(capsLocked ? "⇪" : "⇧")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(shifted || capsLocked ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(
                    shifted || capsLocked
                        ? Color.accentColor
                        : Color(.tertiarySystemBackground)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func keyButton(_ label: String, bytes: [UInt8]) -> some View {
        Button {
            onKey(Data(bytes))
        } label: {
            keyLabel(label)
        }
        .buttonStyle(.plain)
    }

    private func keyLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .medium, design: .monospaced))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

#Preview {
    VStack {
        Spacer()
        SoftKeyboard(onKey: { _ in })
    }
}
