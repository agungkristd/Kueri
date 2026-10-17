import Foundation
import SQLite3
import CPQ

struct QueryResult {
    var id = UUID() // lets the grid skip reloads when nothing new arrived; renew after edits
    var columns: [String] = []
    var types: [String] = [] // per column; may be empty (e.g. Redis)
    var rows: [[String?]] = []
    var message = ""
    var affected = 0
}

// Limitation: results capped in memory, add paging (LIMIT/OFFSET) if you need to scroll millions of rows
let maxRows = 10_000
/// Rows per page when browsing a table.
// Limitation: LIMIT/OFFSET without ORDER BY, fine for browsing; switch to keyset paging on the PK if deep pages get slow
let pageSize = 300

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
    /// Schemas the sidebar can switch between (Postgres); empty = no schema picker.
    func schemas() throws -> [String]
    /// The exact schema of a sidebar label (nil when the database has no schema picker).
    func schemaOf(_ table: String) -> String?
    /// Table name quoted for this dialect (schema-qualified names keep their schema).
    func quoteTable(_ table: String) -> String
    /// `UPDATE table SET … WHERE key…` with values passed safely (bound or hex-encoded).
    /// Returns the number of rows matched.
    func update(_ table: String, set: [(String, String?)], key: [(String, String?)]) throws -> Int
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
    func schemas() throws -> [String] { [] }
    func schemaOf(_ table: String) -> String? { nil }
    func quoteTable(_ table: String) -> String { quoteIdent(table) }
    func update(_ table: String, set: [(String, String?)], key: [(String, String?)]) throws -> Int {
        throw DBError("Editing is not supported for this database")
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

struct DBError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

func quoteIdent(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

/// Sidebar names are display text ("users", "audit.logs"). Each is recorded with its exact
/// (schema, name) when the table list loads, so quoting/DDL never re-splits the text on "." —
/// a table literally named "audit.logs" in the default schema must not become audit → logs.
struct TableNames {
    private var exact: [String: (schema: String, name: String)] = [:]

    /// Bare name in the default schema, `schema.name` elsewhere; if either part contains a dot or a
    /// quote the label is fully quoted (`"a.b"."c"`), which can't collide with any other table.
    static func display(schema: String, name: String, defaultSchema: String?) -> String {
        if schema.contains(where: { $0 == "." || $0 == "\"" }) || name.contains(where: { $0 == "." || $0 == "\"" }) {
            return quoteIdent(schema) + "." + quoteIdent(name)
        }
        return schema == defaultSchema ? name : schema + "." + name
    }

    mutating func record(_ rows: [(schema: String, name: String)], defaultSchema: String?) -> [String] {
        exact = [:]
        var labels = rows.map { Self.display(schema: $0.schema, name: $0.name, defaultSchema: defaultSchema) }
        // Any label still shared by two tables (shouldn't happen, but never guess) gets the quoted form.
        let counts = Dictionary(labels.map { ($0, 1) }, uniquingKeysWith: +)
        for i in labels.indices where counts[labels[i]]! > 1 {
            labels[i] = quoteIdent(rows[i].schema) + "." + quoteIdent(rows[i].name)
        }
        for (label, r) in zip(labels, rows) { exact[label] = r }
        return labels
    }

    /// Exact parts for a sidebar name; names typed by the user (not in the list) split on the first dot.
    func parts(_ display: String, defaultSchema: String?) -> (schema: String?, name: String) {
        if let e = exact[display] { return (e.schema, e.name) }
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
        let sql = "UPDATE \(quote(table: t)) SET " + set.map { "\(quoteIdent($0.0)) = ?" }.joined(separator: ", ")
            + " WHERE " + key.map { "\(quoteIdent($0.0)) IS ?" }.joined(separator: " AND ")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw DBError(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, v) in (set.map(\.1) + key.map(\.1)).enumerated() {
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
                cur.rows.append((0..<n).map { i in
                    switch sqlite3_column_type(s, i) {
                    case SQLITE_NULL: return nil
                    case SQLITE_BLOB: return "<blob \(sqlite3_column_bytes(s, i)) bytes>"
                    default: // by byte count, not C string: text containing NUL must survive intact
                        let n = Int(sqlite3_column_bytes(s, i))
                        return String(decoding: UnsafeBufferPointer(start: sqlite3_column_text(s, i), count: n), as: UTF8.self)
                    }
                })
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
    init(host: String, port: String, user: String, password: String, database: String, allowCleartextPassword: Bool = false) throws {
        func kv(_ k: String, _ v: String) -> String {
            v.isEmpty ? "" : "\(k)='\(v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))' "
        }
        let info = kv("host", host) + kv("port", port) + kv("user", user) + kv("password", password)
            + kv("dbname", database) + "connect_timeout=10 application_name=Kueri"
            + (allowCleartextPassword ? "" : " require_auth=!password")
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
    private var names = TableNames()

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
                    cur!.rows.append((0..<nf).map { PQgetisnull(r, t, $0) == 1 ? nil : String(cString: PQgetvalue(r, t, $0)) })
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
    print("selftest ok")
}

// Run: Kueri --probe <sqlite|postgres|mysql|redis> host port user password database "query"
func probe(_ a: [String]) {
    do {
        let db: Database = switch a[0] {
        case "postgres": try PostgresDB(host: a[1], port: a[2], user: a[3], password: a[4], database: a[5])
        case "postgres-cleartext": try PostgresDB(host: a[1], port: a[2], user: a[3], password: a[4], database: a[5], allowCleartextPassword: true)
        case "mysql": try MySQLDB(host: a[1], port: a[2], user: a[3], password: a[4], database: a[5], allowPublicKeyRetrieval: true) // dev tool
        case "mysql-strict": try MySQLDB(host: a[1], port: a[2], user: a[3], password: a[4], database: a[5])
        case "redis": try RedisDB(host: a[1], port: a[2], user: a[3], password: a[4], database: a[5])
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
