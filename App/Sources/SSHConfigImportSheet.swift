import SwiftUI
import UniformTypeIdentifiers

/// Two-stage sheet for importing entries from an `ssh_config` text
/// file. Stage 1: file picker. Stage 2: preview the parsed entries
/// (including "skipped: …" rows) and confirm import. We import all
/// supported hosts in one go — a checklist would be nice, but tedious
/// for typical configs with dozens of entries, and the user can
/// delete unwanted hosts after.
struct SSHConfigImportSheet: View {
    let store: HostStore
    let onDismiss: () -> Void

    @State private var picking = false
    @State private var parsed: [SSHConfigImporter.ParsedHost] = []
    @State private var selectedIDs: Set<UUID> = []
    @State private var errorMessage: String?
    @State private var importedCount: Int?

    var body: some View {
        NavigationStack {
            Group {
                if let importedCount {
                    importedSummary(count: importedCount)
                } else if parsed.isEmpty {
                    pickStage
                } else {
                    previewStage
                }
            }
            .navigationTitle("Import ssh_config")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDismiss)
                }
            }
            .fileImporter(
                isPresented: $picking,
                allowedContentTypes: [.text, .data, .item],
                allowsMultipleSelection: false
            ) { result in
                handlePicked(result)
            }
        }
    }

    // MARK: - Stages

    private var pickStage: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Import host entries from your `ssh_config` file. Use the Files app to share the config to this device first.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button {
                picking = true
            } label: {
                Label("Choose file…", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Spacer()
        }
        .padding(.top, 32)
    }

    private var previewStage: some View {
        VStack(spacing: 0) {
            List {
                let importable = parsed.filter { $0.skipReason == nil }
                let skipped = parsed.filter { $0.skipReason != nil }

                if !importable.isEmpty {
                    Section {
                        ForEach(importable) { row in
                            importableRow(row)
                        }
                    } header: {
                        HStack {
                            Text("Available (\(importable.count))")
                            Spacer()
                            Button(allImportableSelected(importable) ? "Deselect all" : "Select all") {
                                toggleAll(importable)
                            }
                            .font(.caption)
                            .textCase(nil)
                        }
                    }
                }
                if !skipped.isEmpty {
                    Section("Skipped (\(skipped.count))") {
                        ForEach(skipped) { row in
                            skippedRow(row)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Pick another") {
                    parsed = []
                    selectedIDs = []
                    errorMessage = nil
                }
                Spacer()
                Button {
                    importSelected()
                } label: {
                    Text("Import \(selectedIDs.count)")
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty)
            }
            .padding()
        }
    }

    private func allImportableSelected(_ importable: [SSHConfigImporter.ParsedHost]) -> Bool {
        !importable.isEmpty && importable.allSatisfy { selectedIDs.contains($0.id) }
    }

    private func toggleAll(_ importable: [SSHConfigImporter.ParsedHost]) {
        if allImportableSelected(importable) {
            selectedIDs.removeAll()
        } else {
            selectedIDs = Set(importable.map(\.id))
        }
    }

    private func importedSummary(count: Int) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Imported \(count) host\(count == 1 ? "" : "s").")
                .font(.headline)
            Text("Open Settings → SSH keys to assign a key to each new host.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Done", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .padding(.top)
            Spacer()
        }
        .padding(.top, 48)
    }

    // MARK: - Rows

    private func importableRow(_ row: SSHConfigImporter.ParsedHost) -> some View {
        let isSelected = selectedIDs.contains(row.id)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.pattern)
                    .font(.body.weight(.medium))
                if let host = row.host {
                    Text("\(host.user.isEmpty ? "(no user)" : host.user)@\(host.host):\(host.port)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let id = row.identityFile {
                    Text("IdentityFile: \(id)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                if !row.ignoredDirectives.isEmpty {
                    Text("Ignored: \(row.ignoredDirectives.joined(separator: ", "))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected {
                selectedIDs.remove(row.id)
            } else {
                selectedIDs.insert(row.id)
            }
        }
    }

    private func skippedRow(_ row: SSHConfigImporter.ParsedHost) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.pattern)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
            Text(row.skipReason ?? "")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Actions

    private func handlePicked(_ result: Result<[URL], any Error>) {
        switch result {
        case .failure(let err):
            errorMessage = "pick failed: \(err.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let text = try readSecurityScoped(url: url)
                parsed = try SSHConfigImporter.parse(text: text)
                if parsed.isEmpty {
                    errorMessage = "No `Host` blocks found in the file."
                }
                // Default selection: every importable row pre-checked.
                selectedIDs = Set(parsed.filter { $0.skipReason == nil }.map(\.id))
            } catch {
                errorMessage = "parse failed: \(error.localizedDescription)"
            }
        }
    }

    private func readSecurityScoped(url: URL) throws -> String {
        // Document-picker URLs come with a security scope we have to
        // open before reading. Skipping this fails on real devices.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func importSelected() {
        var imported = 0
        for row in parsed where selectedIDs.contains(row.id) {
            guard let host = row.host else { continue }
            // Skip exact duplicates by user@host:port to avoid
            // littering the list on repeat imports.
            let isDup = store.hosts.contains {
                $0.user == host.user && $0.host == host.host && $0.port == host.port
            }
            if isDup { continue }
            store.add(host)
            imported += 1
        }
        importedCount = imported
    }
}
