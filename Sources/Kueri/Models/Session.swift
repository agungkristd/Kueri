import SwiftUI
import os

@MainActor @Observable final class Session {
    private(set) var conn: Conn
    private var db: Database
    private let queue = DispatchQueue(label: "db")
    var tables: [String] = []
    var databases: [String] = []
    var schemas: [String] = []
    var schema = "public"     // Postgres schema shown in the sidebar
    var sql = ""
    var result = QueryResult()
    var selectedRow: Int?
    var selectedRows: [Int] = [] // every selected row of the active tab's grid (⌘/⇧-click)
    /// Unsaved edits, row → column → new value (nil = NULL). Shared by the grid and Details panel.
    var edits: [Int: [Int: String?]] = [:]
    var editCount: Int { edits.values.reduce(0) { $0 + $1.count } }
    var saving = false
    var table: String?        // table behind `result`, when it came from browse()
    var primaryKey: [String] = []
    var browsed: (query: String, table: String, offset: Int)?
    var offset = 0            // first row of the current page when `table` is set
    // Table tabs: the fields above always hold the active tab; other tabs are parked in `tabs`.
    var tabs: [WorkTab] = []
    var activeTab = UUID()
    var kind = TabKind.data
    var diagram: DiagramModel?
    // Column lists for autocomplete, per table of the current database.
    var history = QueryHistory.shared
    var tunnel: SSHTunnel?   // kept alive for the session; ssh stops when the session goes away
    var serverVersion = ""   // "PostgreSQL 16.8", shown in the connection bar
    var inspectedTable: String? // table in the right panel's Table tab, chosen in the diagram
    /// Database dropdown open. Here, not in WorkspaceView's state: toggling that re-evaluated the whole workspace.
    var dbPicker = false
    /// Every foreign key of the current database, loaded with the first table browsed (nil = not yet).
    var foreignKeys: [ForeignKey]?
    var pendingConfirm: PendingConfirm?   // production safety question the workspace should show
    var columnCache: [String: [ColumnInfo]] = [:]
    var columnCacheLoading: Set<String> = []
    var error: String?
    var busy = false

    init(conn: Conn, db: Database) {
        self.conn = conn; self.db = db
        tabs = [WorkTab(id: activeTab)]
    }

    /// Runs `work` on the session's serial queue (the connection is not thread-safe).
    func onQueue<T>(_ work: @escaping (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in queue.async { [db] in c.resume(with: Result { try work(db) }) } }
    }

    /// Connects and loads the sidebar lists, off the main thread.
    /// Right after launch macOS can refuse LAN connections ("No route to host") while it checks the
    /// Local Network permission, even when it's granted; the same connection works seconds later.
    private static func connectRetryingLocal(_ c: Conn) async throws
        -> (Database, tables: [String], databases: [String], schemas: [String], tunnel: SSHTunnel?, version: String) {
        var attempt = 0
        while true {
            do { return try await connect(c) }
            catch where attempt < 3 && isLocalNetwork(c.host) && error.localizedDescription.contains("No route to host") {
                attempt += 1
                log.notice("LAN connect to \(c.host, privacy: .public) refused, retry \(attempt)")
                try await Task.sleep(for: .milliseconds(700 * attempt))
            }
        }
    }
    private static let log = Logger(subsystem: "app.kueri", category: "connect")

    /// Private / link-local addresses and .local names: what macOS's Local Network permission covers.
    nonisolated static func isLocalNetwork(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.hasSuffix(".local") || h.hasPrefix("10.") || h.hasPrefix("192.168.") || h.hasPrefix("169.254.") { return true }
        let p = h.split(separator: ".").compactMap { Int($0) }
        return p.count == 4 && p[0] == 172 && (16...31).contains(p[1])
    }

    /// Connects (through an SSH tunnel when configured; an existing tunnel is reused when switching
    /// databases) and loads the sidebar lists, off the main thread.
    private static func connect(_ c: Conn, tunnel existing: SSHTunnel? = nil) async throws
        -> (Database, tables: [String], databases: [String], schemas: [String], tunnel: SSHTunnel?, version: String) {
        let pw = c.password ?? ""
        return try await Task.detached {
            var tunnel = existing
            if c.useSSH == true, c.kind != .sqlite, tunnel == nil {
                tunnel = try SSHTunnel(sshHost: c.sshHost ?? "", sshPort: c.sshPort ?? "22", sshUser: c.sshUser ?? "",
                                       keyPath: c.sshKey, dbHost: c.host, dbPort: c.port.isEmpty ? c.kind.defaults.port : c.port)
            }
            let via = c.useSSH == true ? tunnel.map { (host: "127.0.0.1", port: String($0.localPort)) } : nil
            let db: Database = switch c.kind {
            case .sqlite: try SQLiteDB(path: c.path)
            case .postgres: try PostgresDB(host: c.host, port: c.port, user: c.user, password: pw, database: c.database,
                                           allowCleartextPassword: c.allowCleartextPassword ?? false, tls: c.tlsMode, via: via)
            case .mysql: try MySQLDB(host: c.host, port: c.port, user: c.user, password: pw, database: c.database,
                                     allowPublicKeyRetrieval: c.allowPublicKeyRetrieval ?? false, tls: c.tlsMode, via: via)
            case .redis: try RedisDB(host: c.host, port: c.port, user: c.user, password: pw, database: c.database,
                                     allowCleartextPassword: c.allowCleartextPassword ?? false, tls: c.tlsMode, via: via)
            }
            // Query timeout from Settings, enforced by the server for this session.
            let timeout = Prefs.queryTimeout
            if timeout > 0 {
                switch c.kind {
                case .postgres: _ = try? db.query("SET statement_timeout = \(timeout * 1000)")
                case .mysql: _ = try? db.query("SET SESSION max_execution_time = \(timeout * 1000)")
                default: break
                }
            }
            return (db, try db.tables(), (try? db.databases()) ?? [], (try? db.schemas()) ?? [], tunnel, (try? db.serverVersion()) ?? "")
        }.value
    }

    static func open(_ c: Conn) async throws -> Session {
        let (db, tables, databases, schemas, tunnel, version): (Database, [String], [String], [String], SSHTunnel?, String)
        do { (db, tables, databases, schemas, tunnel, version) = try await connectRetryingLocal(c) }
        catch where Self.isLocalNetwork(c.host) && error.localizedDescription.contains("No route to host") {
            // macOS blocks the LAN until Kueri is allowed; it reports that as "No route to host".
            // The hint goes first: error labels show only the first lines.
            throw DBError("""
                macOS is blocking Kueri from the local network. Turn on Kueri in System Settings › Privacy & Security › \
                Local Network (off and on again if it's already on), then connect again.\n\n
                """ + error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let s = Session(conn: c, db: db)
        s.tunnel = tunnel
        s.serverVersion = version
        s.tables = tables
        s.databases = databases
        s.schemas = schemas
        s.schema = schemas.contains("public") ? "public" : (schemas.first ?? "public")
        return s
    }

    var switchingTo: String?


    /// Dialect-quoted table name, for generated DDL.
    func quoteTable(_ t: String) -> String { db.quoteTable(t) }
    func schemaOf(_ t: String) -> String? { db.schemaOf(t) }

    /// Unconnected session for UI checks (`--bench`); queries would fail.
    static func preview(_ c: Conn) -> Session {
        let s = Session(conn: c, db: try! SQLiteDB(path: ":memory:"))
        s.history = QueryHistory(url: FileManager.default.temporaryDirectory.appendingPathComponent("kueri-preview-\(UUID()).json"))
        return s
    }

    /// Switches database inside this session: the views stay, only connection and lists change.
    /// (Rebuilding the whole workspace per switch blocked the main thread ~120 ms.)
    func switchDatabase(_ name: String) {
        guard name != conn.database, switchingTo == nil else { return }
        guard !tabs.contains(where: { $0.id != activeTab && !$0.edits.isEmpty }), edits.isEmpty else {
            error = "Save or discard unsaved changes first."; return
        }
        var c = conn
        c.database = name
        switchingTo = name; error = nil
        Task {
            defer { switchingTo = nil }
            do {
                let (newDB, t, d, sc, _, _) = try await Self.connect(c, tunnel: tunnel)
                // Old connection is released once queued work holding it finishes.
                db = newDB; conn = c; tables = t; databases = d; schemas = sc
                schema = sc.contains("public") ? "public" : (sc.first ?? "public")
                columnCache = [:]; columnCacheLoading = []; foreignKeys = nil
                resetTabs()
            } catch { self.error = error.localizedDescription }
        }
    }

    func run(_ text: String? = nil, confirmed: Bool = false) {
        let q = text ?? sql
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !busy else { return }
        if conn.isProd, !confirmed {
            let reasons = riskyReasons(q, kind: conn.kind)
            if !reasons.isEmpty {
                pendingConfirm = PendingConfirm(title: "Run this on production \(conn.name)?", details: reasons, button: "Run on Production") { [weak self] in
                    self?.run(q, confirmed: true)
                }
                return
            }
        }
        guard !blockedByEdits() else { return }
        busy = true; error = nil
        // Rows are editable when the result is a sidebar browse, or a hand-written SELECT * of one table.
        let fromBrowse = browsed?.query == q
        let source = fromBrowse ? browsed?.table : SimpleSelect.table(q).flatMap(editableTable)
        let pageOffset = fromBrowse ? browsed?.offset ?? 0 : SimpleSelect.offset(q) ?? 0
        let tab = activeTab
        let started = Date()
        let needKeys = source != nil && foreignKeys == nil
        queue.async { [db] in
            let r = Result { try db.query(q) }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            // Big results leave the driver's freed chunk buffers mapped; hand them back (a few ms).
            if ((try? r.get())?.rows.count ?? 0) >= 1000 { malloc_zone_pressure_relief(nil, 0) }
            let t = try? db.tables()
            let sc = try? db.schemas() // a CREATE SCHEMA run from the editor shows up right away
            let pk = source.flatMap { try? db.primaryKey($0) } ?? []
            let fks = needKeys ? (try? db.foreignKeys()) ?? [] : nil
            DispatchQueue.main.async {
                if let fks { self.foreignKeys = fks }
                self.busy = false
                if !fromBrowse { // user-run queries only; sidebar browsing would flood the history
                    let rows: Int? = (try? r.get()).map { $0.columns.isEmpty ? $0.affected : $0.rows.count }
                    let err: String? = if case .failure(let e) = r { e.localizedDescription } else { nil }
                    self.history.add(HistoryEntry(sql: q, connectionID: self.conn.id, connection: self.conn.name, database: self.conn.database,
                                                  date: started, milliseconds: ms, rows: rows, error: err))
                }
                self.updateTab(tab) { w in
                    switch r {
                    case .success(let v):
                        w.result = v; w.selectedRow = nil; w.error = nil
                        if tab == self.activeTab { self.selectedRows = [] }
                        w.table = source; w.primaryKey = pk; w.offset = source == nil ? 0 : pageOffset
                        // The query behind an editable result: paging and header sorting rewrite it.
                        w.browsed = source.map { (q, $0, pageOffset) }
                    case .failure(let e): w.error = e.localizedDescription
                    }
                }
                if let t { self.tables = t }
                if let sc { self.schemas = sc }
            }
        }
    }

    /// Foreign-key columns of the browsed table, by result column.
    // Limitation: a composite key is followed by its one clicked column only.
    var links: [Int: ForeignKey] {
        guard let table, let fks = foreignKeys else { return [:] }
        var m: [Int: ForeignKey] = [:]
        for fk in fks where fk.fromTable == table { if let i = result.columns.firstIndex(of: fk.fromColumn) { m[i] = fk } }
        return m
    }

    /// Opens the row a foreign-key cell points to, in a new tab (editable, like a sidebar browse).
    func follow(row: Int, column: Int) {
        guard let fk = links[column], row < result.rows.count, let v = result.rows.cell(row, column) else { return }
        let q = db.filterQuery(fk.toTable, column: fk.toColumn, value: v)
        _ = newTab()
        browsed = (q, fk.toTable, 0); sql = q; run()
    }

    /// Deletes rows by primary key after asking, then reloads the page.
    /// A new result would silently drop unsaved edits: says so and returns true while there are any.
    private func blockedByEdits() -> Bool {
        guard !edits.isEmpty else { return false }
        error = "Save or discard \(editCount) unsaved change(s) first."
        return true
    }

    // Limitation: one DELETE per row, not in a transaction.
    func deleteRows(_ rows: [Int]) {
        guard readOnlyReason == nil, let table, let q = browsed?.query else { return }
        guard !blockedByEdits() else { return }
        let keys = rows.filter { $0 < result.rows.count }.sorted().map { r in
            primaryKey.map { k in (k, result.rows.cell(r, result.columns.firstIndex(of: k)!)) }
        }
        guard !keys.isEmpty else { return }
        let n = keys.count, place = conn.onProduction
        pendingConfirm = PendingConfirm(title: "Delete \(n) row\(n == 1 ? "" : "s") from \(table)\(place)?",
                                        details: ["Rows are deleted by primary key. This can't be undone."], button: "Delete") { [weak self] in
            guard let self else { return }
            Task {
                do {
                    let deleted = try await self.onQueue { db in try keys.reduce(0) { $0 + (try db.delete(table, key: $1)) } }
                    if deleted == n { self.run(q) } // reload the page
                    else { self.error = "\(deleted) of \(n) rows deleted (changed or deleted meanwhile?). Reload to see the table." }
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    /// Why the selected row can't be edited, or nil if it can.
    var readOnlyReason: String? {
        if conn.kind == .redis { return "Read-only: editing Redis values isn't supported yet." }
        if table == nil { return "Read-only: only a table from the sidebar or SELECT * FROM one table can be edited." }
        if primaryKey.isEmpty { return "Read-only: \(table!) has no primary key." }
        if let k = primaryKey.first(where: { !result.columns.contains($0) }) { return "Read-only: key column \(k) not in result." }
        return nil
    }

    /// One UPDATE for all changed fields of a row, matched by primary key.
    /// Records an edit, or clears it when the value is back to the original.
    func setEdit(row: Int, column: Int, value: String??) {
        var r = edits[row] ?? [:]
        if let value, value != (row < result.rows.count ? result.rows.cell(row, column) : nil) { r[column] = value } else { r.removeValue(forKey: column) }
        edits[row] = r.isEmpty ? nil : r
    }

    /// Saves every edited row (one UPDATE per row). Rows that fail keep their edits.
    func saveAll(confirmed: Bool = false) {
        guard !saving, !edits.isEmpty else { return }
        if conn.isProd, !confirmed {
            pendingConfirm = PendingConfirm(title: "Save \(editCount) change(s) to production \(conn.name)?",
                                            details: ["Rows are updated by primary key in \(table ?? "this table")."], button: "Save to Production") { [weak self] in
                self?.saveAll(confirmed: true)
            }
            return
        }
        saving = true; error = nil
        Task {
            defer { saving = false }
            for (row, changes) in edits.sorted(by: { $0.key < $1.key }) {
                do { try await save(row: row, changes: changes); edits[row] = nil }
                catch { self.error = "Row \(offset + row + 1): \(error.localizedDescription)"; return }
            }
        }
    }

    func save(row: Int, changes: [Int: String?]) async throws {
        guard readOnlyReason == nil, let table, row < result.rows.count, !changes.isEmpty else { return }
        let r = result.rows[row]
        let key = primaryKey.map { k in (k, r[result.columns.firstIndex(of: k)!]) }
        let set = changes.sorted { $0.key < $1.key }.map { (result.columns[$0.key], $0.value) }
        let n = try await withCheckedThrowingContinuation { c in
            queue.async { [db] in c.resume(with: Result { try db.update(table, set: set, key: key) }) }
        }
        guard n == 1 else { throw DBError(n == 0 ? "No row matched (changed or deleted meanwhile?)" : "\(n) rows matched the primary key") }
        var updated = result.rows[row]
        for (i, v) in changes { updated[i] = v }
        result.rows[row] = updated
        result.id = UUID() // grid redraws the edited cells
    }

    /// Sidebar structure: column list for a table, fetched on the session queue.
    func columns(_ table: String, done: @escaping ([ColumnInfo]) -> Void) {
        queue.async { [db] in
            let cols = (try? db.columns(table)) ?? []
            DispatchQueue.main.async { done(cols) }
        }
    }

    /// Bypasses the serial queue on purpose: the query is blocking it.
    func cancel() { DispatchQueue.global().async { [db] in db.cancel() } }

    var canPage: Bool { table != nil && conn.kind != .redis }
    var hasNextPage: Bool { canPage && result.rows.count == pageSize }
    func page(_ delta: Int) {
        guard let table, canPage else { return }
        let o = max(0, offset + delta * pageSize)
        // Same query on another page, so its WHERE and ORDER BY stay.
        if let q = browsed?.query, let p = SimpleSelect.paged(q, offset: o) { browsed = (p, table, o); sql = p; run() }
        else { browse(table, offset: o) }
    }

    /// The table a query names, as the sidebar lists it when it's the same table (default schema /
    /// current database dropped), so foreign keys match; otherwise exactly as written.
    func editableTable(_ written: String) -> String? {
        let parts = written.split(separator: ".").map(String.init)
        let home = switch conn.kind { case .postgres: "public"; case .mysql: conn.database; case .sqlite: "main"; case .redis: "" }
        if parts.count == 2, parts[0] == home, tables.contains(parts[1]) { return parts[1] }
        return written
    }

    /// Current header sort of the result: column index and direction, read from its ORDER BY.
    var sortOrder: (column: Int, ascending: Bool)? {
        guard table != nil, let q = browsed?.query, let s = SimpleSelect.sort(q), let i = result.columns.firstIndex(of: s.column) else { return nil }
        return (i, s.ascending)
    }

    /// Header click: sort by that column, ascending first, then descending; back to the first page.
    func sort(by column: Int) {
        guard let table, let q = browsed?.query, column < result.columns.count, conn.kind != .redis else { return }
        guard !blockedByEdits() else { return }
        let name = result.columns[column]
        let ascending = sortOrder.map { !($0.column == column && $0.ascending) } ?? true
        let quoted = conn.kind == .mysql ? MySQLDB.ident(name) : quoteIdent(name)
        var s = SimpleSelect.sorted(q, by: quoted, ascending: ascending)
        if let p = SimpleSelect.paged(s, offset: 0) { s = p }
        browsed = (s, table, 0); sql = s; run()
    }

    func browse(_ table: String, offset: Int = 0) {
        queue.async { [db] in
            let q = Result { try db.browseQuery(table, offset: offset) }
            DispatchQueue.main.async {
                switch q {
                case .success(let v): self.browsed = (v, table, offset); self.sql = v; self.run()
                case .failure(let e): self.error = e.localizedDescription
                }
            }
        }
    }
}
