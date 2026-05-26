import SwiftUI

/// Browse, share, and delete past session transcripts. Pushed from
/// the Settings sheet's "Transcripts" row.
struct TranscriptListView: View {
    let store: TranscriptStore
    @State private var entries: [TranscriptFile] = []
    @State private var confirmingDeleteAll = false

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No transcripts",
                    systemImage: "doc.text",
                    description: Text("Enable transcripts in Settings, then attach to a session.")
                )
            } else {
                ForEach(entries) { entry in
                    NavigationLink {
                        TranscriptDetailView(file: entry)
                    } label: {
                        row(entry)
                    }
                }
                .onDelete { offsets in
                    for idx in offsets {
                        store.delete(entries[idx].url)
                    }
                    refresh()
                }
            }
        }
        .navigationTitle("Transcripts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !entries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        confirmingDeleteAll = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete all \(entries.count) transcripts?",
            isPresented: $confirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete all", role: .destructive) {
                for entry in entries { store.delete(entry.url) }
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { refresh() }
    }

    private func row(_ file: TranscriptFile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(file.name)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Text(file.createdAt.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                Text(byteCountFormatter.string(fromByteCount: Int64(file.size)))
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        entries = store.list()
    }

    private let byteCountFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return f
    }()
}

/// Per-file view: ANSI-stripped preview + share button. Useful for
/// "what command did I run yesterday" without piping through a real
/// terminal.
struct TranscriptDetailView: View {
    let file: TranscriptFile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(textPreview)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: file.url) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    /// Read up to ~256 KB and strip ANSI escapes for display. The
    /// raw file is what the share button hands off — viewers that
    /// understand escapes (any terminal, `cat`, `less -R`) will
    /// render it correctly.
    private var textPreview: String {
        let cap = 256 * 1024
        guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else {
            return "(failed to read)"
        }
        let slice = data.count > cap ? data.prefix(cap) : data
        let raw = String(decoding: slice, as: UTF8.self)
        return ANSIStripper.strip(raw)
    }
}

/// Drops CSI / OSC escape sequences from a string so the output is
/// readable in a plain `Text` view. We don't try to interpret cursor
/// positioning — just remove the sequences.
private enum ANSIStripper {
    static func strip(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var iter = s.unicodeScalars.makeIterator()
        while let c = iter.next() {
            if c == "\u{1B}" {
                // Consume CSI: ESC [ ... <final-byte>
                guard let next = iter.next() else { break }
                if next == "[" {
                    while let inner = iter.next() {
                        if (0x40...0x7E).contains(Int(inner.value)) { break }
                    }
                } else if next == "]" {
                    // OSC: terminated by BEL or ST (ESC \)
                    while let inner = iter.next() {
                        if inner == "\u{07}" { break }
                        if inner == "\u{1B}" {
                            _ = iter.next() // skip the `\`
                            break
                        }
                    }
                }
                // Other ESC sequences (e.g. ESC ( ?), drop next char.
                continue
            }
            out.unicodeScalars.append(c)
        }
        return out
    }
}
