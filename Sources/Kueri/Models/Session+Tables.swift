import SwiftUI

extension Session {
    private func snapshot() -> WorkTab {
        WorkTab(id: activeTab, kind: kind, sql: sql, result: result, selectedRow: selectedRow, edits: edits, table: table,
                primaryKey: primaryKey, enumValues: enumValues, browsed: browsed, offset: offset, error: error, diagram: diagram)
    }

    private func load(_ t: WorkTab) {
        activeTab = t.id; kind = t.kind; sql = t.sql; result = t.result; selectedRow = t.selectedRow; edits = t.edits
        table = t.table; primaryKey = t.primaryKey; enumValues = t.enumValues; browsed = t.browsed; offset = t.offset; error = t.error; diagram = t.diagram
        selectedRows = []
        undoManager?.removeAllActions(withTarget: self) // undo entries refer to the rows of one tab
    }

    /// Applies an async result to the tab that requested it, whether or not it is still active.
    func updateTab(_ id: UUID, _ change: (inout WorkTab) -> Void) {
        if id == activeTab { var t = snapshot(); change(&t); load(t) }
        else if let i = tabs.firstIndex(where: { $0.id == id }) { change(&tabs[i]) }
    }

    /// Tab list with the active one's live state.
    var tabList: [WorkTab] { tabs.map { $0.id == activeTab ? snapshot() : $0 } }

    func selectTab(_ id: UUID) {
        guard id != activeTab, !saving, let target = tabs.first(where: { $0.id == id }),
              let i = tabs.firstIndex(where: { $0.id == activeTab }) else { return }
        tabs[i] = snapshot()
        load(target)
    }

    @discardableResult
    func newTab(_ kind: TabKind = .data) -> UUID {
        if let i = tabs.firstIndex(where: { $0.id == activeTab }) { tabs[i] = snapshot() }
        let t = WorkTab(id: UUID(), kind: kind)
        tabs.append(t)
        load(t)
        return t.id
    }

    func closeTab(_ id: UUID) {
        let pending = id == activeTab ? !edits.isEmpty : !(tabs.first { $0.id == id }?.edits.isEmpty ?? true)
        guard !pending else { error = "Save or discard that tab's unsaved changes first."; return }
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        if id == activeTab {
            let next = tabs.indices.contains(i + 1) ? tabs[i + 1] : (i > 0 ? tabs[i - 1] : nil)
            tabs.remove(at: i)
            if let next { load(next) } else { resetTabs() }
        } else {
            tabs.remove(at: i)
        }
    }

    func resetTabs() {
        let t = WorkTab(id: UUID())
        tabs = [t]
        load(t)
    }

    /// Sidebar click: show the table in the current tab (a new one if this tab isn't a data tab).
    func openTable(_ name: String, inNewTab: Bool = false) {
        if inNewTab || kind != .data { newTab() }
        browse(name)
    }

    func openStructure(_ name: String) {
        let tab = newTab(.structure(name))
        Task {
            do {
                let (st, pk) = try await onQueue { db in (try db.structure(name), (try? db.primaryKey(name)) ?? []) }
                updateTab(tab) { $0.result = st; $0.primaryKey = pk; $0.error = nil }
            } catch { updateTab(tab) { $0.error = error.localizedDescription } }
        }
    }

    /// The table plus every table linked to it by a foreign key, in either direction; an empty name
    /// is the whole database (current schema). An open diagram tab is reused rather than stacking tabs.
    /// `highlight` marks (and scrolls to) one table in the whole-database diagram; an open one is
    /// reused, so moving the highlight doesn't reload or re-lay out anything.
    func showDiagram(_ name: String, highlight: String? = nil) {
        if name.isEmpty, case .diagram("") = kind, var whole = diagram, !whole.positions.isEmpty {
            whole.highlight = highlight
            diagram = whole
            return
        }
        let tab: UUID
        if case .diagram = kind, edits.isEmpty { kind = .diagram(name); diagram = nil; error = nil; tab = activeTab }
        else { tab = newTab(.diagram(name)) }
        let all = visibleTables
        Task {
            do {
                let model = try await onQueue { db -> DiagramModel in
                    let fks = try db.foreignKeys()
                    if name.isEmpty {
                        var whole = try Self.wholeDiagram(db, tables: all, fks: fks)
                        whole.highlight = highlight
                        return whole
                    }
                    var names = [name]
                    for fk in fks {
                        if fk.fromTable == name, !names.contains(fk.toTable) { names.append(fk.toTable) }
                        if fk.toTable == name, !names.contains(fk.fromTable) { names.append(fk.fromTable) }
                    }
                    // Limitation: capped neighbourhood; add a "whole schema" diagram if someone needs it
                    names = Array(names.prefix(30))
                    let tables = try names.map { DiagramTable(name: $0, columns: try db.columns($0)) }
                    let links = fks.filter { names.contains($0.fromTable) && names.contains($0.toTable) }
                    return DiagramModel(focus: name, tables: tables, links: links)
                }
                updateTab(tab) { $0.diagram = model; $0.error = nil }
            } catch { updateTab(tab) { $0.error = error.localizedDescription } }
        }
    }

    // Limitation: whole-database diagram capped at 150 tables (one column query each); a bulk column query would lift it.
    nonisolated static func wholeDiagram(_ db: Database, tables all: [String], fks: [ForeignKey]) throws -> DiagramModel {
        // Related tables next to each other: walk each FK-connected group in sidebar order.
        var neighbours: [String: [String]] = [:]
        for fk in fks where fk.fromTable != fk.toTable {
            neighbours[fk.fromTable, default: []].append(fk.toTable)
            neighbours[fk.toTable, default: []].append(fk.fromTable)
        }
        let known = Set(all)
        var order: [String] = [], seen = Set<String>()
        for start in all where !seen.contains(start) {
            var queue = [start]; seen.insert(start)
            while !queue.isEmpty {
                let t = queue.removeFirst(); order.append(t)
                for n in neighbours[t] ?? [] where known.contains(n) && !seen.contains(n) { seen.insert(n); queue.append(n) }
            }
        }
        order = Array(order.prefix(150))
        let tables = try order.map { DiagramTable(name: $0, columns: try db.columns($0)) }
        // Columns filled shortest-first, so tall tables don't leave empty rows.
        let columns = max(1, Int(Double(tables.count).squareRoot().rounded(.up)))
        var bottoms = [CGFloat](repeating: 40, count: columns), positions: [String: CGPoint] = [:]
        for t in tables {
            let c = bottoms.indices.min { bottoms[$0] < bottoms[$1] }!
            positions[t.name] = CGPoint(x: 40 + CGFloat(c) * (DiagramView.width + 120), y: bottoms[c])
            bottoms[c] += DiagramView.height(t) + 40
        }
        let names = Set(order)
        return DiagramModel(focus: "", tables: tables, links: fks.filter { names.contains($0.fromTable) && names.contains($0.toTable) },
                            positions: positions)
    }

    // MARK: Column DDL

    /// Statements that turn column `old` into `new` (only what changed). SQLite can only rename.
    nonisolated static func alterColumnSQL(_ kind: Conn.Kind, table: String, from old: ColumnDef, to new: ColumnDef) -> [String] {
        let q = kind == .mysql ? { "`" + $0.replacingOccurrences(of: "`", with: "``") + "`" } : quoteIdent
        switch kind {
        case .mysql:
            guard old != new else { return [] }
            // CHANGE restates the whole column; extra (auto_increment, ON UPDATE…) and comment are kept.
            var def = "\(q(new.name)) \(new.type) \(new.nullable ? "NULL" : "NOT NULL")"
            if !new.defaultSQL.isEmpty { def += " DEFAULT \(new.defaultSQL)" }
            if !new.extra.isEmpty { def += " \(new.extra)" }
            if !new.comment.isEmpty {
                def += " COMMENT '" + new.comment.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'"
            }
            return ["ALTER TABLE \(table) CHANGE COLUMN \(q(old.name)) \(def)"]
        case .sqlite:
            return old.name == new.name ? [] : ["ALTER TABLE \(table) RENAME COLUMN \(q(old.name)) TO \(q(new.name))"]
        default:
            var out: [String] = []
            let col = q(new.name)
            if old.name != new.name { out.append("ALTER TABLE \(table) RENAME COLUMN \(q(old.name)) TO \(col)") }
            if old.type != new.type { out.append("ALTER TABLE \(table) ALTER COLUMN \(col) TYPE \(new.type) USING \(col)::\(new.type)") }
            if old.nullable != new.nullable { out.append("ALTER TABLE \(table) ALTER COLUMN \(col) \(new.nullable ? "DROP" : "SET") NOT NULL") }
            if old.defaultSQL != new.defaultSQL {
                out.append("ALTER TABLE \(table) ALTER COLUMN \(col) " + (new.defaultSQL.isEmpty ? "DROP DEFAULT" : "SET DEFAULT \(new.defaultSQL)"))
            }
            return out
        }
    }

    nonisolated static func addColumnSQL(_ kind: Conn.Kind, table: String, column c: ColumnDef) -> String {
        let q = kind == .mysql ? "`" + c.name.replacingOccurrences(of: "`", with: "``") + "`" : quoteIdent(c.name)
        var sql = "ALTER TABLE \(table) ADD COLUMN \(q) \(c.type)"
        if !c.nullable { sql += " NOT NULL" }
        if !c.defaultSQL.isEmpty { sql += " DEFAULT \(c.defaultSQL)" }
        return sql
    }

    nonisolated static func indexAlgorithms(_ kind: Conn.Kind) -> [String] {
        kind == .mysql ? ["BTREE", "HASH"] : ["BTREE", "HASH", "GIN", "GIST", "BRIN", "SPGIST"]
    }

    nonisolated static func createIndexSQL(_ kind: Conn.Kind, table: String, name: String, columns: [String], unique: Bool,
                                           algorithm: String) -> String {
        let q = kind == .mysql ? { "`" + $0.replacingOccurrences(of: "`", with: "``") + "`" } : quoteIdent
        let cols = columns.map(q).joined(separator: ", ")
        let u = unique ? "UNIQUE " : ""
        switch kind {
        case .postgres: return "CREATE \(u)INDEX \(q(name)) ON \(table) USING \(algorithm.lowercased()) (\(cols))"
        case .mysql: return "CREATE \(u)INDEX \(q(name)) USING \(algorithm) ON \(table) (\(cols))"
        default: return "CREATE \(u)INDEX \(q(name)) ON \(table) (\(cols))"
        }
    }

    /// Postgres: a primary key or UNIQUE constraint owns its index, so the constraint is dropped first
    /// (a no-op for plain indexes) and then the index, if it still exists.
    nonisolated static func dropIndexSQL(_ kind: Conn.Kind, table: String, schema: String?, name: String, primary: Bool) -> [String] {
        switch kind {
        case .mysql:
            let q = "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
            return [primary ? "ALTER TABLE \(table) DROP PRIMARY KEY" : "ALTER TABLE \(table) DROP INDEX \(q)"]
        case .postgres:
            let qualified = (schema.map { quoteIdent($0) + "." } ?? "") + quoteIdent(name)
            return ["ALTER TABLE \(table) DROP CONSTRAINT IF EXISTS \(quoteIdent(name))", "DROP INDEX IF EXISTS \(qualified)"]
        default:
            return ["DROP INDEX \(quoteIdent(name))"]
        }
    }

    nonisolated static func dropColumnSQL(_ kind: Conn.Kind, table: String, column: String) -> String {
        let q = kind == .mysql ? "`" + column.replacingOccurrences(of: "`", with: "``") + "`" : quoteIdent(column)
        return "ALTER TABLE \(table) DROP COLUMN \(q)"
    }

    // MARK: Table actions (DDL)

    func cloneSQL(_ t: String, to new: String, withData: Bool) -> String {
        let src = quoteTable(t), dst = quoteTable(new)
        switch conn.kind {
        case .postgres:
            return "CREATE TABLE \(dst) (LIKE \(src) INCLUDING ALL);" + (withData ? " INSERT INTO \(dst) SELECT * FROM \(src);" : "")
        case .mysql:
            return "CREATE TABLE \(dst) LIKE \(src);" + (withData ? " INSERT INTO \(dst) SELECT * FROM \(src);" : "")
        default: // SQLite: no LIKE; copies columns and data, not constraints
            return "CREATE TABLE \(dst) AS SELECT * FROM \(src)" + (withData ? ";" : " WHERE 0;")
        }
    }
    func truncateSQL(_ t: String) -> String { conn.kind == .sqlite ? "DELETE FROM \(quoteTable(t))" : "TRUNCATE TABLE \(quoteTable(t))" }
    func dropSQL(_ t: String) -> String { "DROP TABLE \(quoteTable(t))" }

    /// Runs DDL/DML on the session queue, then refreshes the table list. Throws the database error.
    func execute(_ sql: String) async throws {
        let t = try await onQueue { db -> [String] in _ = try db.query(sql); return try db.tables() }
        tables = t
    }
}

enum NewObject: CaseIterable {
    case table, view, materializedView, function
    var title: String {
        switch self {
        case .table: "New Table"
        case .view: "New View"
        case .materializedView: "New Materialized View"
        case .function: "New Function/Procedure"
        }
    }
}

extension Session {
    /// Sidebar tables for the selected schema (Postgres); everything elsewhere.
    var visibleTables: [String] {
        guard conn.kind == .postgres, !schemas.isEmpty else { return tables }
        return tables.filter { schemaOf($0) == schema } // exact schema, not a guess from the label text
    }
    /// What the sidebar strips from names in the selected schema ("" for public).
    var schemaPrefix: String { conn.kind == .postgres && schema != "public" ? schema + "." : "" }

    func availableNewObjects() -> [NewObject] {
        switch conn.kind {
        case .postgres: NewObject.allCases
        case .mysql: [.table, .view, .function]
        case .sqlite: [.table, .view]
        case .redis: []
        }
    }

    /// A CREATE template for the current dialect and schema, opened in a new query tab to edit and run.
    func template(_ o: NewObject) -> String {
        let q = { (name: String) in self.quoteTable(self.schemaPrefix + name) }
        switch (conn.kind, o) {
        case (.postgres, .table):
            return "CREATE TABLE \(q("new_table")) (\n    id bigserial PRIMARY KEY,\n    name varchar(255) NOT NULL,\n    created_at timestamp NOT NULL DEFAULT now(),\n    updated_at timestamp NOT NULL DEFAULT now()\n);"
        case (.mysql, .table):
            return "CREATE TABLE \(q("new_table")) (\n    id bigint unsigned NOT NULL AUTO_INCREMENT PRIMARY KEY,\n    name varchar(255) NOT NULL,\n    created_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,\n    updated_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP\n);"
        case (_, .table):
            return "CREATE TABLE \(q("new_table")) (\n    id INTEGER PRIMARY KEY,\n    name TEXT NOT NULL,\n    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP\n);"
        case (_, .view):
            return "CREATE VIEW \(q("new_view")) AS\nSELECT *\nFROM \(q("table_name"))\nWHERE true;"
        case (_, .materializedView):
            return "CREATE MATERIALIZED VIEW \(q("new_matview")) AS\nSELECT *\nFROM \(q("table_name"))\nWITH DATA;"
        case (.mysql, .function):
            return "CREATE PROCEDURE \(q("new_procedure"))(IN p_id BIGINT)\nBEGIN\n    SELECT * FROM table_name WHERE id = p_id;\nEND"
        case (_, .function):
            return "CREATE OR REPLACE FUNCTION \(q("new_function"))(p_id bigint)\nRETURNS bigint\nLANGUAGE plpgsql\nAS $$\nBEGIN\n    RETURN p_id;\nEND;\n$$;"
        }
    }

    func openTemplate(_ o: NewObject) {
        newTab()
        sql = template(o)
    }

    // MARK: Database owner (Postgres; MySQL has no owner concept — Limitation)

    nonisolated static func alterOwnerSQL(database: String, owner: String) -> String {
        "ALTER DATABASE \(quoteIdent(database)) OWNER TO \(quoteIdent(owner))"
    }

    /// One ALTER … OWNER TO per object of the current database not yet owned by `owner`: schemas,
    /// relations (tables, views, sequences, …), routines and types. Objects that belong to an
    /// extension stay with it. ALTER DATABASE alone would leave every table with the old owner.
    nonisolated static func transferOwnershipListSQL(owner: String) -> String {
        let role = "'" + owner.replacingOccurrences(of: "'", with: "''") + "'"
        let system = "n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\\_%'"
        let notExt = { (oid: String) in "NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = \(oid) AND d.deptype = 'e')" }
        return """
        SELECT 'ALTER SCHEMA ' || quote_ident(n.nspname) || ' OWNER TO ' || quote_ident(\(role)) FROM pg_namespace n
          WHERE \(system) AND pg_get_userbyid(n.nspowner) <> \(role) AND \(notExt("n.oid"))
        UNION ALL
        SELECT 'ALTER ' || CASE c.relkind WHEN 'c' THEN 'TYPE ' || c.oid::regtype::text ELSE 'TABLE ' || c.oid::regclass::text END
               || ' OWNER TO ' || quote_ident(\(role))
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f', 'c') AND \(system) AND pg_get_userbyid(c.relowner) <> \(role) AND \(notExt("c.oid"))
        UNION ALL
        SELECT 'ALTER ROUTINE ' || p.oid::regprocedure::text || ' OWNER TO ' || quote_ident(\(role))
          FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE \(system) AND pg_get_userbyid(p.proowner) <> \(role) AND \(notExt("p.oid"))
        UNION ALL
        SELECT 'ALTER TYPE ' || t.oid::regtype::text || ' OWNER TO ' || quote_ident(\(role))
          FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
          WHERE t.typtype IN ('d', 'e', 'r') AND \(system) AND pg_get_userbyid(t.typowner) <> \(role) AND \(notExt("t.oid"))
        """
    }

    /// Roles that can own a database (system pg_* roles left out) and the owner of the current database.
    func databaseOwners() async throws -> (roles: [String], owner: String?) {
        try await onQueue { db in
            let r = try db.query("SELECT rolname FROM pg_roles WHERE rolname NOT LIKE 'pg\\_%' ORDER BY 1")
            let o = try db.query("SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database()")
            return ((0..<r.rows.count).compactMap { r.rows.cell($0, 0) }, o.rows.count > 0 ? o.rows.cell(0, 0) : nil)
        }
    }

    /// Makes `owner` own the current database and everything in it, in one transaction (all or
    /// nothing). Returns how many objects inside changed hands. Needs to run as a superuser or a
    /// member of both roles, which the server checks.
    func transferDatabase(to owner: String) async throws -> Int {
        let database = conn.database
        let n = try await onQueue { db -> Int in
            let list = try db.query(Self.transferOwnershipListSQL(owner: owner))
            let statements = (0..<list.rows.count).compactMap { list.rows.cell($0, 0) }
            _ = try db.query("BEGIN")
            do {
                for sql in statements { _ = try db.query(sql) }
                _ = try db.query(Self.alterOwnerSQL(database: database, owner: owner))
                _ = try db.query("COMMIT")
            } catch { _ = try? db.query("ROLLBACK"); throw error }
            return statements.count
        }
        tables = try await onQueue { try $0.tables() }
        return n
    }

    func createDatabaseSQL(_ name: String) -> String {
        conn.kind == .mysql
            ? "CREATE DATABASE `\(name.replacingOccurrences(of: "`", with: "``"))` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
            : "CREATE DATABASE \(quoteIdent(name))"
    }

    func createDatabase(_ name: String, open: Bool) async throws {
        let sql = createDatabaseSQL(name)
        databases = try await onQueue { db in _ = try db.query(sql); return try db.databases() }
        if open { switchDatabase(name) }
    }

    func createSchema(_ name: String) async throws {
        try await execute("CREATE SCHEMA \(quoteIdent(name))")
        schemas = try await onQueue { try $0.schemas() }
        schema = name
    }
}
