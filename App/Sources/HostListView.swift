import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Root list of saved hosts + SSH keys. Two sections in one `List`:
/// hosts on top (tap a row → push detail screen), keys below (Files
/// import, rename, remove — remove disabled while a host references
/// the key).
///
/// The page is designed for iPad with a hardware keyboard, so row
/// destruction uses explicit Remove buttons (not swipe-only). Swipe
/// is still offered as a convenience on touch.
struct HostListView: View {
    let store: HostStore
    let settings: SettingsStore
    let keyStore: KeyStore

    @State private var showingAddHost = false
    @State private var showingSettings = false
    @State private var importingConfig = false

    /// Files-picker visibility. Drives `.fileImporter`.
    @State private var importingKey = false
    /// Bytes + derived name held between the file picker resolving
    /// and the user confirming/editing the name in the import sheet.
    @State private var pendingKeyImport: PendingKeyImport?

    /// Sheet for editing an existing key's name.
    @State private var renamingKey: KeyMetadata?

    /// Per-action error surfacing — used for "key in use, can't
    /// remove" and import failures so the user always knows why an
    /// action declined to run.
    @State private var actionError: String?

    var body: some View {
        List {
            hostsSection
            keysSection
        }
        .overlay {
            if store.hosts.isEmpty && keyStore.keys.isEmpty {
                ContentUnavailableView(
                    "Empty",
                    systemImage: "server.rack",
                    description: Text("Tap + to add a host or import an SSH key.")
                )
            }
        }
        .navigationTitle("Hosts")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    importingConfig = true
                } label: {
                    Image(systemName: "square.and.arrow.down.on.square")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                // Single + button opens a menu so the toolbar stays
                // tidy. Add host is the most common action so it's
                // the first entry.
                Menu {
                    Button {
                        showingAddHost = true
                    } label: {
                        Label("Add host", systemImage: "server.rack")
                    }
                    Button {
                        importingKey = true
                    } label: {
                        Label("Import SSH key…", systemImage: "key")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddHost) {
            NavigationStack {
                HostFormView(initial: nil, keyStore: keyStore) { newHost in
                    store.add(newHost)
                    showingAddHost = false
                } onCancel: {
                    showingAddHost = false
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(settings: settings, keyStore: keyStore) {
                showingSettings = false
            }
        }
        .sheet(isPresented: $importingConfig) {
            SSHConfigImportSheet(store: store) {
                importingConfig = false
            }
        }
        .sheet(item: $pendingKeyImport) { pending in
            KeyImportSheet(
                initialName: pending.suggestedName,
                onSave: { editedName in
                    do {
                        try keyStore.importFromFile(name: editedName, fileBytes: pending.bytes)
                        pendingKeyImport = nil
                    } catch {
                        actionError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                        pendingKeyImport = nil
                    }
                },
                onCancel: { pendingKeyImport = nil }
            )
        }
        .sheet(item: $renamingKey) { key in
            KeyRenameSheet(
                initialName: key.name,
                onSave: { newName in
                    do {
                        try keyStore.rename(key.id, to: newName)
                    } catch {
                        actionError = "\(error)"
                    }
                    renamingKey = nil
                },
                onCancel: { renamingKey = nil }
            )
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            ),
            presenting: actionError
        ) { _ in
            Button("OK") { actionError = nil }
        } message: { msg in
            Text(msg)
        }
        .fileImporter(
            isPresented: $importingKey,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                // Files-imported URLs are security-scoped — must
                // bracket the read in start/stop access.
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let data = try Data(contentsOf: url)
                    let suggested = url.deletingPathExtension().lastPathComponent
                    pendingKeyImport = PendingKeyImport(
                        bytes: data,
                        suggestedName: suggested.isEmpty ? "imported-key" : suggested
                    )
                } catch {
                    actionError = "Couldn't read file: \(error.localizedDescription)"
                }
            case .failure(let error):
                actionError = "Import cancelled: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Hosts section

    @ViewBuilder
    private var hostsSection: some View {
        if !store.hosts.isEmpty {
            Section("Hosts") {
                ForEach(store.hosts) { host in
                    NavigationLink(value: host.id) {
                        HostRow(host: host)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.remove(id: host.id)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            store.remove(id: host.id)
                        } label: {
                            Label("Remove host", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Keys section

    @ViewBuilder
    private var keysSection: some View {
        if !keyStore.keys.isEmpty {
            Section("SSH keys") {
                ForEach(keyStore.keys) { key in
                    let users = hostsUsingKey(key.id)
                    HStack(alignment: .top) {
                        KeyRow(key: key, usedBy: users)
                        Spacer(minLength: 8)
                        // Explicit trailing menu — discoverable on
                        // iPad / HW keyboard without relying on
                        // long-press for context menu or trailing
                        // swipe. Same actions; "Remove" is disabled
                        // (greyed) while any host references the key
                        // so users see *why* they can't delete.
                        Menu {
                            Button {
                                renamingKey = key
                            } label: {
                                Label("Rename…", systemImage: "pencil")
                            }
                            if let pub = key.publicKeyOpenSSH {
                                Button {
                                    UIPasteboard.general.string = "\(pub) \(key.name)"
                                } label: {
                                    Label("Copy public key", systemImage: "doc.on.doc")
                                }
                            }
                            Divider()
                            Button(role: .destructive) {
                                removeKey(key.id)
                            } label: {
                                Label("Remove key", systemImage: "trash")
                            }
                            .disabled(!users.isEmpty)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .swipeActions(edge: .trailing) {
                        // Touch-only convenience — same gate as the
                        // explicit Remove in the menu.
                        if users.isEmpty {
                            Button(role: .destructive) {
                                removeKey(key.id)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func hostsUsingKey(_ keyID: UUID) -> [Host] {
        store.hosts.filter { $0.keyID == keyID }
    }

    private func removeKey(_ id: UUID) {
        let users = hostsUsingKey(id)
        guard users.isEmpty else {
            actionError = "Can't remove: used by \(users.map(\.name).joined(separator: ", "))."
            return
        }
        do {
            try keyStore.remove(id)
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

// MARK: - Rows

private struct HostRow: View {
    let host: Host

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(host.name)
                .font(.body.weight(.medium))
            Text(connectionString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var connectionString: String {
        let portSuffix = host.port == 22 ? "" : ":\(host.port)"
        return "\(host.user)@\(host.host)\(portSuffix)"
    }
}

private struct KeyRow: View {
    let key: KeyMetadata
    let usedBy: [Host]

    /// Brief checkmark feedback after tapping the copy-fingerprint
    /// button so the user sees the action took. Mirrors the build-
    /// signature copy pattern in `SettingsSheet`.
    @State private var fingerprintCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key.name)
                .font(.body.weight(.medium))
            if let fp = key.fingerprintSHA256 {
                HStack(spacing: 8) {
                    Text(fp)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        UIPasteboard.general.string = fp
                        fingerprintCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            fingerprintCopied = false
                        }
                    } label: {
                        Image(systemName: fingerprintCopied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(fingerprintCopied ? Color.green : Color.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy fingerprint")
                }
            } else {
                // Older entries without a stored fingerprint —
                // backfill happens on first load; until then we just
                // omit the line rather than show a placeholder.
                EmptyView()
            }
            HStack(spacing: 12) {
                Text("Added \(Self.relativeDate(key.createdAt))")
                Text("·")
                if let last = key.lastUsedAt {
                    Text("Used \(Self.relativeDate(last))")
                } else {
                    Text("Never used")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if usedBy.isEmpty {
                Text("Unused")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Used by: \(usedBy.map(\.name).joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    /// Compact "2h ago"-style relative date for the row's metadata
    /// strip. `RelativeDateTimeFormatter` is locale-aware *and*
    /// honors the user's region — fine here because these strings
    /// are user-facing chrome, not log/filename material.
    private static func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Import + rename sheets

private struct PendingKeyImport: Identifiable {
    let id = UUID()
    let bytes: Data
    let suggestedName: String
}

private struct KeyImportSheet: View {
    let initialName: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Key name") {
                    TextField("Display name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Text("Pre-filled from the filename — edit if you want something more memorable. You can rename later.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Import key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { onSave(name) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if name.isEmpty { name = initialName }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct KeyRenameSheet: View {
    let initialName: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Key name") {
                    TextField("Display name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Rename key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(name) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if name.isEmpty { name = initialName }
            }
        }
        .presentationDetents([.medium])
    }
}
