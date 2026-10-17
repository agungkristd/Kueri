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
        case .diagram(let t): "\(t) · diagram"
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

    /// The table plus every table linked to it by a foreign key, in either direction.
    func showDiagram(_ name: String) {
        let tab = newTab(.diagram(name))
        Task {
            do {
                let model = try await onQueue { db -> DiagramModel in
                    let fks = try db.foreignKeys()
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
            b.bezelStyle = .recessed
            b.showsBorderOnlyWhileMouseInside = !active
            b.setButtonType(.pushOnPushOff)
            b.state = active ? .on : .off
            b.imagePosition = .imageLeading
            b.lineBreakMode = .byTruncatingTail
            b.toolTip = t.title
            b.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small) + 1, weight: active ? .semibold : .regular)
            b.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let x = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")!,
                             target: c, action: #selector(Coordinator.close(_:)))
            x.tag = i
            x.bezelStyle = .recessed
            x.showsBorderOnlyWhileMouseInside = true
            x.toolTip = "Close tab"
            x.imageScaling = .scaleProportionallyDown
            x.controlSize = .small
            stack.addArrangedSubview(b)
            stack.addArrangedSubview(x)
            stack.setCustomSpacing(10, after: x)
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

// MARK: Diagram tab

struct DiagramTable: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let columns: [ColumnInfo]
}

struct DiagramModel {
    let focus: String
    let tables: [DiagramTable]
    let links: [ForeignKey]
}

struct DiagramView: View {
    let model: DiagramModel?
    var error: String?
    @State private var pos: [String: CGPoint] = [:]
    @State private var dragStart: [String: CGPoint] = [:]

    static let width: CGFloat = 250, header: CGFloat = 34, row: CGFloat = 22, maxRows = 40

    var body: some View {
        if let model {
            let size = canvasSize(model)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in draw(model, in: &ctx) }
                        .frame(width: size.width, height: size.height)
                    ForEach(model.tables) { t in
                        box(t, focus: t.name == model.focus)
                            .offset(x: point(t.name, model).x, y: point(t.name, model).y)
                            .gesture(DragGesture()
                                .onChanged { g in
                                    let start = dragStart[t.name] ?? point(t.name, model)
                                    dragStart[t.name] = start
                                    pos[t.name] = CGPoint(x: max(0, start.x + g.translation.width), y: max(0, start.y + g.translation.height))
                                }
                                .onEnded { _ in dragStart[t.name] = nil })
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .onChange(of: model.focus) { pos = [:] }
        } else if let error {
            Text(error).foregroundStyle(.red).textSelection(.enabled).padding()
        } else {
            ProgressView("Loading diagram…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // Layout: tables the focus references on the right, tables referencing it on the left.
    private func initial(_ name: String, _ m: DiagramModel) -> CGPoint {
        let parents = m.tables.map(\.name).filter { n in n != m.focus && m.links.contains { $0.fromTable == m.focus && $0.toTable == n } }
        let children = m.tables.map(\.name).filter { n in n != m.focus && !parents.contains(n) }
        let gap: CGFloat = 120, x0: CGFloat = 40
        func stackY(_ list: [String], _ n: String) -> CGFloat {
            var y: CGFloat = 40
            for other in list { if other == n { return y }; y += height(m.tables.first { $0.name == other }!) + 40 }
            return y
        }
        if name == m.focus { return CGPoint(x: x0 + Self.width + gap, y: 40) }
        if let _ = parents.firstIndex(of: name) { return CGPoint(x: x0 + 2 * (Self.width + gap), y: stackY(parents, name)) }
        return CGPoint(x: x0, y: stackY(children, name))
    }
    private func point(_ name: String, _ m: DiagramModel) -> CGPoint { pos[name] ?? initial(name, m) }

    private func height(_ t: DiagramTable) -> CGFloat {
        Self.header + CGFloat(min(t.columns.count, Self.maxRows) + (t.columns.count > Self.maxRows ? 1 : 0)) * Self.row + 12
    }

    private func canvasSize(_ m: DiagramModel) -> CGSize {
        var w: CGFloat = 800, h: CGFloat = 600
        for t in m.tables {
            let p = point(t.name, m)
            w = max(w, p.x + Self.width + 80); h = max(h, p.y + height(t) + 80)
        }
        return CGSize(width: w, height: h)
    }

    private func rowY(_ table: String, _ column: String, _ m: DiagramModel) -> CGFloat {
        let t = m.tables.first { $0.name == table }!
        let i = min(t.columns.firstIndex { $0.name == column } ?? 0, Self.maxRows) // hidden rows anchor to "more"
        return point(table, m).y + Self.header + CGFloat(i) * Self.row + Self.row / 2
    }

    private func draw(_ m: DiagramModel, in ctx: inout GraphicsContext) {
        for fk in m.links {
            let a = point(fk.fromTable, m), b = point(fk.toTable, m)
            let y1 = rowY(fk.fromTable, fk.fromColumn, m), y2 = rowY(fk.toTable, fk.toColumn, m)
            let fromRight = a.x + Self.width <= b.x || (abs(a.x - b.x) < Self.width && fk.fromTable != fk.toTable)
            let start = CGPoint(x: fromRight ? a.x + Self.width : a.x, y: y1)
            let endOnLeft = fromRight ? (a.x + Self.width <= b.x) : false
            let end = CGPoint(x: endOnLeft ? b.x : b.x + Self.width, y: y2)
            let bend: CGFloat = 60
            var path = Path()
            path.move(to: start)
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x + (fromRight ? bend : -bend), y: start.y),
                          control2: CGPoint(x: end.x + (endOnLeft ? -bend : bend), y: end.y))
            ctx.stroke(path, with: .color(.secondary), lineWidth: 2)
            // arrowhead pointing into the referenced table
            let dir: CGFloat = endOnLeft ? 1 : -1
            var head = Path()
            head.move(to: end)
            head.addLine(to: CGPoint(x: end.x - dir * 9, y: end.y - 5))
            head.addLine(to: CGPoint(x: end.x - dir * 9, y: end.y + 5))
            head.closeSubpath()
            ctx.fill(head, with: .color(.secondary))
        }
    }

    private func box(_ t: DiagramTable, focus: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t.name).font(.headline).lineLimit(1).frame(maxWidth: .infinity).frame(height: Self.header)
            ForEach(t.columns.prefix(Self.maxRows), id: \.self) { c in
                HStack(spacing: 6) {
                    if c.isPrimaryKey { Image(systemName: "key.fill").font(.caption2).foregroundStyle(.yellow) }
                    Text(c.name).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(c.type).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.callout)
                .frame(height: Self.row)
            }
            if t.columns.count > Self.maxRows {
                Text("+ \(t.columns.count - Self.maxRows) more").font(.caption).foregroundStyle(.secondary).frame(height: Self.row)
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
        .frame(width: Self.width, height: height(t), alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(focus ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: focus ? 2 : 1))
        .contentShape(Rectangle())
    }
}

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
    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(session.availableNewObjects(), id: \.self) { o in
                    Button(o.title) { session.openTemplate(o) }
                }
                if session.conn.kind == .postgres {
                    Divider()
                    Button("New Schema…", action: newSchema)
                }
            } label: { Image(systemName: "plus") }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New table, view, function or schema")
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

struct NewSchemaSheet: View {
    let session: Session
    let done: () -> Void
    @State private var name = ""
    @State private var error: String?
    @State private var running = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Schema").font(.headline)
            TextField("Schema name", text: $name).textFieldStyle(.roundedBorder).onSubmit(run)
            Text("CREATE SCHEMA \(quoteIdent(name.isEmpty ? "name" : name))")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Create", action: run).keyboardShortcut(.defaultAction)
                    .disabled(running || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18).frame(width: 380)
    }
    private func run() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        running = true; error = nil
        Task {
            defer { running = false }
            do { try await session.createSchema(n); done() } catch { self.error = error.localizedDescription }
        }
    }
}
