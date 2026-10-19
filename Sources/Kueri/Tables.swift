import SwiftUI

// MARK: Table tabs

enum TabKind: Equatable { case data, structure(String), diagram(String) }

/// A parked tab. The active tab's state lives directly on `Session` so the grid, Details panel and
/// editing code keep working unchanged; switching tabs swaps these values in and out.
struct WorkTab: Identifiable {
    let id: UUID
    var kind = TabKind.data
    var sql = ""
    var result = QueryResult()
    var selectedRow: Int?
    var edits: [Int: [Int: String?]] = [:]
    var table: String?
    var primaryKey: [String] = []
    var browsed: (query: String, table: String, offset: Int)?
    var offset = 0
    var error: String?
    var diagram: DiagramModel?

    var title: String {
        switch kind {
        case .data: table ?? "Query"
        case .structure(let t): "\(t) · structure"
        case .diagram(let t): t.isEmpty ? "Diagram" : "\(t) · diagram"
        }
    }
}

enum TableAction: CaseIterable {
    case openNewTab, structure, diagram, copyName, clone, truncate, delete
    var title: String {
        switch self {
        case .openNewTab: "Open in New Tab"
        case .structure: "Open Structure"
        case .diagram: "Show Diagram"
        case .copyName: "Copy Name"
        case .clone: "Clone…"
        case .truncate: "Truncate…"
        case .delete: "Delete…"
        }
    }
}

extension Session {
    private func snapshot() -> WorkTab {
        WorkTab(id: activeTab, kind: kind, sql: sql, result: result, selectedRow: selectedRow, edits: edits, table: table,
                primaryKey: primaryKey, browsed: browsed, offset: offset, error: error, diagram: diagram)
    }

    private func load(_ t: WorkTab) {
        activeTab = t.id; kind = t.kind; sql = t.sql; result = t.result; selectedRow = t.selectedRow; edits = t.edits
        table = t.table; primaryKey = t.primaryKey; browsed = t.browsed; offset = t.offset; error = t.error; diagram = t.diagram
        selectedRows = []
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

// MARK: Tab strip

/// Table tab bar in plain AppKit (NSButton target/action). The SwiftUI version's tap gestures and
/// buttons didn't switch tabs on click in the real window, so this avoids SwiftUI's gesture layer.
/// One tab: icon, title and close button inside a single rounded shape (filled when active,
/// a lighter fill while the pointer is over an inactive one).
final class TabPill: NSView {
    private let active: Bool
    private var hovering = false { didSet { updateFill() } }

    init(title: NSButton, close: NSButton, active: Bool) {
        self.active = active
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        let row = NSStackView(views: [title, close])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        updateFill()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func viewDidChangeEffectiveAppearance() { updateFill() }
    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (active ? NSColor.quaternaryLabelColor : hovering ? NSColor.quaternaryLabelColor.withAlphaComponent(0.5) : .clear).cgColor
        }
    }
}

struct TabStrip: NSViewRepresentable {
    @Bindable var session: Session

    final class Coordinator: NSObject {
        var session: Session?
        var ids: [UUID] = []
        @MainActor @objc func select(_ b: NSButton) { if ids.indices.contains(b.tag) { session?.selectTab(ids[b.tag]) } }
        @MainActor @objc func close(_ b: NSButton) { if ids.indices.contains(b.tag) { session?.closeTab(ids[b.tag]) } }
        @MainActor @objc func add(_ b: NSButton) { session?.newTab() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        let line = NSBox(); line.boxType = .separator; line.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(line)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor), stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor), line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 32),
        ])
        return bar
    }

    func updateNSView(_ bar: NSView, context: Context) {
        let c = context.coordinator
        c.session = session
        guard let stack = bar.subviews.compactMap({ $0 as? NSStackView }).first else { return }
        let tabs = session.tabList
        c.ids = tabs.map(\.id)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() } // few tabs: rebuilding is cheap
        for (i, t) in tabs.enumerated() {
            let active = t.id == session.activeTab
            let title = t.title + (t.edits.isEmpty ? "" : " •")
            let b = NSButton(title: title, image: NSImage(systemSymbolName: icon(t.kind), accessibilityDescription: nil) ?? NSImage(),
                             target: c, action: #selector(Coordinator.select(_:)))
            b.tag = i
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.lineBreakMode = .byTruncatingTail
            b.toolTip = t.title
            b.contentTintColor = active ? .labelColor : .secondaryLabelColor
            b.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small) + 1, weight: active ? .semibold : .regular)
            b.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let x = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")!
                                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))!,
                             target: c, action: #selector(Coordinator.close(_:)))
            x.tag = i
            x.isBordered = false
            x.toolTip = "Close tab"
            x.contentTintColor = .secondaryLabelColor
            stack.addArrangedSubview(TabPill(title: b, close: x, active: active))
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        stack.addArrangedSubview(spacer)
        let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New query tab")!,
                            target: c, action: #selector(Coordinator.add(_:)))
        plus.bezelStyle = .recessed
        plus.showsBorderOnlyWhileMouseInside = true
        plus.toolTip = "New query tab"
        stack.addArrangedSubview(plus)
    }

    private func icon(_ k: TabKind) -> String {
        switch k {
        case .data: "tablecells"
        case .structure: "list.bullet.rectangle"
        case .diagram: "point.3.connected.trianglepath.dotted"
        }
    }
}

// MARK: Structure tab

struct StructureView: View {
    @Bindable var session: Session
    let table: String
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                LabeledContent("Name") { Text(table).textSelection(.enabled).fontWeight(.medium) }
                LabeledContent("Primary") {
                    HStack(spacing: 4) {
                        if session.primaryKey.isEmpty { Text("none").foregroundStyle(.secondary) }
                        ForEach(session.primaryKey, id: \.self) { k in
                            Text(k).font(.callout.monospaced())
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.3)))
                        }
                    }
                }
                Spacer()
                Text("\(session.result.rows.count) columns").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if let e = session.error {
                Text(e).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            ResultGrid(result: session.result, selection: $session.selectedRow)
        }
    }
}

/// Unsaved work in the table details (right panel). Grid edits are keyed by row → result column; rows past the
/// loaded ones are new (not yet created) columns / indexes.
struct TableDraft {
    var table = ""
    var columnEdits: [Int: [Int: String?]] = [:]
    var newColumns = 0
    var indexEdits: [Int: [Int: String?]] = [:]
    var newIndexes = 0
    var isEmpty: Bool { columnEdits.isEmpty && newColumns == 0 && indexEdits.isEmpty && newIndexes == 0 }
}

struct DiagramTableInfo: View {
    let name: String
    var session: Session?
    let load: (String) async -> QueryResult?
    @Binding var draft: TableDraft
    let action: (TableAction) -> Void
    @State private var result: QueryResult?        // structure as loaded
    @State private var indexes: QueryResult?
    @State private var structureGrid: QueryResult?  // + placeholder rows for new columns
    @State private var indexGrid: QueryResult?
    @State private var row: Int?
    @State private var indexRow: Int?
    @State private var showIndexes = false
    @State private var editRequest: GridEditRequest?
    @State private var pending: (title: String, sql: [String])?
    @State private var error: String?
    @State private var running = false

    private var kind: Conn.Kind { session?.conn.kind ?? .postgres }
    private func col(_ r: QueryResult?, _ n: String) -> Int? { r?.columns.firstIndex { $0.lowercased() == n } }
    private var baseColumns: Int { result?.rows.count ?? 0 }
    private var baseIndexes: Int { indexes?.rows.count ?? 0 }
    private var newTypeName: String { kind == .sqlite ? "TEXT" : "varchar" }

    private func column(_ r: Int) -> ColumnDef? {
        guard let result, result.rows.indices.contains(r) else { return nil }
        return ColumnDef(row: result.rows[r], header: result.columns)
    }

    // MARK: Staged SQL

    /// Existing columns changed in the grid, then new columns (rows without a name are left out).
    private var columnSQL: [String] {
        guard let session, let result else { return [] }
        let table = session.quoteTable(name)
        let (nc, tc, nullc, dc) = (col(result, "column_name"), col(result, "data_type"), col(result, "is_nullable"), col(result, "column_default"))
        func value(_ r: Int, _ c: Int?) -> String?? { c.flatMap { draft.columnEdits[r]?[$0] } }
        return draft.columnEdits.keys.filter { $0 < baseColumns }.sorted().flatMap { r -> [String] in
            guard let old = column(r) else { return [] }
            var new = old
            if let n = value(r, nc) ?? nil, !n.isEmpty { new.name = n }
            if let t = value(r, tc) ?? nil, let tc, t != result.rows[r][tc] { new.type = ColumnType.resolved(t, previous: old.type, kind: kind) }
            if let n = value(r, nullc) ?? nil { new.nullable = n != "NO" }
            if let d = value(r, dc) { new.defaultSQL = d ?? "" }
            return Session.alterColumnSQL(kind, table: table, from: old, to: new)
        } + (0..<draft.newColumns).compactMap { i -> String? in
            let r = baseColumns + i
            guard let n = value(r, nc) ?? nil, !n.isEmpty else { return nil }
            let def = ColumnDef(name: n, type: ColumnType.resolved((value(r, tc) ?? nil) ?? newTypeName, previous: "", kind: kind),
                                nullable: ((value(r, nullc) ?? nil) ?? "YES") != "NO", defaultSQL: (value(r, dc) ?? nil) ?? "")
            return Session.addColumnSQL(kind, table: table, column: def)
        }
    }

    private var indexSQL: [String] {
        guard let session else { return [] }
        let (nc, ac, uc, cc) = (col(indexes, "index_name"), col(indexes, "index_algorithm"), col(indexes, "is_unique"), col(indexes, "columns"))
        func value(_ r: Int, _ c: Int?) -> String? { c.flatMap { draft.indexEdits[r]?[$0] ?? nil } }
        return (0..<draft.newIndexes).compactMap { i -> String? in
            let r = baseIndexes + i
            let columns = (value(r, cc) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let n = value(r, nc), !n.isEmpty, !columns.isEmpty else { return nil }
            return Session.createIndexSQL(kind, table: session.quoteTable(name), name: n, columns: columns,
                                          unique: value(r, uc) == "TRUE", algorithm: value(r, ac) ?? "BTREE")
        }
    }

    private var incomplete: Bool {
        let missingColumn = (0..<draft.newColumns).contains { i in
            (col(result, "column_name").flatMap { draft.columnEdits[baseColumns + i]?[$0] ?? nil } ?? "").isEmpty
        }
        let missingIndex = (0..<draft.newIndexes).contains { i in
            let r = baseIndexes + i
            return (col(indexes, "index_name").flatMap { draft.indexEdits[r]?[$0] ?? nil } ?? "").isEmpty
                || (col(indexes, "columns").flatMap { draft.indexEdits[r]?[$0] ?? nil } ?? "").isEmpty
        }
        return missingColumn || missingIndex
    }

    // MARK: View

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Name") { Text(name).textSelection(.enabled).fontWeight(.medium) }
            Picker("View", selection: $showIndexes) {
                Text("Structure").tag(false)
                Text("Index").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().frame(maxWidth: .infinity)
            .onChange(of: showIndexes) { _, on in if on, indexes == nil { Task { await loadIndexes() } } }
            Group {
                if showIndexes { indexGridView } else { structureGridView }
            }
            .frame(minHeight: 180, maxHeight: .infinity) // fills the panel's height
            .clipShape(RoundedRectangle(cornerRadius: 6))
            if session != nil {
                HStack(spacing: 6) {
                    Button { showIndexes ? addIndex() : addColumn() } label: { Image(systemName: "plus").frame(width: 14) }
                        .help(showIndexes ? "Add an index" : "Add a column")
                        .disabled(showIndexes && kind == .redis)
                    Button { showIndexes ? removeIndex() : removeColumn() } label: { Image(systemName: "minus").frame(width: 14) }
                        .help(showIndexes ? "Delete the selected index" : "Delete the selected column")
                        .disabled((showIndexes ? indexRow : row) == nil)
                    if !showIndexes {
                    }
                    Text(showIndexes ? "New index: name it, then pick its columns"
                                     : "Double-click a cell to edit it")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !draft.isEmpty {
                    // Two lines so it fits the narrowest panel.
                    let count = draft.columnEdits.keys.filter { $0 < baseColumns }.count + draft.newColumns + draft.newIndexes
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(count) unsaved change\(count == 1 ? "" : "s")"
                             + (incomplete ? " · new rows need a name\(showIndexes ? " and columns" : "")" : ""))
                            .font(.callout).foregroundStyle(incomplete ? .orange : .secondary)
                        HStack {
                            Spacer()
                            Button("Discard") { discard() }
                            Button("Save…") { pending = ("Save changes to \(name)?", columnSQL + indexSQL) }
                                .keyboardShortcut("s", modifiers: .command)
                                .disabled((columnSQL + indexSQL).isEmpty || incomplete)
                        }
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).lineLimit(6) }
            Divider()
            HStack {
                Button("Open Data") { action(.openNewTab) }
                Spacer()
                Menu {
                    Button("Open Structure") { action(.structure) }
                    Divider()
                    Button("Delete Table…", role: .destructive) { action(.delete) }
                } label: { FieldIcon(name: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More table actions")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .disabled(running)
        .task { await reload() }
        // With the form open, selecting another existing row edits that column instead.
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if let p = pending { Button(p.title.hasPrefix("Delete") ? "Delete" : "Save", role: .destructive) { apply(p.sql) } }
        } message: {
            if let p = pending { Text(p.sql.joined(separator: ";\n") + ";") }
        }
    }

    @ViewBuilder private var structureGridView: some View {
        if let structureGrid, let result {
            let (nc, tc, nullc, dc) = (col(result, "column_name"), col(result, "data_type"), col(result, "is_nullable"), col(result, "column_default"))
            ResultGrid(result: structureGrid, selection: $row, edits: draft.columnEdits, editable: session != nil,
                       onEdit: { r, c, v in
                           draft.columnEdits[r, default: [:]][c] = v
                           // full_type follows a picked type, so the row reads like the loaded ones.
                           if c == tc, let v, let fc = col(result, "full_type") {
                               draft.columnEdits[r, default: [:]][fc] = ColumnType.fullName(ColumnType.resolved(v, previous: column(r)?.type ?? "", kind: kind), kind: kind)
                           }
                       },
                       editableCell: { r, c in
                           c == nc || ((r >= baseColumns || kind != .sqlite) && c == dc)
                       },
                       editRequest: showIndexes ? nil : editRequest,
                       menuForCell: { r, c in
                           let changeable = r >= baseColumns || kind != .sqlite
                           if c == tc, changeable { return ColumnType.names(kind) }
                           if c == nullc, changeable { return ["YES", "NO"] }
                           return nil
                       },
                       editsOnSingleClick: { r in r >= baseColumns || draft.columnEdits[r] != nil },
                       hiddenColumns: col(result, "#").map { [$0] } ?? []) // the position adds nothing in a narrow panel
        } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    @ViewBuilder private var indexGridView: some View {
        if let indexGrid, let indexes {
            let (nc, ac, uc, cc) = (col(indexes, "index_name"), col(indexes, "index_algorithm"), col(indexes, "is_unique"), col(indexes, "columns"))
            ResultGrid(result: indexGrid, selection: $indexRow, edits: draft.indexEdits, editable: session != nil,
                       onEdit: { r, c, v in
                           if c == cc, let v {  // toggle the picked column in the list, keeping pick order
                               var list = (draft.indexEdits[r]?[c] ?? nil).map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } ?? []
                               if let i = list.firstIndex(of: v) { list.remove(at: i) } else { list.append(v) }
                               draft.indexEdits[r, default: [:]][c] = list.joined(separator: ", ")
                           } else { draft.indexEdits[r, default: [:]][c] = v }
                       },
                       editableCell: { r, c in r >= baseIndexes && c == nc },
                       editRequest: showIndexes ? editRequest : nil,
                       menuForCell: { r, c in
                           guard r >= baseIndexes else { return nil }
                           if c == ac, kind != .sqlite { return Session.indexAlgorithms(kind) }
                           if c == uc { return ["FALSE", "TRUE"] }
                           if c == cc, let result, let n = col(result, "column_name") { return result.rows.compactMap { $0[n] } }
                           return nil
                       },
                       isMultiMenu: { _, c in c == cc },
                       editsOnSingleClick: { r in r >= baseIndexes })
        } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private var confirmTitle: String {
        guard let p = pending else { return "" }
        return p.title + (session?.conn.isProduction == true ? " (production: \(session!.conn.name))" : "")
    }

    // MARK: Rows

    /// Loaded rows plus one placeholder per new row (`template` keyed by lowercased column name).
    private static func padded(_ base: QueryResult, extra: Int, template: [String: String?]) -> QueryResult {
        var r = base
        r.rows += Array(repeating: base.columns.map { template[$0.lowercased()] ?? "" }, count: extra)
        r.id = UUID()
        return r
    }

    private func rebuildGrids() {
        if let result {
            structureGrid = Self.padded(result, extra: draft.newColumns, template: [
                "#": "+", "column_name": "", "data_type": newTypeName,
                "full_type": ColumnType.fullName(ColumnType.resolved(newTypeName, previous: "", kind: kind), kind: kind), "is_nullable": "YES",
                "column_default": String?.none, "primary_key": ""] as [String: String?])
        }
        if let indexes {
            indexGrid = Self.padded(indexes, extra: draft.newIndexes, template: [
                "index_name": "", "index_algorithm": "BTREE", "is_unique": "FALSE", "is_primary": "FALSE",
                "columns": "", "definition": ""])
        }
    }

    private func addColumn() {
        draft.newColumns += 1
        rebuildGrids()
        let r = baseColumns + draft.newColumns - 1
        row = r
        if let nc = col(result, "column_name") { editRequest = GridEditRequest(row: r, column: nc) }
    }

    private func addIndex() {
        draft.newIndexes += 1
        rebuildGrids()
        let r = baseIndexes + draft.newIndexes - 1
        indexRow = r
        if let nc = col(indexes, "index_name") { editRequest = GridEditRequest(row: r, column: nc) }
    }

    /// Drops a staged row and shifts the edits of the rows after it.
    private static func removing(_ r: Int, from edits: [Int: [Int: String?]]) -> [Int: [Int: String?]] {
        Dictionary(uniqueKeysWithValues: edits.compactMap { k, v in k == r ? nil : (k > r ? k - 1 : k, v) })
    }

    private func removeColumn() {
        guard let r = row, let s = session else { return }
        if r >= baseColumns {
            draft.columnEdits = Self.removing(r, from: draft.columnEdits); draft.newColumns -= 1; row = nil; rebuildGrids()
        } else if let c = column(r) {
            pending = ("Delete column \(c.name) from \(name)?", [Session.dropColumnSQL(kind, table: s.quoteTable(name), column: c.name)])
        }
    }

    private func removeIndex() {
        guard let r = indexRow, let s = session, let indexes else { return }
        if r >= baseIndexes {
            draft.indexEdits = Self.removing(r, from: draft.indexEdits); draft.newIndexes -= 1; indexRow = nil; rebuildGrids()
        } else if let nc = col(indexes, "index_name"), let idx = indexes.rows[r][nc] {
            let primary = col(indexes, "is_primary").map { indexes.rows[r][$0] == "TRUE" } ?? false
            pending = ("Delete index \(idx) of \(name)?",
                       Session.dropIndexSQL(kind, table: s.quoteTable(name), schema: s.schemaOf(name), name: idx, primary: primary))
        }
    }

    private func discard() {
        draft = TableDraft(table: draft.table)
        row = nil; indexRow = nil
        rebuildGrids()
    }

    private func reload() async {
        result = await load(name) ?? QueryResult(message: "Couldn't load the structure")
        if showIndexes || indexes != nil { await loadIndexes() } else { rebuildGrids() }
    }

    private func loadIndexes() async {
        if let session {
            do { indexes = try await session.onQueue { [name] in try $0.indexes(name) } }
            catch { self.error = error.localizedDescription; indexes = QueryResult() }
        } else { indexes = QueryResult() }
        rebuildGrids()
    }

    private func apply(_ statements: [String]) {
        guard let session else { return }
        pending = nil; running = true; error = nil
        Task {
            do {
                for s in statements { _ = try await session.onQueue { try $0.query(s) } }
                draft = TableDraft(table: draft.table); row = nil; indexRow = nil
                indexes = nil
                await reload()
                if case .diagram(let focus) = session.kind { session.showDiagram(focus) } // boxes show the new columns
            } catch { self.error = error.localizedDescription }
            running = false
        }
    }
}

/// A column type picked from a list (no free text): a base type plus, for types that take one,
/// a length / precision written as digits.
struct ColumnType: Equatable {
    var base: String
    var arguments = ""

    /// Postgres' own short names, as its data_type column shows them.
    static let postgres = ["bool", "bytea", "char", "cidr", "date", "float4", "float8", "inet", "int2", "int4", "int8", "interval",
                           "json", "jsonb", "macaddr", "money", "numeric", "text", "time", "timestamp", "timestamptz", "timetz",
                           "uuid", "varchar", "xml", "_int4", "_int8", "_text", "_varchar"]
    static let mysql = ["tinyint", "smallint", "int", "int unsigned", "bigint", "bigint unsigned", "decimal", "float", "double",
                        "bit", "char", "varchar", "tinytext", "text", "mediumtext", "longtext", "binary", "varbinary", "blob",
                        "mediumblob", "longblob", "date", "time", "datetime", "timestamp", "year", "json"]
    static let withArguments: Set<String> = ["numeric", "decimal", "character varying", "character", "char", "varchar", "bit",
                                             "varbit", "binary", "varbinary"]

    static let sqlite = ["INTEGER", "TEXT", "REAL", "NUMERIC", "BLOB"]

    /// How the structure's full_type column spells a type: Postgres' long names ("int8" → "bigint").
    static func fullName(_ type: String, kind: Conn.Kind) -> String {
        guard kind == .postgres else { return type }
        let long = ["int2": "smallint", "int4": "integer", "int8": "bigint", "float4": "real", "float8": "double precision",
                    "bool": "boolean", "varchar": "character varying", "char": "character", "timestamp": "timestamp without time zone",
                    "timestamptz": "timestamp with time zone", "time": "time without time zone", "timetz": "time with time zone"]
        if type.hasSuffix("[]") { return fullName(String(type.dropLast(2)), kind: kind) + "[]" }
        let t = ColumnType(type)
        let base = long[t.base] ?? t.base
        return t.arguments.isEmpty ? base : "\(base)(\(t.arguments))"
    }

    static func names(_ kind: Conn.Kind) -> [String] { kind == .mysql ? mysql : kind == .sqlite ? sqlite : postgres }

    /// A type picked by name from the grid menu, as SQL: Postgres arrays use their `[]` spelling, and MySQL
    /// varchar/varbinary (which need a length) keep the previous length, or get 255.
    static func resolved(_ picked: String, previous: String, kind: Conn.Kind) -> String {
        if kind == .postgres, picked.hasPrefix("_") { return String(picked.dropFirst()) + "[]" }
        guard kind == .mysql, ["varchar", "varbinary"].contains(picked) else { return picked }
        let old = ColumnType(previous)
        return "\(picked)(\(old.takesArguments && !old.arguments.isEmpty ? old.arguments.split(separator: ",")[0] : "255"))"
    }

    var takesArguments: Bool { Self.withArguments.contains(base) }
    var argumentsValid: Bool { arguments.isEmpty || arguments.range(of: #"^\d+(,\d+)?$"#, options: .regularExpression) != nil }
    var sql: String { takesArguments && !arguments.isEmpty ? "\(base)(\(arguments))" : base }

    init(base: String, arguments: String = "") { (self.base, self.arguments) = (base, arguments) }

    init(_ type: String) {
        // "character varying(200)" → base + "200"; anything else (e.g. "timestamp(6) without time zone") stays whole.
        if let m = type.range(of: #"^([a-z ]+)\(([0-9, ]+)\)$"#, options: .regularExpression), m == type.startIndex..<type.endIndex,
           let open = type.firstIndex(of: "("), Self.withArguments.contains(String(type[..<open])) {
            base = String(type[..<open])
            arguments = type[type.index(after: open)...].dropLast().replacingOccurrences(of: " ", with: "")
        } else {
            base = type
        }
    }

    /// The dialect's list, with the column's current type kept as an option when it isn't in it.
    static func choices(_ kind: Conn.Kind, current: String) -> [String] {
        let list = names(kind)
        let base = ColumnType(current).base
        return list.contains(base) ? list : [base] + list
    }
}

/// A column as the edit form sees it, read from a `structure()` row.
struct ColumnDef: Equatable {
    var name = "", type = "", nullable = true, defaultSQL = "", extra = "", comment = ""

    init(name: String, type: String, nullable: Bool = true, defaultSQL: String = "", extra: String = "", comment: String = "") {
        (self.name, self.type, self.nullable, self.defaultSQL, self.extra, self.comment) = (name, type, nullable, defaultSQL, extra, comment)
    }

    init(row: [String?], header: [String]) {
        // MySQL 8 reports information_schema names in capitals (COLUMN_NAME).
        func v(_ k: String) -> String? { header.firstIndex { $0.lowercased() == k }.flatMap { row.indices.contains($0) ? row[$0] : nil } }
        name = v("column_name") ?? ""
        type = v("full_type") ?? v("data_type") ?? ""
        nullable = (v("is_nullable") ?? "YES") != "NO"
        let rawExtra = v("extra") ?? ""
        let generated = rawExtra.contains("DEFAULT_GENERATED") // MySQL: the default is an expression
        extra = rawExtra.replacingOccurrences(of: "DEFAULT_GENERATED", with: "").trimmingCharacters(in: .whitespaces)
        comment = v("comment") ?? ""
        if let d = v("column_default") {
            // Postgres/SQLite store an SQL expression already; MySQL stores plain literal text.
            defaultSQL = header.contains(where: { $0.lowercased() == "extra" }) && !generated ? "'" + d.replacingOccurrences(of: "'", with: "''") + "'" : d
        }
    }
}

/// ⌃ + scroll zooms; ⇧ + scroll with a plain mouse wheel (vertical only) scrolls sideways.
// MARK: Clone / Truncate / Delete sheets

struct TableActionSheet: View {
    let action: TableAction
    let table: String
    let session: Session
    let done: () -> Void
    @State private var newName = ""
    @State private var withData = true
    @State private var typed = ""
    @State private var running = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch action {
            case .clone:
                Text("Clone \(table)").font(.headline)
                TextField("New table name", text: $newName).textFieldStyle(.roundedBorder).selectAllOnFocus()
                Toggle("Copy data too", isOn: $withData)
                if session.conn.kind == .sqlite {
                    Text("SQLite copies columns and data, but not constraints or indexes.").font(.caption).foregroundStyle(.secondary)
                }
                sqlPreview(session.cloneSQL(table, to: newName, withData: withData))
            default:
                Text(action == .truncate ? "Truncate \(table)?" : "Delete \(table)?").font(.headline)
                Text(action == .truncate
                     ? "Every row is deleted. The table itself stays. This cannot be undone."
                     : "The table and all its data are dropped. This cannot be undone.")
                    .foregroundStyle(.secondary)
                Text("Connection: \(session.conn.name) · \(session.conn.database)").font(.caption).foregroundStyle(.secondary)
                // Typing the name guards against the wrong table / wrong database (e.g. production).
                TextField("Type \(table) to confirm", text: $typed).textFieldStyle(.roundedBorder)
                sqlPreview(action == .truncate ? session.truncateSQL(table) : session.dropSQL(table))
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(action == .clone ? "Clone" : (action == .truncate ? "Truncate" : "Delete"), role: action == .clone ? nil : .destructive) { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || !canRun)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear { newName = "\(table)_copy" }
    }

    private var canRun: Bool {
        action == .clone ? !newName.trimmingCharacters(in: .whitespaces).isEmpty && newName != table : typed == table
    }

    private func sqlPreview(_ sql: String) -> some View {
        Text(sql).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }

    private func run() {
        let sql: String = switch action {
        case .clone: session.cloneSQL(table, to: newName.trimmingCharacters(in: .whitespaces), withData: withData)
        case .truncate: session.truncateSQL(table)
        default: session.dropSQL(table)
        }
        running = true; error = nil
        Task {
            defer { running = false }
            do {
                try await session.execute(sql)
                if action == .truncate, session.table == table { session.browse(table) } // show it empty
                done()
            } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: Schemas and "+" (new object) menu

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

/// Bottom of the sidebar: "+" menu (new table/view/…/schema) and the schema picker.
struct SidebarFooter: View {
    @Bindable var session: Session
    let newSchema: () -> Void
    let newDatabase: () -> Void
    var transfer: (TransferSheet.Mode) -> Void = { _ in }
    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(session.availableNewObjects(), id: \.self) { o in
                    Button(o.title) { session.openTemplate(o) }
                }
                if session.conn.kind == .postgres || session.conn.kind == .mysql {
                    Divider()
                    if session.conn.kind == .postgres { Button("New Schema…", action: newSchema) }
                    Button("New Database…", action: newDatabase)
                }
                if session.canTransfer {
                    Divider()
                    Button("Export Database…") { transfer(.export) }
                    Button("Import Database…") { transfer(.import) }
                }
            } label: { Image(systemName: "plus") }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New table, view, function, schema or database; export or import")
            if session.conn.kind == .postgres, !session.schemas.isEmpty {
                Picker("Schema", selection: $session.schema) {
                    ForEach(session.schemas, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .help("Schema")
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Name prompt for CREATE SCHEMA / CREATE DATABASE, with the exact SQL shown before it runs.
struct NewSchemaSheet: View {
    enum What { case schema, database }
    let session: Session
    var what = What.schema
    let done: () -> Void
    @State private var name = ""
    @State private var openAfter = true
    @State private var error: String?
    @State private var running = false
    private var noun: String { what == .schema ? "Schema" : "Database" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New \(noun)").font(.headline)
            TextField("\(noun) name", text: $name).textFieldStyle(.roundedBorder).onSubmit(run)
            if what == .database { Toggle("Switch to it after creating", isOn: $openAfter) }
            Text(what == .schema ? "CREATE SCHEMA \(quoteIdent(name.isEmpty ? "name" : name))" : session.createDatabaseSQL(name.isEmpty ? "name" : name))
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Create", action: run).keyboardShortcut(.defaultAction)
                    .disabled(running || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18).frame(width: 400)
    }
    private func run() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        running = true; error = nil
        Task {
            defer { running = false }
            do {
                if what == .schema { try await session.createSchema(n) } else { try await session.createDatabase(n, open: openAfter) }
                done()
            } catch { self.error = error.localizedDescription }
        }
    }
}


/// Key to the line ends in the diagram, drawn against a table edge so it's clear which end is which.
struct RelationLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            item("one (1)") { DiagramView.oneMark($0, at: CGPoint(x: 30, y: 9), outward: -1) }
            item("many (N)") { DiagramView.manyMark($0, at: CGPoint(x: 30, y: 9), outward: -1) }
            Text("Click a table to see its relations").foregroundStyle(.tertiary)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .help("Each line joins a foreign key (the many end) to the row it references (the one end). Many-to-many relations go through a linking table, shown as two of these.")
    }

    private func item(_ label: String, _ mark: @escaping (CGMutablePath) -> Void) -> some View {
        HStack(spacing: 5) {
            Canvas { ctx, _ in
                let line = CGMutablePath(); line.move(to: CGPoint(x: 0, y: 9)); line.addLine(to: CGPoint(x: 30, y: 9))
                mark(line)
                ctx.stroke(Path(line), with: .color(.secondary), lineWidth: 1.4)
                // The table edge the mark touches.
                ctx.fill(Path(roundedRect: CGRect(x: 30, y: 1, width: 3, height: 16), cornerRadius: 1), with: .color(.secondary.opacity(0.6)))
            }
            .frame(width: 34, height: 18)
            Text(label)
        }
    }
}
