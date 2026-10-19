import SwiftUI

/// Query history: every query the user runs (not sidebar browsing), newest first, kept on disk.
struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    let sql: String
    var connectionID: UUID? = nil // nil in entries saved before history was per database
    let connection: String
    let database: String
    let date: Date
    let milliseconds: Int
    let rows: Int?
    let error: String?
}

@MainActor @Observable final class QueryHistory {
    static let shared = QueryHistory()
    // Limitation: capped JSON file rewritten on each append; move to SQLite if history must grow unbounded
    static let limit = 1000
    private(set) var entries: [HistoryEntry] = []
    let url: URL
    private let io = DispatchQueue(label: "history-io")

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kueri/history.json")) {
        self.url = url
        if let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([HistoryEntry].self, from: d) { entries = e }
    }

    /// Statements that carry credentials are never written to the history file.
    /// Deliberately broad (whole text, every line): a query that merely mentions a password column
    /// isn't recorded either, which is the safe side of the trade-off.
    nonisolated static func containsSecret(_ sql: String) -> Bool {
        sql.range(of: #"password|passwd|identified|requirepass|masterauth|secret|\bauth2?\b|\bhello\b|\bacl\b"#,
                  options: [.regularExpression, .caseInsensitive]) != nil
    }

    func add(_ e: HistoryEntry) {
        guard Prefs.saveHistory, !Self.containsSecret(e.sql) else { return }
        // Re-running the same query moves it to the top instead of duplicating it.
        entries.removeAll { $0.sql == e.sql && $0.connectionID == e.connectionID && $0.connection == e.connection && $0.database == e.database }
        entries.insert(e, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        let snapshot = entries, url = url
        io.async {
            Self.write(snapshot, to: url)
        }
    }

    func clearAll() {
        entries = []
        let url = url
        io.async { Self.write([], to: url) }
    }

    /// Clears this connection + database's history only.
    func clear(_ c: Conn) {
        entries.removeAll { $0.database == c.database && ($0.connectionID.map { $0 == c.id } ?? ($0.connection == c.name)) }
        let snapshot = entries, url = url
        io.async { Self.write(snapshot, to: url) }
    }

    /// Queries can contain private data: the folder is 0700 and the file 0600 (owner only).
    private nonisolated static func write(_ entries: [HistoryEntry], to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

