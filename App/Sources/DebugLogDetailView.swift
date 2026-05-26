import SwiftUI

/// "Browse debug log" detail screen — symmetric with the transcripts
/// detail. File metadata at top, ANSI-stripped tail preview, share &
/// reset actions. Pushed from the Settings sheet's "Debug" section.
struct DebugLogDetailView: View {
    @Bindable var fileLogger = FileLogger.shared
    /// Local snapshot of file metadata. SwiftUI doesn't observe disk
    /// changes, so we refresh this on `onAppear` and after a reset.
    @State private var size: Int = 0
    @State private var tail: String = ""

    var body: some View {
        Form {
            Section("File") {
                LabeledContent("Path", value: fileLogger.url.lastPathComponent)
                    .font(.caption.monospaced())
                LabeledContent("Size", value: sizeText)
                    .font(.caption.monospaced())
            }

            Section("Actions") {
                ShareLink(item: fileLogger.url) {
                    Label("Share log", systemImage: "square.and.arrow.up")
                        // Fill the row so the whole row is the
                        // hit-target, not just the icon+text bbox.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .foregroundStyle(hasContent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                }
                .disabled(!hasContent)

                Button(role: .destructive) {
                    fileLogger.reset()
                    refresh()
                } label: {
                    Label("Reset log", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .foregroundStyle(hasContent ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
                .disabled(!hasContent)
            }

            if hasContent {
                Section("Tail (last 64 KB)") {
                    Text(tail)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Section {
                    Text("Log is empty. Enable the toggle in Settings → Debug to start writing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Debug log")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
    }

    private var sizeText: String {
        if size < 1024 { return "\(size) B" }
        return String(format: "%.1f KB", Double(size) / 1024.0)
    }

    private var hasContent: Bool { size > 0 }

    /// Re-read size + tail from disk and update local state.
    private func refresh() {
        let path = fileLogger.url.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        size = (attrs?[.size] as? Int) ?? 0
        guard size > 0,
              let data = try? Data(contentsOf: fileLogger.url, options: .mappedIfSafe)
        else {
            tail = ""
            return
        }
        let cap = 64 * 1024
        let slice = data.count > cap ? data.suffix(cap) : data
        tail = String(decoding: slice, as: UTF8.self)
    }
}
