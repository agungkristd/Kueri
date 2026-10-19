import Foundation
import SQLite3
import CPQ

struct QueryResult {
    var id = UUID() // lets the grid skip reloads when nothing new arrived; renew after edits
    var columns: [String] = []
    var types: [String] = [] // per column; may be empty (e.g. Redis)
    var rows = Rows()
    var message = ""
    var affected = 0
}

extension QueryResult {
    init(id: UUID = UUID(), columns: [String] = [], types: [String] = [], rows: [[String?]], message: String = "", affected: Int = 0) {
        self.init(id: id, columns: columns, types: types, rows: Rows(rows), message: message, affected: affected)
    }
}

/// Result rows in one block of memory: every cell's UTF-8 bytes back to back, an end offset per
/// cell and a NULL bit per cell. An array of `String?` per row costs 16 bytes a cell plus a heap
/// block for every value longer than 15 bytes; this is the text itself plus about 4 bytes a cell.
/// Reads build the `String` on demand (`cell(_:_:)` for one value, `self[r]` for a row).
struct Rows: RandomAccessCollection, Equatable, ExpressibleByArrayLiteral {
    private var bytes: [UInt8] = []
    private var ends: [UInt32] = []      // cell i is bytes[ends[i - 1] ..< ends[i]]
    private var nulls: [UInt64] = []     // bit i set: cell i is NULL
    private var rowStarts: [UInt32] = [] // first cell of each row (rows may differ in width)

    init() {}
    init(_ rows: [[String?]]) { for r in rows { append(r) } }
    init(arrayLiteral rows: [String?]...) { self.init(rows) }

    var startIndex: Int { 0 }
    var endIndex: Int { rowStarts.count }

    private func cellRange(_ row: Int) -> Range<Int> {
        Int(rowStarts[row]) ..< (row + 1 < rowStarts.count ? Int(rowStarts[row + 1]) : ends.count)
    }
    /// Number of cells in a row.
    func width(_ row: Int) -> Int { cellRange(row).count }

    /// One value without building the whole row; nil for NULL or a column the row doesn't have.
    func cell(_ row: Int, _ column: Int) -> String? {
        let cells = cellRange(row)
        guard column >= 0, column < cells.count else { return nil }
        let i = cells.lowerBound + column
        if nulls[i >> 6] & (1 << UInt64(i & 63)) != 0 { return nil }
        let a = i == 0 ? 0 : Int(ends[i - 1]), b = Int(ends[i])
        return bytes.withUnsafeBufferPointer { String(decoding: UnsafeBufferPointer(rebasing: $0[a..<b]), as: UTF8.self) }
    }

    subscript(row: Int) -> [String?] {
        get { (0..<width(row)).map { cell(row, $0) } }
        set { replace(row, with: newValue) }
    }

    /// Splices the row's bytes in place (same width: the usual cell edit); otherwise rebuilds.
    /// Either way the layout stays canonical, so == can compare storage.
    private mutating func replace(_ row: Int, with values: [String?]) {
        let cells = cellRange(row)
        guard values.count == cells.count else {
            var copy = Rows()
            for r in indices { copy.append(r == row ? values : self[r]) }
            self = copy
            return
        }
        guard !cells.isEmpty else { return }
        let a = cells.lowerBound == 0 ? 0 : Int(ends[cells.lowerBound - 1]), b = Int(ends[cells.upperBound - 1])
        var new: [UInt8] = [], newEnds: [UInt32] = []
        for (k, v) in values.enumerated() {
            let i = cells.lowerBound + k, bit: UInt64 = 1 << UInt64(i & 63)
            if let v { new.append(contentsOf: v.utf8); nulls[i >> 6] &= ~bit } else { nulls[i >> 6] |= bit }
            newEnds.append(UInt32(a + new.count))
        }
        bytes.replaceSubrange(a..<b, with: new)
        ends.replaceSubrange(cells, with: newEnds)
        let shift = Int64(new.count) - Int64(b - a)
        if shift != 0 { for i in cells.upperBound..<ends.count { ends[i] = UInt32(Int64(ends[i]) + shift) } }
    }

    mutating func append(_ row: [String?]) {
        appendRow(row.count) { i, add in if let v = row[i] { var v = v; v.withUTF8 { add($0) } } }
    }

    /// Appends a row of `count` cells. `fill(i, add)` calls `add` with cell i's bytes, or doesn't
    /// call it for NULL; drivers hand over their buffers this way without making Strings.
    mutating func appendRow(_ count: Int, _ fill: (Int, (UnsafeBufferPointer<UInt8>) -> Void) -> Void) {
        rowStarts.append(UInt32(ends.count))
        for i in 0..<count {
            var present = false
            fill(i) { b in bytes.append(contentsOf: b); present = true }
            let cell = ends.count
            if cell >> 6 >= nulls.count { nulls.append(0) }
            if !present { nulls[cell >> 6] |= 1 << UInt64(cell & 63) }
            ends.append(UInt32(bytes.count))
        }
    }

    static func += (lhs: inout Rows, rhs: [[String?]]) { for r in rhs { lhs.append(r) } }
    static func == (lhs: Rows, rhs: [[String?]]) -> Bool { lhs == Rows(rhs) }
}

// Limitation: results capped in memory, add paging (LIMIT/OFFSET) if you need to scroll millions of rows
var maxRows: Int { Prefs.maxRows }
/// Rows per page when browsing a table.
// Limitation: LIMIT/OFFSET without ORDER BY, fine for browsing; switch to keyset paging on the PK if deep pages get slow
var pageSize: Int { Prefs.pageSize }

protocol Database: AnyObject {
    func tables() throws -> [String]
    /// Query shown in the editor when a sidebar item is clicked; `offset` drives pagination.
    func browseQuery(_ table: String, offset: Int) throws -> String
    func query(_ sql: String) throws -> QueryResult
    /// Databases the user can switch to (empty = no switcher).
    func databases() throws -> [String]
    /// Stops the running query; must be safe to call from another thread.
    func cancel()
    /// Primary-key columns of a table; empty means rows can't be edited safely.
    func primaryKey(_ table: String) throws -> [String]
    /// Columns in the table's own (ordinal) order, as defined in the database (empty = not expandable).
    func columns(_ table: String) throws -> [ColumnInfo]
    /// Column details for the Structure tab, in database order.
    func structure(_ table: String) throws -> QueryResult
    /// Every foreign key in the current database/schema, for diagrams.
    func foreignKeys() throws -> [ForeignKey]
    /// Indexes of a table: name, algorithm, unique, primary, columns (and definition where known).
    func indexes(_ table: String) throws -> QueryResult
    /// Schemas the sidebar can switch between (Postgres); empty = no schema picker.
    func schemas() throws -> [String]
    /// The exact schema of a sidebar label (nil when the database has no schema picker).
    func schemaOf(_ table: String) -> String?
    /// Server product and version for the connection bar, e.g. "PostgreSQL 16.8".
    func serverVersion() throws -> String
    /// Client connections on the server (nil = not supported, e.g. SQLite).
    func processes() throws -> [ServerProcess]?
    /// Ends a client connection, or with `queryOnly` just its running statement.
    func killProcess(_ id: String, queryOnly: Bool) throws
    /// Table name quoted for this dialect (schema-qualified names keep their schema).
    func quoteTable(_ table: String) -> String
    /// `UPDATE table SET … WHERE key…` with values passed safely (bound or hex-encoded).
    /// Returns the number of rows matched.
    func update(_ table: String, set: [(String, String?)], key: [(String, String?)]) throws -> Int
    /// `DELETE FROM table WHERE key…`, values passed like `update`. Returns the number of rows deleted.
    func delete(_ table: String, key: [(String, String?)]) throws -> Int
    /// Browse query for the rows whose `column` equals `value` (following a foreign key).
    func filterQuery(_ table: String, column: String, value: String) -> String
}

extension Database {
    func databases() throws -> [String] { [] }
    func cancel() {}
    func primaryKey(_ table: String) throws -> [String] { [] }
    func columns(_ table: String) throws -> [ColumnInfo] { [] }
    func structure(_ table: String) throws -> QueryResult {
        let cols = try columns(table)
        return QueryResult(columns: ["#", "column_name", "data_type", "primary_key"],
                           rows: cols.enumerated().map { [String($0.offset + 1), $0.element.name, $0.element.type, $0.element.isPrimaryKey ? "YES" : ""] })
    }
    func foreignKeys() throws -> [ForeignKey] { [] }
    func indexes(_ table: String) throws -> QueryResult { QueryResult() }
    func schemas() throws -> [String] { [] }
    func schemaOf(_ table: String) -> String? { nil }
    func serverVersion() throws -> String { "" }
    func processes() throws -> [ServerProcess]? { nil }
    func killProcess(_ id: String, queryOnly: Bool) throws { throw DBError("Not supported for this database") }
    func quoteTable(_ table: String) -> String { quoteIdent(table) }
    func update(_ table: String, set: [(String, String?)], key: [(String, String?)]) throws -> Int {
        throw DBError("Editing is not supported for this database")
    }
    func delete(_ table: String, key: [(String, String?)]) throws -> Int {
        throw DBError("Deleting rows is not supported for this database")
    }
    func filterQuery(_ table: String, column: String, value: String) -> String {
        "SELECT * FROM \(quoteTable(table)) WHERE \(quoteIdent(column)) = '\(value.replacingOccurrences(of: "'", with: "''"))' LIMIT \(pageSize)"
    }
    func firstColumn(_ sql: String) throws -> [String] { try query(sql).rows.compactMap { $0.first ?? nil } }
}

struct ForeignKey: Hashable {
    let fromTable: String, fromColumn: String, toTable: String, toColumn: String
}

struct ColumnInfo: Hashable {
    let name: String
    let type: String
    let isPrimaryKey: Bool
}

/// Rows of (name, type, "1"/"0" pk flag), already in the table's ordinal order → ColumnInfo.
/// Never re-sorted: the database's column order is the order users expect.
func columnInfos(_ rows: [[String?]]) -> [ColumnInfo] {
    rows.map { ColumnInfo(name: $0[0] ?? "", type: $0[1] ?? "", isPrimaryKey: ["1", "t", "true"].contains($0[2] ?? "")) }
}

/// Encryption for a connection. `prefer` = TLS when the server offers it (Postgres' default).
enum TLSMode: String, Codable, CaseIterable {
    case off, prefer, required, verify
    var title: String {
        switch self {
        case .off: "Off"
        case .prefer: "Prefer (if available)"
        case .required: "Required (encrypt, don't check certificate)"
        case .verify: "Verify (encrypt and check certificate + host)"
        }
    }
}

struct DBError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

func quoteIdent(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

/// Sidebar names are display text ("users", "audit.logs"). Each is recorded with its exact
/// (schema, name) when the table list loads, so quoting/DDL never re-splits the text on "." —
/// a table literally named "audit.logs" in the default schema must not become audit → logs.
/// Thread-safe: the session queue rebuilds it while the main thread reads it (connection bar,
/// quoting for the details popover), so every access goes through the lock.
final class TableNames: @unchecked Sendable {
    private var exact: [String: (schema: String, name: String)] = [:]
    private let lock = NSLock()

    /// Bare name in the default schema, `schema.name` elsewhere; if either part contains a dot or a
    /// quote the label is fully quoted (`"a.b"."c"`), which can't collide with any other table.
    static func display(schema: String, name: String, defaultSchema: String?) -> String {
        if schema.contains(where: { $0 == "." || $0 == "\"" }) || name.contains(where: { $0 == "." || $0 == "\"" }) {
            return quoteIdent(schema) + "." + quoteIdent(name)
        }
        return schema == defaultSchema ? name : schema + "." + name
    }

    func record(_ rows: [(schema: String, name: String)], defaultSchema: String?) -> [String] {
        var labels = rows.map { Self.display(schema: $0.schema, name: $0.name, defaultSchema: defaultSchema) }
        // Any label still shared by two tables (shouldn't happen, but never guess) gets the quoted form.
        let counts = Dictionary(labels.map { ($0, 1) }, uniquingKeysWith: +)
        for i in labels.indices where counts[labels[i]]! > 1 {
            labels[i] = quoteIdent(rows[i].schema) + "." + quoteIdent(rows[i].name)
        }
        var map: [String: (schema: String, name: String)] = [:]
        for (label, r) in zip(labels, rows) { map[label] = r }
        lock.withLock { exact = map }
        return labels
    }

    /// Exact parts for a sidebar name; names typed by the user (not in the list) split on the first dot.
    func parts(_ display: String, defaultSchema: String?) -> (schema: String?, name: String) {
        if let e = lock.withLock({ exact[display] }) { return (e.schema, e.name) }
        let p = display.split(separator: ".", maxSplits: 1).map(String.init)
        return p.count == 2 ? (p[0], p[1]) : (defaultSchema, display)
    }
}

// MARK: SQLite (system libsqlite3, no deps)

final class SQLiteDB: Database {
    private var db: OpaquePointer?

    init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
            // No close here: the object is fully initialized, so deinit closes it.
            throw DBError(String(cString: sqlite3_errmsg(db)))
        }
    }
    deinit { sqlite3_close(db) }
    func cancel() { sqlite3_interrupt(db) }
    func serverVersion() throws -> String { "SQLite " + String(cString: sqlite3_libversion()) }

    func primaryKey(_ t: String) throws -> [String] {
        // PRAGMA table_info columns: cid, name, type, notnull, dflt_value, pk (1-based order)
        try query("PRAGMA table_info(\(quote(table: t)))").rows
            .compactMap { r in r[5].flatMap(Int.init).flatMap { $0 > 0 ? ($0, r[1] ?? "") : nil } }
            .sorted { $0.0 < $1.0 }.map(\.1)
    }

    func quoteTable(_ t: String) -> String { quote(table: t) }

    func structure(_ t: String) throws -> QueryResult {
        // PRAGMA table_info: cid, name, type, notnull, dflt_value, pk
        let r = try query("PRAGMA table_info(\(quote(table: t)))")
        return QueryResult(columns: ["#", "column_name", "data_type", "is_nullable", "column_default", "primary_key"],
                           rows: r.rows.map { [String((Int($0[0] ?? "0") ?? 0) + 1), $0[1], $0[2],
                                               $0[3] == "1" ? "NO" : "YES", $0[4], ($0[5].flatMap(Int.init) ?? 0) > 0 ? "YES" : ""] })
    }

    func indexes(_ t: String) throws -> QueryResult {
        // PRAGMA index_list: seq, name, unique, origin (c = CREATE INDEX, u = UNIQUE, pk), partial
        let list = try query("PRAGMA index_list(\(quote(table: t)))").rows
        return QueryResult(columns: ["index_name", "index_algorithm", "is_unique", "is_primary", "columns"], rows: try list.map { r in
            let name = r[1] ?? ""
            let cols = try query("PRAGMA index_info(\(quoteIdent(name)))").rows.compactMap { $0[2] }.joined(separator: ", ")
            return [name, "BTREE", r[2] == "1" ? "TRUE" : "FALSE", r[3] == "pk" ? "TRUE" : "FALSE", cols]
        })
    }

    func foreignKeys() throws -> [ForeignKey] {
        // PRAGMA foreign_key_list: id, seq, table, from, to, on_update, on_delete, match
        try tables().flatMap { t in
            try query("PRAGMA foreign_key_list(\(quote(table: t)))").rows.map {
                ForeignKey(fromTable: t, fromColumn: $0[3] ?? "", toTable: $0[2] ?? "", toColumn: $0[4] ?? "")
            }
        }
    }

    func columns(_ t: String) throws -> [ColumnInfo] {
        columnInfos(try query("PRAGMA table_info(\(quote(table: t)))").rows.map {
            [$0[1], ($0[2] ?? "").lowercased(), ($0[5].flatMap(Int.init) ?? 0) > 0 ? "1" : "0"]
        })
    }

    func update(_ t: String, set: [(String, String?)], key: [(String, String?)]) throws -> Int {
        try exec("UPDATE \(quote(table: t)) SET " + set.map { "\(quoteIdent($0.0)) = ?" }.joined(separator: ", ")
            + " WHERE " + key.map { "\(quoteIdent($0.0)) IS ?" }.joined(separator: " AND "), set.map(\.1) + key.map(\.1))
    }

    func delete(_ t: String, key: [(String, String?)]) throws -> Int {
        try exec("DELETE FROM \(quote(table: t)) WHERE " + key.map { "\(quoteIdent($0.0)) IS ?" }.joined(separator: " AND "), key.map(\.1))
    }

    /// One statement with bound values; returns the rows changed.
    private func exec(_ sql: String, _ params: [String?]) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw DBError(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, v) in params.enumerated() {
            // Explicit byte length: values may contain NUL, which -1 ("until NUL") would cut off.
            if let v { sqlite3_bind_text(stmt, Int32(i + 1), v, Int32(v.utf8.count), transient) } else { sqlite3_bind_null(stmt, Int32(i + 1)) }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DBError(String(cString: sqlite3_errmsg(db))) }
        return Int(sqlite3_changes(db))
    }

    func tables() throws -> [String] {
        try query("SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name")
            .rows.compactMap { $0.first ?? nil }
    }

    func quote(table: String) -> String { quoteIdent(table) }
    func browseQuery(_ t: String, offset: Int) -> String { "SELECT * FROM \(quote(table: t)) LIMIT \(pageSize) OFFSET \(offset)" }

    func query(_ sql: String) throws -> QueryResult {
        var res = QueryResult()
        var tail: UnsafePointer<CChar>?
        let cstr = strdup(sql)!
        defer { free(cstr) }
        tail = UnsafePointer(cstr)
        // Run every statement; keep the last one that returned columns.
        while let t = tail, t.pointee != 0 {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, t, -1, &stmt, &tail) == SQLITE_OK else {
                throw DBError(String(cString: sqlite3_errmsg(db)))
            }
            guard let s = stmt else { continue } // whitespace/comment only
            defer { sqlite3_finalize(s) }
            let n = sqlite3_column_count(s)
            var cur = QueryResult(columns: (0..<n).map { String(cString: sqlite3_column_name(s, $0)) },
                                  types: (0..<n).map { sqlite3_column_decltype(s, $0).map { String(cString: $0).lowercased() } ?? "" })
            while true {
                let rc = sqlite3_step(s)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw DBError(String(cString: sqlite3_errmsg(db))) }
                if cur.rows.count >= maxRows { cur.message = "Showing first \(maxRows) rows"; break }
                cur.rows.appendRow(Int(n)) { i, add in
                    let i = Int32(i)
                    switch sqlite3_column_type(s, i) {
                    case SQLITE_NULL: break
                    case SQLITE_BLOB: var t = "<blob \(sqlite3_column_bytes(s, i)) bytes>"; t.withUTF8 { add($0) }
                    default: // by byte count, not C string: text containing NUL must survive intact
                        let n = Int(sqlite3_column_bytes(s, i))
                        add(UnsafeBufferPointer(start: sqlite3_column_text(s, i), count: n))
                    }
                }
            }
            if n > 0 { res = cur } else { res.message = "\(sqlite3_changes(db)) row(s) affected" }
        }
        return res
    }
}

// MARK: PostgreSQL (libpq)

final class PostgresDB: Database {
    private let conn: OpaquePointer

    /// `allowCleartextPassword`: by default the server may not ask for the password in clear text
    /// (`require_auth=!password`), so a spoofed server can't collect it; scram, md5 and trust still work.
    /// `via`: connect to this address instead (an SSH tunnel's local end); `host` is still used for
    /// TLS certificate checks.
    init(host: String, port: String, user: String, password: String, database: String, allowCleartextPassword: Bool = false,
         tls: TLSMode = .prefer, via: (host: String, port: String)? = nil) throws {
        func kv(_ k: String, _ v: String) -> String {
            v.isEmpty ? "" : "\(k)='\(v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))' "
        }
        let info = kv("host", host) + (via.map { kv("hostaddr", $0.host) + kv("port", $0.port) } ?? kv("port", port))
            + kv("user", user) + kv("password", password)
            + kv("dbname", database) + "connect_timeout=10 application_name=Kueri"
            + (allowCleartextPassword ? "" : " require_auth=!password")
            + " sslmode=" + ["off": "disable", "prefer": "prefer", "required": "require", "verify": "verify-full"][tls.rawValue]!
            + (tls == .verify ? " sslrootcert=system" : "") // the system's trusted CAs (libpq 16+)
        conn = PQconnectdb(info)
        if PQstatus(conn) != CONNECTION_OK {
            // No PQfinish here: the object is fully initialized, so deinit frees it (double free otherwise).
            throw DBError(String(cString: PQerrorMessage(conn)))
        }
        // ~600 rows once per connection; lets the detail panel show int8/varchar/jsonb…
        for row in (try? query("SELECT oid::text, typname FROM pg_type"))?.rows ?? [] {
            if let o = row[0].flatMap(UInt32.init), let n = row[1] { typeNames[o] = n }
        }
    }
    deinit { PQfinish(conn) }
    private var typeNames: [UInt32: String] = [:]
    private let names = TableNames()

    func tables() throws -> [String] {
        let rows = try query("""
            SELECT s, n FROM (
                SELECT table_schema AS s, table_name AS n FROM information_schema.tables
                WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
                UNION ALL -- materialized views aren't in information_schema.tables
                SELECT schemaname, matviewname FROM pg_matviews
            ) t
            ORDER BY s <> 'public', s, n
            """).rows.map { (schema: $0[0] ?? "", name: $0[1] ?? "") }
        return names.record(rows, defaultSchema: "public")
    }

    func schemaOf(_ table: String) -> String? { names.parts(table, defaultSchema: "public").schema }
    func indexes(_ t: String) throws -> QueryResult {
        let rel = "'" + quoteTable(t).replacingOccurrences(of: "'", with: "''") + "'::regclass"
        return try query("""
            SELECT ic.relname AS index_name, upper(am.amname) AS index_algorithm,
                   CASE WHEN ix.indisunique THEN 'TRUE' ELSE 'FALSE' END AS is_unique,
                   CASE WHEN ix.indisprimary THEN 'TRUE' ELSE 'FALSE' END AS is_primary,
                   (SELECT string_agg(coalesce(a.attname, '(expression)'), ', ' ORDER BY k.ord)
                      FROM unnest(ix.indkey) WITH ORDINALITY k(attnum, ord)
                      LEFT JOIN pg_attribute a ON a.attrelid = ix.indrelid AND a.attnum = k.attnum) AS columns,
                   pg_get_indexdef(ix.indexrelid) AS definition
            FROM pg_index ix JOIN pg_class ic ON ic.oid = ix.indexrelid JOIN pg_am am ON am.oid = ic.relam
            WHERE ix.indrelid = \(rel) ORDER BY ix.indisprimary DESC, ic.relname
            """)
    }

    func serverVersion() throws -> String {
        // "16.8 (Debian 16.8-1.pgdg120+1)" → "PostgreSQL 16.8"
        let v = (try firstColumn("SHOW server_version").first ?? "").split(separator: " ").first.map(String.init) ?? ""
        return "PostgreSQL " + v
    }

    func schemas() throws -> [String] {
        try firstColumn("""
            SELECT nspname FROM pg_namespace
            WHERE nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema'
            ORDER BY nspname <> 'public', nspname
            """)
    }

    func browseQuery(_ t: String, offset: Int) -> String { "SELECT * FROM \(quote(table: t)) LIMIT \(pageSize) OFFSET \(offset)" }

    func databases() throws -> [String] {
        try firstColumn("SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY 1")
    }

    func quote(table: String) -> String {
        let p = names.parts(table, defaultSchema: "public")
        return quoteIdent(p.schema ?? "public") + "." + quoteIdent(p.name)
    }

    /// Streams rows in chunks so memory stays bounded however large the result is.
    /// Rows past `maxRows` are received and discarded (not cancelled server-side, which would
    /// abort an open transaction); the Stop button cancels explicitly.
    func query(_ sql: String) throws -> QueryResult {
        guard PQsendQuery(conn, sql) == 1 else { throw DBError(String(cString: PQerrorMessage(conn))) }
        PQsetChunkedRowsMode(conn, 1000)
        var last = QueryResult(), cur: QueryResult?, total = 0
        var failure: DBError?
        // Must drain every result before returning, or the connection stays busy.
        while let r = PQgetResult(conn) {
            defer { PQclear(r) }
            switch PQresultStatus(r) {
            case PGRES_TUPLES_CHUNK, PGRES_TUPLES_OK:
                let nf = PQnfields(r), nt = PQntuples(r)
                if cur == nil {
                    cur = QueryResult(columns: (0..<nf).map { String(cString: PQfname(r, $0)) },
                                      types: (0..<nf).map { typeNames[PQftype(r, $0)] ?? "" })
                    total = 0
                }
                total += Int(nt)
                for t in 0..<nt where cur!.rows.count < maxRows {
                    cur!.rows.appendRow(Int(nf)) { i, add in // libpq's own buffers, no String per cell
                        let f = Int32(i)
                        guard PQgetisnull(r, t, f) == 0 else { return }
                        PQgetvalue(r, t, f).withMemoryRebound(to: UInt8.self, capacity: 1) {
                            add(UnsafeBufferPointer(start: $0, count: Int(PQgetlength(r, t, f))))
                        }
                    }
                }
                if PQresultStatus(r) == PGRES_TUPLES_OK { // end of this statement's rows
                    if total > maxRows { cur!.message = "Showing first \(maxRows) of \(total) rows" }
                    last = cur!
                    cur = nil
                }
            case PGRES_COMMAND_OK:
                last = QueryResult(message: String(cString: PQcmdStatus(r)))
            default:
                failure = failure ?? DBError(String(cString: PQresultErrorMessage(r)))
            }
        }
        if let failure { throw failure }
        return last
    }

    func primaryKey(_ t: String) throws -> [String] {
        try execParams("""
            SELECT a.attname FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
            WHERE i.indrelid = $1::regclass AND i.indisprimary
            ORDER BY array_position(i.indkey::int2[], a.attnum)
            """, [quote(table: t)]).rows.compactMap { $0.first ?? nil }
    }

    func quoteTable(_ t: String) -> String { quote(table: t) }

    func structure(_ t: String) throws -> QueryResult {
        let cols = ["#", "column_name", "data_type", "full_type", "is_nullable", "column_default", "comment"]
        return QueryResult(columns: cols, rows: try execParams("""
            SELECT a.attnum::text, a.attname, t.typname, format_type(a.atttypid, a.atttypmod),
                   CASE WHEN a.attnotnull THEN 'NO' ELSE 'YES' END,
                   pg_get_expr(d.adbin, d.adrelid), col_description(a.attrelid, a.attnum)
            FROM pg_attribute a
            JOIN pg_type t ON t.oid = a.atttypid
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = $1::regclass AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """, [quote(table: t)]).rows)
    }

    func foreignKeys() throws -> [ForeignKey] {
        // Table names built with the same rule as the sidebar's (TableNames.display).
        try execParams("""
            SELECT n1.nspname, c1.relname, a1.attname, n2.nspname, c2.relname, a2.attname
            FROM pg_constraint con
            JOIN pg_class c1 ON c1.oid = con.conrelid JOIN pg_namespace n1 ON n1.oid = c1.relnamespace
            JOIN pg_class c2 ON c2.oid = con.confrelid JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
            CROSS JOIN LATERAL unnest(con.conkey, con.confkey) AS k(a, b)
            JOIN pg_attribute a1 ON a1.attrelid = con.conrelid AND a1.attnum = k.a
            JOIN pg_attribute a2 ON a2.attrelid = con.confrelid AND a2.attnum = k.b
            WHERE con.contype = 'f'
            """, []).rows.map {
                ForeignKey(fromTable: TableNames.display(schema: $0[0] ?? "", name: $0[1] ?? "", defaultSchema: "public"), fromColumn: $0[2] ?? "",
                           toTable: TableNames.display(schema: $0[3] ?? "", name: $0[4] ?? "", defaultSchema: "public"), toColumn: $0[5] ?? "")
            }
    }

    func columns(_ t: String) throws -> [ColumnInfo] {
        columnInfos(try execParams("""
            SELECT a.attname, t.typname,
                   COALESCE(a.attnum = ANY(i.indkey), false)::text
            FROM pg_attribute a
            JOIN pg_type t ON t.oid = a.atttypid
            LEFT JOIN pg_index i ON i.indrelid = a.attrelid AND i.indisprimary
            WHERE a.attrelid = $1::regclass AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """, [quote(table: t)]).rows.map { [$0[0], $0[1], $0[2] == "true" ? "1" : "0"] })
    }

    func update(_ t: String, set: [(String, String?)], key: [(String, String?)]) throws -> Int {
        var n = 0
        func p() -> String { n += 1; return "$\(n)" }
        let sql = "UPDATE \(quote(table: t)) SET " + set.map { "\(quoteIdent($0.0)) = \(p())" }.joined(separator: ", ")
            + " WHERE " + key.map { "\(quoteIdent($0.0)) IS NOT DISTINCT FROM \(p())" }.joined(separator: " AND ")
        return try execParams(sql, set.map(\.1) + key.map(\.1)).affected
    }

    func delete(_ t: String, key: [(String, String?)]) throws -> Int {
        var n = 0
        let sql = "DELETE FROM \(quote(table: t)) WHERE "
            + key.map { n += 1; return "\(quoteIdent($0.0)) IS NOT DISTINCT FROM $\(n)" }.joined(separator: " AND ")
        return try execParams(sql, key.map(\.1)).affected
    }

    /// Parameters go over the wire separately from the SQL text (no quoting/injection issues).
    private func execParams(_ sql: String, _ params: [String?]) throws -> (rows: [[String?]], affected: Int) {
        let cs = params.map { $0.flatMap { strdup($0) } }
        defer { cs.forEach { free($0) } }
        let ptrs = cs.map { UnsafePointer($0) }
        guard let r = PQexecParams(conn, sql, Int32(params.count), nil, ptrs, nil, nil, 0) else {
            throw DBError(String(cString: PQerrorMessage(conn)))
        }
        defer { PQclear(r) }
        let st = PQresultStatus(r)
        guard st == PGRES_TUPLES_OK || st == PGRES_COMMAND_OK else { throw DBError(String(cString: PQresultErrorMessage(r))) }
        let rows = (0..<PQntuples(r)).map { t in (0..<PQnfields(r)).map { PQgetisnull(r, t, $0) == 1 ? nil : String(cString: PQgetvalue(r, t, $0)) } }
        return (rows, Int(String(cString: PQcmdTuples(r))) ?? 0)
    }

    /// Thread-safe: called from the UI while `query` is running on the session queue.
    func cancel() {
        let c = PQcancelCreate(conn)
        PQcancelBlocking(c)
        PQcancelFinish(c)
    }
}

// Run: Kueri.app/Contents/MacOS/Kueri --selftest
func selfTest() {
    let db = try! SQLiteDB(path: ":memory:")
    let r = try! db.query("CREATE TABLE \"a\"\"b\"(x, y); INSERT INTO \"a\"\"b\" VALUES (1, NULL), ('é', 2); SELECT * FROM \(db.quote(table: "a\"b"));")
    assert(r.columns == ["x", "y"])
    assert(r.rows == [["1", nil], ["é", "2"]])
    assert(try! db.tables() == ["a\"b"])
    assert((try? db.query("SELEC")) == nil)
    assert(RedisDB.tokenize(#"SET "a b" 'c d' "x\"y" e"#) == ["SET", "a b", "c d", "x\"y", "e"])
    assert(RedisDB.tokenize(try! RedisDB.quote("k \"1\"")) == ["k \"1\""])
    // A key can't smuggle a second Redis command through a line break.
    let evil = try! RedisDB.quote("x\nFLUSHDB\r\nDEL y")
    assert(!evil.contains(where: \.isNewline) && RedisDB.tokenize(evil) == ["x\nFLUSHDB\r\nDEL y"])
    assert((try? RedisDB.quote("a\u{2028}FLUSHALL")) == nil && (try? RedisDB.quote("a\u{0}b")) == nil)
    // Sidebar names map to exact (schema, name); a dotted name in the default schema stays one name.
    var tn = TableNames()
    let shown = tn.record([("public", "audit.logs"), ("audit", "logs"), ("public", "users"), ("a.b", "c"), ("a", "b.c")], defaultSchema: "public")
    assert(shown == [#""public"."audit.logs""#, "audit.logs", "users", #""a.b"."c""#, #""a"."b.c""#])
    assert(Set(shown).count == shown.count) // every label unique
    assert(tn.parts(#""public"."audit.logs""#, defaultSchema: "public") == ("public", "audit.logs"))
    assert(tn.parts(#""a.b"."c""#, defaultSchema: "public") == ("a.b", "c") && tn.parts(#""a"."b.c""#, defaultSchema: "public") == ("a", "b.c"))
    assert(tn.parts("audit.logs", defaultSchema: "public") == ("audit", "logs"))
    assert(tn.parts("users", defaultSchema: "public") == ("public", "users"))
    assert(MySQLDB.scramble("mysql_native_password", "", [1, 2]) == [])
    _ = try! db.query("CREATE TABLE p(id INTEGER PRIMARY KEY, v TEXT, w TEXT); INSERT INTO p VALUES (1, 'a', 'b'), (2, 'c', 'd')")
    assert(try! db.primaryKey("p") == ["id"])
    assert(try! db.update("p", set: [("v", "it's; DROP TABLE p;--"), ("w", nil)], key: [("id", "1")]) == 1)
    assert(try! db.query("SELECT v, w FROM p ORDER BY id").rows == [["it's; DROP TABLE p;--", nil], ["c", "d"]])
    assert(try! db.update("p", set: [("v", "x")], key: [("id", "9")]) == 0)
    assert(prettyJSON(#"{"b":1,"a":[1,{"x":"}, \"y"}],"e":{},"f":[]}"#) == """
        {
          "b": 1,
          "a": [
            1,
            {
              "x": "}, \\"y"
            }
          ],
          "e": {},
          "f": []
        }
        """)
    assert(prettyJSON("{not json") == nil && prettyJSON("42") == nil)
    // Failed connects must throw, not crash (double free in deinit)
    assert((try? PostgresDB(host: "127.0.0.1", port: "1", user: "x", password: "x", database: "x")) == nil)
    assert((try? SQLiteDB(path: "/nonexistent-dir/x.db")) == nil)
    // Connections saved before the password field existed must still load; password round-trips.
    let old = #"[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","name":"local","kind":"PostgreSQL","host":"localhost","port":"5432","user":"postgres","database":"postgres","path":""}]"#
    let decoded = try! JSONDecoder().decode([Conn].self, from: Data(old.utf8))
    assert(decoded.count == 1 && decoded[0].name == "local" && decoded[0].password == nil)
    var withPw = decoded[0]; withPw.password = "s3cr'et"
    assert(try! JSONDecoder().decode(Conn.self, from: JSONEncoder().encode(withPw)).password == "s3cr'et")
    // Tab restore picks the saved connection by id and reopens the last database.
    let saved = [decoded[0]]
    assert(RootView.restorable(saved, connID: saved[0].id.uuidString, database: "app_dev")?.database == "app_dev")
    assert(RootView.restorable(saved, connID: saved[0].id.uuidString, database: "")?.database == "postgres")
    assert(RootView.restorable(saved, connID: "deleted-or-empty", database: "x") == nil)
    // Highlighting only colors: the text is identical to the formatted JSON.
    let pretty = prettyJSON(#"{"id":"hlz8\"x","n":-1.5e3,"ok":true,"z":null,"a":[{"k":"v: x"}]}"#)!
    assert(String(highlightJSON(pretty).characters) == pretty)
    // Search marks every case-insensitive hit and nothing else.
    let m = markMatches(AttributedString(#"{"owner": "x", "OWNER_id": 1}"#), "owner")
    assert(m.runs.filter { $0.backgroundColor != nil }.map { String(m[$0.range].characters) } == ["owner", "OWNER"])
    assert(String(m.characters) == #"{"owner": "x", "OWNER_id": 1}"#)
    // Structure tab + foreign keys (diagram) + quoting.
    _ = try! db.query("PRAGMA foreign_keys = ON; CREATE TABLE parent(id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT 'x'); CREATE TABLE child(id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent(id))")
    let st = try! db.structure("parent")
    assert(st.columns == ["#", "column_name", "data_type", "is_nullable", "column_default", "primary_key"])
    assert(st.rows == [["1", "id", "INTEGER", "YES", nil, "YES"], ["2", "name", "TEXT", "NO", "'x'", ""]])
    assert(try! db.foreignKeys() == [ForeignKey(fromTable: "child", fromColumn: "parent_id", toTable: "parent", toColumn: "id")])
    // Following a foreign key finds the parent row (quotes in values are escaped); delete goes by key.
    _ = try! db.query("INSERT INTO parent(id, name) VALUES (1, 'a'), (2, 'it''s')")
    assert(try! db.query(db.filterQuery("parent", column: "name", value: "it's")).rows == [["2", "it's"]])
    assert(try! db.delete("parent", key: [("id", "1")]) == 1 && db.delete("parent", key: [("id", "1")]) == 0)
    assert(try! db.query("SELECT id FROM parent").rows == [["2"]])
    _ = try! db.query("DELETE FROM parent")
    // Hand-written single-table queries: detected, sorted in place (WHERE and paging kept), paged.
    let q1 = #"SELECT * FROM "public"."lesson_schedules" order by 1 desc LIMIT 100 OFFSET 0"#
    assert(SimpleSelect.table(q1) == "public.lesson_schedules")
    assert(SimpleSelect.table("select * from users where name = 'x';") == "users")
    for q in ["SELECT id FROM users", "SELECT * FROM a JOIN b ON true", "SELECT * FROM a, b", "SELECT * FROM a GROUP BY id",
              "SELECT * FROM a; DELETE FROM a", "SELECT * FROM a UNION SELECT * FROM b"] { assert(SimpleSelect.table(q) == nil, q) }
    let s1 = SimpleSelect.sorted(q1, by: #""id""#, ascending: true)
    assert(s1 == #"SELECT * FROM "public"."lesson_schedules" ORDER BY "id" ASC LIMIT 100 OFFSET 0"#, s1)
    assert(SimpleSelect.sort(s1)! == ("id", true))
    assert(SimpleSelect.sort(SimpleSelect.sorted(s1, by: "`id`", ascending: false))! == ("id", false))
    assert(SimpleSelect.sorted("SELECT * FROM t WHERE a = 1", by: "a", ascending: false) == "SELECT * FROM t WHERE a = 1 ORDER BY a DESC")
    assert(SimpleSelect.paged(s1, offset: 200) == #"SELECT * FROM "public"."lesson_schedules" ORDER BY "id" ASC LIMIT 100 OFFSET 200"#)
    assert(SimpleSelect.offset("SELECT * FROM t LIMIT 100 OFFSET 300;") == 300 && SimpleSelect.paged("SELECT * FROM t", offset: 1) == nil)
    assert(db.quoteTable(#"we"ird"#) == #""we""ird""#)
    // Structure view keeps the table's own column order (not alphabetical).
    _ = try! db.query("CREATE TABLE ord(zeta TEXT, alpha INTEGER PRIMARY KEY, mid TEXT)")
    assert(try! db.columns("ord").map(\.name) == ["zeta", "alpha", "mid"])
    assert(try! db.columns("ord")[1] == ColumnInfo(name: "alpha", type: "integer", isPrimaryKey: true))
    // Autocomplete: referenced tables and aliases.
    let refs = SQLCompleter.referencedTables("select u.na from users u join orders AS o on o.uid = u.id where")
    assert(refs.tables == ["users", "orders"] && refs.aliases == ["u": "users", "o": "orders"])
    assert(SQLCompleter.referencedTables("SELECT * FROM public.users WHERE").tables == ["public.users"])
    // Rename migration: old connections/history are copied once, existing new data is never overwritten.
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kueri-mig-\(UUID())")
    let oldD = UserDefaults(suiteName: "kueri-test-old-\(UUID())")!, newD = UserDefaults(suiteName: "kueri-test-new-\(UUID())")!
    oldD.set(Data("[1]".utf8), forKey: "conns"); oldD.set(false, forKey: "showEditor")
    try! FileManager.default.createDirectory(at: tmp.appendingPathComponent("LiteTable"), withIntermediateDirectories: true)
    try! Data("[]".utf8).write(to: tmp.appendingPathComponent("LiteTable/history.json"))
    LegacyMigration.run(defaults: newD, old: oldD, support: tmp)
    assert(newD.data(forKey: "conns") == Data("[1]".utf8) && newD.bool(forKey: "showEditor") == false)
    assert(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("Kueri/history.json").path))
    newD.set(Data("[2]".utf8), forKey: "conns"); LegacyMigration.run(defaults: newD, old: oldD, support: tmp)
    assert(newD.data(forKey: "conns") == Data("[2]".utf8)) // never overwrites
    // Hostile server replies are rejected, not crashed on.
    assert((try? RedisDB.length("9223372036854775807", max: RedisDB.maxBulk)) == nil)
    assert((try? RedisDB.length("-5", max: RedisDB.maxBulk)) == nil && (try! RedisDB.length("-1", max: 10)) == nil)
    assert(try! RedisDB.length("42", max: RedisDB.maxBulk) == 42)
    assert((try? MySQLDB.checkScramble([])) == nil && (try? MySQLDB.checkScramble(Array(repeating: 1, count: 20))) != nil)
    var huge = Reader([0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    assert(huge.lenenc() == Int.max) // clamped, no trap
    var r2 = Reader([3, 65, 66, 67, 0xFE, 1]); assert(r2.take(r2.lenenc()) == [65, 66, 67])
    _ = r2.take(Int.max); r2.skip(Int.max); assert(r2.take(5) == [] && r2.peek == 0) // saturates, no overflow
    // Text with an embedded NUL reads back whole, and an edit keyed on it hits that row only.
    _ = try! db.query("CREATE TABLE nul(k TEXT PRIMARY KEY, v TEXT); INSERT INTO nul VALUES ('a' || char(0) || 'b', 'x'), ('a', 'y')")
    let nulKey = try! db.query("SELECT k FROM nul WHERE v = 'x'").rows[0][0]!
    assert(nulKey == "a\u{0}b")
    assert(try! db.update("nul", set: [("v", "edited")], key: [("k", nulKey)]) == 1)
    assert(try! db.query("SELECT v FROM nul ORDER BY v").rows.map { $0[0] } == ["edited", "y"])
    // Credential-bearing statements stay out of the history file.
    for secret in ["AUTH hunter2", "auth default hunter2", "ALTER USER app WITH PASSWORD 'x'", "CREATE USER u IDENTIFIED BY 'x'",
                   "CONFIG SET requirepass x", "ACL SETUSER bob on >pw", "GET a\nAUTH hunter2",
                   "MIGRATE h 6379 k 0 5000 AUTH2 u p", "ALTER USER u IDENTIFIED WITH caching_sha2_password BY 'x'",
                   "select user_password from t"] { assert(QueryHistory.containsSecret(secret)) }
    for plain in ["SELECT * FROM users", "SELECT * FROM authors"] { assert(!QueryHistory.containsSecret(plain)) }
    assert(RedisDB.isLoopback("localhost") && RedisDB.isLoopback("127.0.0.1") && !RedisDB.isLoopback("192.168.1.10"))
    assert((try? RedisDB(host: "192.0.2.1", port: "6379", user: "", password: "pw", database: "0")) == nil) // refused before connecting
    // Production safety: risky statements are found; strings, comments and dollar bodies don't fool it.
    assert(riskyReasons("DELETE FROM t", kind: .postgres).count == 1)
    assert(riskyReasons("delete from t where id = 1", kind: .postgres).isEmpty)
    assert(riskyReasons("UPDATE t SET a = 'where'", kind: .postgres).count == 1) // WHERE inside a string doesn't count
    assert(riskyReasons("SELECT 1; DROP TABLE x; TRUNCATE y", kind: .postgres).count == 2)
    assert(riskyReasons("SELECT 'DROP TABLE x' -- DROP TABLE y\n", kind: .postgres).isEmpty)
    assert(riskyReasons("ALTER TABLE t DROP COLUMN c", kind: .mysql).count == 1)
    assert(riskyReasons("GET a\nFLUSHALL", kind: .redis).count == 1)
    assert(splitSQL("CREATE FUNCTION f() RETURNS int AS $$ BEGIN RETURN 1; END; $$ LANGUAGE plpgsql; SELECT 2").count == 2)
    assert(splitSQL("SELECT 'a;b'; SELECT `c;d`; SELECT \"e;f\"").count == 3)
    assert(splitSQL("DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END //\nDELIMITER ;\nSELECT 3;").count == 2)
    assert(splitSQL("SELECT 1 # x; y\n; SELECT 2", hashComments: true).count == 2 && splitSQL("SELECT j #> '{a}'; SELECT 2").count == 2)
    // Cross-version import: settings unknown to the target server are dropped, others kept.
    let dumpURL = FileManager.default.temporaryDirectory.appendingPathComponent("kueri-filter-\(UUID()).sql")
    try! "SET statement_timeout = 0;\nSET transaction_timeout = 0;\nCREATE TABLE a(x int);\n".write(to: dumpURL, atomically: true, encoding: .utf8)
    let (f16, removed16) = try! PGDumpFilter.filtered(dumpURL, serverVersion: 160000)
    assert(removed16 == 1 && !(try! String(contentsOf: f16, encoding: .utf8)).contains("transaction_timeout"))
    assert(try! PGDumpFilter.filtered(dumpURL, serverVersion: 170000).removed == 0)
    // psql runs the file inside our own \restrict block; the dump's own restrict lines are dropped.
    try! "\\restrict abc\nSELECT 1;\n\\unrestrict abc\n".write(to: dumpURL, atomically: true, encoding: .utf8)
    let wrapped = try! String(contentsOf: PGDumpFilter.filtered(dumpURL, serverVersion: 170000, key: "k1").0, encoding: .utf8)
    assert(wrapped == "\\restrict k1\nSELECT 1;\n\\unrestrict k1\n", wrapped)
    // MySQL dump values: numbers bare, binary as hex, text escaped.
    assert(MySQLDump.literal(Array("12.5".utf8), .init(name: "n", numeric: true, binary: false)) == "12.5")
    assert(MySQLDump.literal([0, 255], .init(name: "b", numeric: false, binary: true)) == "X'00FF'")
    assert(MySQLDump.literal(Array("a'b\\c\n".utf8), .init(name: "t", numeric: false, binary: false)) == "'a\\'b\\\\c\\n'")
    assert(MySQLDump.literal(nil, .init(name: "t", numeric: false, binary: false)) == "NULL")
    // Column DDL: only what changed, per dialect.
    let oldCol = ColumnDef(name: "a", type: "integer", nullable: true)
    assert(Session.alterColumnSQL(.postgres, table: "\"t\"", from: oldCol, to: oldCol).isEmpty)
    assert(Session.alterColumnSQL(.postgres, table: "\"t\"", from: oldCol, to: ColumnDef(name: "b", type: "bigint", nullable: false, defaultSQL: "0")) == [
        "ALTER TABLE \"t\" RENAME COLUMN \"a\" TO \"b\"", "ALTER TABLE \"t\" ALTER COLUMN \"b\" TYPE bigint USING \"b\"::bigint",
        "ALTER TABLE \"t\" ALTER COLUMN \"b\" SET NOT NULL", "ALTER TABLE \"t\" ALTER COLUMN \"b\" SET DEFAULT 0"])
    assert(Session.alterColumnSQL(.mysql, table: "`t`", from: ColumnDef(name: "id", type: "int", extra: "auto_increment"),
                                  to: ColumnDef(name: "id2", type: "bigint", nullable: false, extra: "auto_increment", comment: "it's"))
           == ["ALTER TABLE `t` CHANGE COLUMN `id` `id2` bigint NOT NULL auto_increment COMMENT 'it''s'"])
    assert(Session.alterColumnSQL(.sqlite, table: "\"t\"", from: oldCol, to: ColumnDef(name: "a", type: "text")).isEmpty)
    assert(Session.dropColumnSQL(.mysql, table: "`t`", column: "a`b") == "ALTER TABLE `t` DROP COLUMN `a``b`")
    let mysqlRow = ColumnDef(row: ["1", "c", "varchar", "varchar(20)", "NO", "x'y", "", ""],
                             header: ["#", "column_name", "data_type", "full_type", "is_nullable", "column_default", "extra", "comment"])
    assert(mysqlRow == ColumnDef(name: "c", type: "varchar(20)", nullable: false, defaultSQL: "'x''y'"))
    // Column type picker: parameterised types split into base + digits; others kept whole.
    assert(ColumnType("character varying(200)") == ColumnType(base: "character varying", arguments: "200"))
    assert(ColumnType("numeric(10, 2)").sql == "numeric(10,2)")
    assert(ColumnType("timestamp(6) without time zone").base == "timestamp(6) without time zone")
    assert(ColumnType.choices(.postgres, current: "timestamp(6) without time zone").first == "timestamp(6) without time zone")
    assert(!ColumnType(base: "varchar", arguments: "2x").argumentsValid && ColumnType(base: "varchar", arguments: "").sql == "varchar")
    assert(ColumnType.resolved("_int4", previous: "integer", kind: .postgres) == "int4[]")
    assert(ColumnType.resolved("varchar", previous: "char(12)", kind: .mysql) == "varchar(12)")
    assert(ColumnType.resolved("varchar", previous: "int", kind: .mysql) == "varchar(255)")
    assert(Session.addColumnSQL(.postgres, table: "\"t\"", column: ColumnDef(name: "n", type: "int8", nullable: false, defaultSQL: "0"))
           == "ALTER TABLE \"t\" ADD COLUMN \"n\" int8 NOT NULL DEFAULT 0")
    assert(Session.addColumnSQL(.mysql, table: "`t`", column: ColumnDef(name: "n", type: "varchar(255)")) == "ALTER TABLE `t` ADD COLUMN `n` varchar(255)")
    assert(Session.createIndexSQL(.postgres, table: "\"t\"", name: "i", columns: ["a", "b"], unique: true, algorithm: "BTREE")
           == "CREATE UNIQUE INDEX \"i\" ON \"t\" USING btree (\"a\", \"b\")")
    assert(Session.createIndexSQL(.mysql, table: "`t`", name: "i", columns: ["a"], unique: false, algorithm: "HASH") == "CREATE INDEX `i` USING HASH ON `t` (`a`)")
    assert(Session.dropIndexSQL(.mysql, table: "`t`", schema: nil, name: "PRIMARY", primary: true) == ["ALTER TABLE `t` DROP PRIMARY KEY"])
    assert(ColumnType.fullName("timestamp", kind: .postgres) == "timestamp without time zone")
    assert(ColumnType.fullName("int4[]", kind: .postgres) == "integer[]" && ColumnType.fullName("varchar(255)", kind: .mysql) == "varchar(255)")
    // Redis: unverified TLS to another host still needs the cleartext opt-in (refused before connecting).
    assert((try? RedisDB(host: "192.0.2.1", port: "6379", user: "", password: "pw", database: "0", tls: .required)) == nil)
    // Table names are rebuilt on the session queue while the main thread reads them: must not crash.
    let shared = TableNames()
    DispatchQueue.concurrentPerform(iterations: 2) { worker in
        for i in 0..<20_000 {
            if worker == 0 { _ = shared.record([(schema: "s\(i % 3)", name: "t\(i % 50)")], defaultSchema: "public") }
            else { _ = shared.parts("s1.t\(i % 50)", defaultSchema: "public") }
        }
    }
    // Name search: words in any order and case, separators ignored.
    assert(nameMatches("shop local", "shop_local") && nameMatches("LOCAL sho", "shop_local_dev"))
    assert(nameMatches("", "anything") && nameMatches("  ", "x") && !nameMatches("shop prod", "shop_local"))
    assert(nameMatches("user.id", "users_id_seq"))
    // Editor colours: keyword, quoted identifier, string, number, type, comment.
    let hl = SQLHighlighter.ranges("SELECT \"id\", 'a''b' FROM t WHERE n = 42 -- note\nCREATE TABLE x (id bigserial)" as NSString)
    let kinds = hl.map { $0.1 }
    assert(kinds.filter { $0 == SQLHighlighter.keyword }.count == 5, "\(hl)")
    assert(!kinds.contains(SQLHighlighter.identifier) && kinds.contains(SQLHighlighter.number) && kinds.contains(SQLHighlighter.type))
    assert(hl.contains { $0.1 == SQLHighlighter.string && $0.0.length == 6 } && hl.contains { $0.1 == SQLHighlighter.comment })
    // Result filter: every word somewhere in the row, any case; nil when empty.
    let fr = QueryResult(columns: ["id", "name"], rows: [["1", "Class 1-A"], ["2", "Kelas 1"], ["3", nil]])
    assert(ResultGrid.matching(fr, "") == nil && ResultGrid.matching(fr, "class 1-a") == [0] && ResultGrid.matching(fr, "1") == [0, 1])
    assert(Session.isLocalNetwork("192.168.1.20") && Session.isLocalNetwork("nas.local") && Session.isLocalNetwork("172.20.0.5"))
    assert(!Session.isLocalNetwork("172.40.0.1") && !Session.isLocalNetwork("db.example.com") && !Session.isLocalNetwork("8.8.8.8"))
    // Beautify: clause keywords on their own lines, content indented; strings and comments untouched.
    func fmt(_ q: String, _ want: String) { let got = SQLFormatter.format(q); assert(got == want, "\n" + got) }
    fmt("select * from \"public\".\"assets\" limit 300 offset 0",
        "SELECT\n  *\nFROM\n  \"public\".\"assets\"\nLIMIT\n  300\nOFFSET\n  0")
    fmt("select * from assets where name ilike '%te st%' and id between 1 and 9 order by id",
        "SELECT\n  *\nFROM\n  assets\nWHERE\n  name ILIKE '%te st%'\n  AND id BETWEEN 1 AND 9\nORDER BY\n  id")
    fmt("select o.id, count(*) from orders o left join users u on u.id = o.user_id group by o.id",
        "SELECT\n  o.id,\n  COUNT(*)\nFROM\n  orders o\n  LEFT JOIN users u ON u.id = o.user_id\nGROUP BY\n  o.id")
    fmt("create table t (id bigserial primary key, name text default 'a, b')",
        "CREATE TABLE t (\n  id bigserial PRIMARY KEY,\n  name text DEFAULT 'a, b'\n)")
    fmt("insert into notes (id) values (1), (2)", "INSERT INTO\n  notes (id)\nVALUES\n  (1),\n  (2)")
    fmt("select 1; -- keep me\nselect x::int from t", "SELECT\n  1;\n\n-- keep me\nSELECT\n  x::int\nFROM\n  t")
    fmt("create or replace function f() returns int as $$ select 1; $$ language sql",
        "CREATE OR REPLACE FUNCTION f() RETURNS int AS $$ select 1; $$ LANGUAGE sql")
    // No completion inside strings or comments.
    assert(SQLCompleter.insideLiteral("SELECT * FROM t WHERE a ILIKE '%te") && SQLCompleter.insideLiteral("SELECT 1 -- us"))
    assert(SQLCompleter.referencedTables(#"SELECT * FROM "public"."ai_events" where ty"#).tables == ["public.ai_events"])
    var rows: Rows = [["1", nil, "é"], [nil], [], ["x", "yy"]]
    assert(rows.count == 4 && rows.cell(0, 2) == "é" && rows.cell(0, 1) == nil && rows.cell(1, 0) == nil && rows.width(2) == 0 && rows.cell(9 - 9, 7) == nil)
    rows[0][1] = "two"; rows[3][0] = nil // same width: spliced in place
    assert(rows == [["1", "two", "é"], [nil], [], [nil, "yy"]])
    rows[1] = ["a", "b"] // new width: rebuilt
    assert(rows == [["1", "two", "é"], ["a", "b"], [], [nil, "yy"]] && rows.map { $0.count } == [3, 2, 0, 2])
    var big = Rows(); for i in 0..<200 { big.append([String(i), i % 3 == 0 ? nil : "v\(i)"]) }
    big[100][1] = "changed"
    assert(big.cell(100, 1) == "changed" && big.cell(101, 1) == "v101" && big.cell(99, 1) == nil && big.cell(199, 0) == "199")
    assert(SQLCompleter.referencedTables("SELECT * FROM `shop`.`orders` o").aliases["o"] == "shop.orders")
    assert(!SQLCompleter.insideLiteral("SELECT * FROM t WHERE a = 'x' AND us") && !SQLCompleter.insideLiteral("SELECT 'it''s' FROM us"))
    print("selftest ok")
}

// Run: Kueri --probe <sqlite|postgres|mysql|redis> host port user password database "query"
func probe(_ a: [String]) {
    let tls = TLSMode(rawValue: ProcessInfo.processInfo.environment["KUERI_TLS"] ?? "")
    do {
        // KUERI_SSH="host:port:user:keyfile" tunnels like the app does.
        var via: (host: String, port: String)?, tunnel: SSHTunnel?
        if let spec = ProcessInfo.processInfo.environment["KUERI_SSH"]?.split(separator: ":", maxSplits: 3).map(String.init), spec.count == 4 {
            tunnel = try SSHTunnel(sshHost: spec[0], sshPort: spec[1], sshUser: spec[2], keyPath: spec[3], dbHost: a[1], dbPort: a[2])
            via = ("127.0.0.1", String(tunnel!.localPort))
            print("tunnel: 127.0.0.1:\(tunnel!.localPort) -> \(a[1]):\(a[2]) via \(spec[0])")
        }
        defer { _ = tunnel }
        let db: Database = switch a[0] {
        case "postgres": try PostgresDB(host: a[1], port: a[2], user: a[3], password: a[4], database: a[5], tls: tls ?? .prefer, via: via)
        case "postgres-cleartext": try PostgresDB(host: a[1], port: a[2], user: a[3], password: a[4], database: a[5], allowCleartextPassword: true)
        case "mysql": try MySQLDB(host: a[1], port: a[2], user: a[3], password: a[4], database: a[5], allowPublicKeyRetrieval: tls == nil, tls: tls ?? .off, via: via) // dev tool
        case "mysql-strict": try MySQLDB(host: a[1], port: a[2], user: a[3], password: a[4], database: a[5])
        case "redis": try RedisDB(host: a[1], port: a[2], user: a[3], password: a[4], database: a[5], tls: tls ?? .off, via: via)
        case "redis-cleartext": try RedisDB(host: a[1], port: a[2], user: a[3], password: a[4], database: a[5], allowCleartextPassword: true)
        default: try SQLiteDB(path: a[1])
        }
        let t = try db.tables()
        print("databases:", (try? db.databases()) ?? [], "tables:", t)
        if let first = t.first { print("browse:", try db.browseQuery(first, offset: 0)) }
        if let first = t.first { print("columns:", try db.columns(first).map { "\($0.isPrimaryKey ? "🔑" : "")\($0.name):\($0.type)" }) }
        if let first = t.first { let st = try db.structure(first); print("structure:", st.columns, st.rows.prefix(3)) }
        let fks = try db.foreignKeys(); print("foreign keys:", fks.count, fks.prefix(3).map { "\($0.fromTable).\($0.fromColumn) -> \($0.toTable).\($0.toColumn)" })
        let r = try db.query(a[6])
        print(r.columns, r.rows, r.message)
    } catch { print("error:", error.localizedDescription) }
}
