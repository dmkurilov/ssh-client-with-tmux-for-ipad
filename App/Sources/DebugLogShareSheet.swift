import SwiftUI
import UIKit

/// Wraps the debug log file in an iOS share sheet so the user can
/// AirDrop / mail / save it to Files. Also offers a "Reset" button
/// that wipes the log before reproducing a specific bug.
struct DebugLogShareSheet: View {
    let url: URL
    let onDismiss: () -> Void

    @State private var lastReset: Date?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(url.lastPathComponent)
                    .font(.body.monospaced())
                Text(sizeText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                ShareLink(item: url) {
                    Label("Share log", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    FileLogger.shared.reset()
                    lastReset = Date()
                } label: {
                    Label("Reset log", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if lastReset != nil {
                    Text("Log cleared.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Debug log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }

    private var sizeText: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int
        else { return "—" }
        let kb = Double(size) / 1024.0
        return String(format: "%.1f KB on disk", kb)
    }
}
