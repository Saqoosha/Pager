import Foundation

/// Read/write API for notification history, backed by per-entry JSON files
/// inside the App Group container. Safe to call from both the main app and
/// the Notification Service Extension because each entry lives in its own
/// file (unique name = no write conflicts).
enum HistoryStore {
    static let appGroupID = "group.sh.saqoo.CanopyCompanion"
    static let maxItems = 100

    enum StoreError: Error {
        case containerUnavailable
    }

    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static func historyDirectory() throws -> URL {
        guard let container = containerURL() else {
            throw StoreError.containerUnavailable
        }
        let dir = container.appendingPathComponent("history", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func filename(for item: NotificationHistoryItem) -> String {
        let millis = Int64(item.receivedAt.timeIntervalSince1970 * 1000)
        return "\(millis)-\(item.id).json"
    }

    /// Called by the Notification Service Extension when a push arrives.
    static func append(_ item: NotificationHistoryItem) throws {
        let dir = try historyDirectory()
        let url = dir.appendingPathComponent(filename(for: item))
        let data = try encoder().encode(item)
        try data.write(to: url, options: .atomic)
        try pruneOldFiles(in: dir)
    }

    /// Loads all history entries, newest first.
    static func loadAll() throws -> [NotificationHistoryItem] {
        let dir = try historyDirectory()
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        let dec = decoder()
        var items: [NotificationHistoryItem] = []
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                items.append(try dec.decode(NotificationHistoryItem.self, from: data))
            } catch {
                // Corrupt file — skip. Could log, but this runs on every list load.
                continue
            }
        }
        items.sort { $0.receivedAt > $1.receivedAt }
        return items
    }

    static func item(withId id: String) throws -> NotificationHistoryItem? {
        try loadAll().first(where: { $0.id == id })
    }

    static func delete(id: String) throws {
        let dir = try historyDirectory()
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        for file in files where file.lastPathComponent.contains("-\(id).json") {
            try FileManager.default.removeItem(at: file)
        }
    }

    static func deleteAll() throws {
        let dir = try historyDirectory()
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        for file in files {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Updates `decision` / `decidedAt` for the entry with a matching requestId.
    /// Called from the main app after the user acts on Allow/Deny/AllowAlways.
    /// No-op if the entry has already been pruned.
    static func updateDecision(requestId: String, decision: String, decidedAt: Date) throws {
        guard var item = try item(withId: requestId) else { return }
        item.decision = decision
        item.decidedAt = decidedAt
        // Overwrite the existing file by re-appending under the same filename.
        let dir = try historyDirectory()
        let url = dir.appendingPathComponent(filename(for: item))
        let data = try encoder().encode(item)
        try data.write(to: url, options: .atomic)
    }

    private static func pruneOldFiles(in dir: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        guard files.count > maxItems else { return }
        // Sort ascending by filename (filenames begin with receivedAt millis, so
        // lexicographic order matches chronological order).
        let sorted = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let excess = sorted.count - maxItems
        for i in 0..<excess {
            try? FileManager.default.removeItem(at: sorted[i])
        }
    }
}
