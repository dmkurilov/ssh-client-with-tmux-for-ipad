import Foundation
import Observation

/// Persists raw pane-output bytes to per-pane files in
/// `Documents/transcripts/`. One file per `(host, session, paneID)`
/// triple. Files stay open while the session is attached and are
/// closed on `onDisappear` of the tmux view (or when the master
/// `enabled` toggle flips off).
///
/// `enabled` is opt-in (off by default) — terminal output often
/// contains secrets, so we don't silently mirror to disk.
@MainActor
@Observable
final class TranscriptStore {
    static let shared = TranscriptStore()

    private static let enabledKey = "TranscriptsEnabled"

    /// Master switch. Persists in `UserDefaults` so it survives a
    /// relaunch. Flipping off closes any open handles immediately.
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if !enabled { closeAll() }
            RecordingConsent.shared.reconcile()
        }
    }

    private struct Key: Hashable {
        let host: String
        let session: String
        let paneID: Int
    }

    private struct OpenFile {
        let handle: FileHandle
        var url: URL
        var windowID: Int?  // nil → file was opened with `wX` placeholder
    }

    @ObservationIgnored
    private var handles: [Key: OpenFile] = [:]

    private init() {
        self.enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // MARK: - Writing

    /// Append bytes from one `%output` event to the appropriate file.
    /// Opens the file lazily on the first call for a given key.
    /// `windowID` is just for filename labelling — the per-pane file
    /// is keyed by paneID, so a pane that gets moved between windows
    /// keeps writing to its original file.
    func feed(host: String, session: String, windowID: Int?, paneID: Int, data: Data) {
        guard enabled, !data.isEmpty else { return }
        let key = Key(host: host, session: session, paneID: paneID)
        if handles[key] == nil, let opened = openHandle(for: key, windowID: windowID) {
            handles[key] = opened
        } else if let existing = handles[key],
                  existing.windowID == nil,
                  let wid = windowID
        {
            // First feed where we know the window — rename the
            // placeholder `wX` file to its real name. The FileHandle
            // is keyed to the inode, so writes after the move keep
            // landing in the right file.
            let oldURL = existing.url
            let newName = oldURL.lastPathComponent.replacingOccurrences(
                of: "-wX-",
                with: "-w\(wid)-"
            )
            let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newName)
            do {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
                handles[key] = OpenFile(
                    handle: existing.handle,
                    url: newURL,
                    windowID: wid
                )
            } catch {
                // Rename failed — keep writing under the wX name.
            }
        }
        try? handles[key]?.handle.write(contentsOf: data)
    }

    /// Close the handles for one (host, session) pair — called when
    /// the tmux view disappears so files don't stay open across
    /// navigations.
    func close(host: String, session: String) {
        let stale = handles.keys.filter { $0.host == host && $0.session == session }
        for k in stale {
            try? handles[k]?.handle.close()
            handles.removeValue(forKey: k)
        }
    }

    func closeAll() {
        for f in handles.values { try? f.handle.close() }
        handles.removeAll()
    }

    // MARK: - Listing

    var transcriptsDirectory: URL {
        let docs = try! FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = docs.appendingPathComponent("transcripts")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// All transcripts present on disk, newest first.
    func list() -> [TranscriptFile] {
        let dir = transcriptsDirectory
        let keys: Set<URLResourceKey> = [.fileSizeKey, .creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url -> TranscriptFile? in
            let values = try? url.resourceValues(forKeys: keys)
            return TranscriptFile(
                url: url,
                size: values?.fileSize ?? 0,
                createdAt: values?.creationDate ?? Date()
            )
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func delete(_ url: URL) {
        // Close any matching open handle first so the OS doesn't
        // hold the file alive after we unlink it.
        for (key, file) in handles where file.url == url {
            try? file.handle.close()
            handles.removeValue(forKey: key)
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - File creation

    private func openHandle(for key: Key, windowID: Int?) -> OpenFile? {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let widComponent = windowID.map { "w\($0)" } ?? "wX"
        let raw = "\(key.host)-\(key.session)-\(widComponent)-pane\(key.paneID)-\(timestamp).log"
        let safe = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
        let url = transcriptsDirectory.appendingPathComponent(safe)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? h.seekToEnd()
        return OpenFile(handle: h, url: url, windowID: windowID)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        // Per Apple's `Date and Time Programming Guide` ("Working
        // With Fixed Format Date Representations"), any `DateFormatter`
        // with a custom `dateFormat` must use `en_US_POSIX` — without
        // it the formatter applies the user's region overrides
        // (Thai/Buddhist calendar, Hebrew calendar, Arabic numerals,
        // etc.) and the "fixed" format produces filenames that vary
        // by device locale and don't sort lexicographically.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.timeZone = TimeZone.current
        return f
    }()
}

struct TranscriptFile: Identifiable, Hashable {
    let url: URL
    let size: Int
    let createdAt: Date

    var id: URL { url }
    var name: String { url.lastPathComponent }
}
