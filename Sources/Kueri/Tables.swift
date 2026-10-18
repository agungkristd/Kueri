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
    func showDiagram(_ name: String) {
        let tab: UUID
        if case .diagram = kind, edits.isEmpty { kind = .diagram(name); diagram = nil; error = nil; tab = activeTab }
        else { tab = newTab(.diagram(name)) }
        let all = visibleTables
        Task {
            do {
                let model = try await onQueue { db -> DiagramModel in
                    let fks = try db.foreignKeys()
                    if name.isEmpty { return try Self.wholeDiagram(db, tables: all, fks: fks) }
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

// MARK: Diagram tab

struct DiagramTable: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let columns: [ColumnInfo]
}

/// Click-and-drag on the diagram background scrolls the enclosing scroll view.
/// Table boxes sit above it, so dragging a box still moves the box.
struct PanSurface: NSViewRepresentable {
    final class View: NSView {
        private var last: NSPoint?
        override func mouseDown(with e: NSEvent) { last = e.locationInWindow }
        override func mouseUp(with e: NSEvent) { last = nil }
        override func mouseDragged(with e: NSEvent) {
            guard let last, let sv = enclosingScrollView else { return }
            let p = e.locationInWindow
            pan(sv, dx: p.x - last.x, dy: p.y - last.y)
            self.last = p
        }
        /// Content follows the pointer: moving right shows what's further left.
        func pan(_ sv: NSScrollView, dx: CGFloat, dy: CGFloat) {
            let clip = sv.contentView, doc = sv.documentView?.frame.size ?? .zero
            var o = clip.bounds.origin
            o.x -= dx
            o.y += clip.isFlipped ? dy : -dy  // window y grows upwards
            o.x = min(max(0, o.x), max(0, doc.width - clip.bounds.width))
            o.y = min(max(0, o.y), max(0, doc.height - clip.bounds.height))
            clip.scroll(to: o)
            sv.reflectScrolledClipView(clip)
        }
    }
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ v: View, context: Context) {}
}

struct DiagramModel {
    let focus: String  // empty for the whole-database diagram
    let tables: [DiagramTable]
    let links: [ForeignKey]
    var positions: [String: CGPoint] = [:]  // precomputed layout (whole database)
}

struct DiagramView: View {
    let model: DiagramModel?
    var error: String?
    var structure: (String) async -> QueryResult? = { _ in nil }
    var onAction: (TableAction, String) -> Void = { _, _ in }
    var session: Session?  // enables column editing in the details popover
    @State private var selected: String?
    @State private var inspecting: String?
    @State private var draft = TableDraft()    // lives here so an app switch doesn't lose it
    @State private var reopen: String?         // popover closed by switching apps; shown again on return
    @State private var pos: [String: CGPoint] = [:]
    @State private var dragStart: [String: CGPoint] = [:]
    @State private var zoom: CGFloat = 1
    @State private var pinchStart: CGFloat?
    @State private var viewport = CGSize(width: 800, height: 600)

    static let width: CGFloat = 250, header: CGFloat = 34, row: CGFloat = 22, maxRows = 40
    static let zoomRange: ClosedRange<CGFloat> = 0.2...2.5

    private func setZoom(_ z: CGFloat) { zoom = min(max(z, Self.zoomRange.lowerBound), Self.zoomRange.upperBound) }

    var body: some View {
        if let model {
            let size = canvasSize(model)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in draw(model, in: &ctx) }
                        .frame(width: size.width, height: size.height)
                    PanSurface().frame(width: size.width, height: size.height) // drag on empty space scrolls
                    ForEach(model.tables) { t in
                        // One highlighted table: the clicked one, or the diagram's own table until then.
                        box(t, selected: t.name == (selected ?? model.focus))
                            .popover(isPresented: Binding(get: { inspecting == t.name }, set: { if !$0 { inspecting = nil } }),
                                     arrowEdge: .trailing) {
                                DiagramTableInfo(name: t.name, session: session, load: structure, draft: $draft) { action in
                                    inspecting = nil; onAction(action, t.name)
                                }
                            }
                            .onTapGesture(count: 2) { selected = t.name; inspecting = t.name }
                            .onTapGesture { selected = t.name }
                            .contextMenu {
                                Button("Show Details") { selected = t.name; inspecting = t.name }
                                Divider()
                                Button("Open Data") { onAction(.openNewTab, t.name) }
                                Button("Open Structure") { onAction(.structure, t.name) }
                                Divider()
                                Button("Delete Table…", role: .destructive) { onAction(.delete, t.name) }
                            }
                            .offset(x: point(t.name, model).x, y: point(t.name, model).y)
                            .gesture(DragGesture()
                                .onChanged { g in
                                    NSCursor.closedHand.set()
                                    let start = dragStart[t.name] ?? point(t.name, model)
                                    dragStart[t.name] = start
                                    pos[t.name] = CGPoint(x: max(0, start.x + g.translation.width), y: max(0, start.y + g.translation.height))
                                }
                                .onEnded { _ in dragStart[t.name] = nil; NSCursor.openHand.set() })
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                // Grab hand only over a table (it can be dragged); the plain arrow everywhere else.
                .onContinuousHover { phase in
                    guard case .active(let p) = phase else { NSCursor.arrow.set(); return }
                    let overTable = model.tables.contains { t in
                        CGRect(origin: point(t.name, model), size: CGSize(width: Self.width, height: Self.height(t))).contains(p)
                    }
                    (overTable ? NSCursor.openHand : NSCursor.arrow).set()
                }
                // Scaled drawing plus a frame of the scaled size, so scrolling covers the zoomed canvas.
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: size.width * zoom, height: size.height * zoom, alignment: .topLeading)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .background(GeometryReader { g in Color.clear.onAppear { viewport = g.size }.onChange(of: g.size) { viewport = $1 } })
            .background(ScrollModifierMonitor(zoom: { setZoom(zoom * $0) }))
            .simultaneousGesture(MagnifyGesture()
                .onChanged { g in
                    let base = pinchStart ?? zoom
                    pinchStart = base
                    setZoom(base * g.magnification)
                }
                .onEnded { _ in pinchStart = nil })
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 2) {
                    Button { setZoom(zoom / 1.25) } label: { Image(systemName: "minus") }
                        .keyboardShortcut("-", modifiers: .command).help("Zoom out (⌘−, or ⌃ + scroll)")
                    Button { setZoom(1) } label: { Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().frame(minWidth: 44) }
                        .keyboardShortcut("0", modifiers: .command).help("Actual size (⌘0)")
                    Button { setZoom(zoom * 1.25) } label: { Image(systemName: "plus") }
                        .keyboardShortcut("=", modifiers: .command).help("Zoom in (⌘+, or ⌃ + scroll)")
                    Button("Fit") { setZoom(min(viewport.width / size.width, viewport.height / size.height, 1)) }
                        .help("Fit the whole diagram in the window")
                }
                .buttonStyle(.accessoryBarAction)
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
            }
            .onChange(of: model.focus) { pos = [:]; zoom = 1; selected = nil; inspecting = nil }
            .onChange(of: inspecting) { old, new in if let new, new != old, new != draft.table { draft = TableDraft(table: new) } }
            // Popovers close when the app is deactivated (⌘-Tab); bring this one back on return.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in reopen = inspecting }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if let r = reopen, inspecting == nil { inspecting = r }
                reopen = nil
            }
        } else if let error {
            Text(error).foregroundStyle(.red).textSelection(.enabled).padding()
        } else {
            ProgressView("Loading diagram…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // Layout: tables the focus references on the right, tables referencing it on the left.
    private func initial(_ name: String, _ m: DiagramModel) -> CGPoint {
        if let p = m.positions[name] { return p }
        let parents = m.tables.map(\.name).filter { n in n != m.focus && m.links.contains { $0.fromTable == m.focus && $0.toTable == n } }
        let children = m.tables.map(\.name).filter { n in n != m.focus && !parents.contains(n) }
        let gap: CGFloat = 120, x0: CGFloat = 40
        func stackY(_ list: [String], _ n: String) -> CGFloat {
            var y: CGFloat = 40
            for other in list { if other == n { return y }; y += Self.height(m.tables.first { $0.name == other }!) + 40 }
            return y
        }
        if name == m.focus { return CGPoint(x: x0 + Self.width + gap, y: 40) }
        if let _ = parents.firstIndex(of: name) { return CGPoint(x: x0 + 2 * (Self.width + gap), y: stackY(parents, name)) }
        return CGPoint(x: x0, y: stackY(children, name))
    }
    private func point(_ name: String, _ m: DiagramModel) -> CGPoint { pos[name] ?? initial(name, m) }

    nonisolated static func height(_ t: DiagramTable) -> CGFloat {
        Self.header + CGFloat(min(t.columns.count, Self.maxRows) + (t.columns.count > Self.maxRows ? 1 : 0)) * Self.row + 12
    }

    private func canvasSize(_ m: DiagramModel) -> CGSize {
        var w: CGFloat = 800, h: CGFloat = 600
        for t in m.tables {
            let p = point(t.name, m)
            w = max(w, p.x + Self.width + 80); h = max(h, p.y + Self.height(t) + 80)
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

    private func box(_ t: DiagramTable, selected: Bool) -> some View {
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
        .frame(width: Self.width, height: Self.height(t), alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .help("Double-click or right-click for details")
    }
}

/// Popover for a table clicked in the diagram: its structure and the usual actions.
/// Unsaved work in the details popover. Grid edits are keyed by row → result column; rows past the
/// loaded ones are new (not yet created) columns / indexes.
struct TableDraft {
    var table = ""
    var columnEdits: [Int: [Int: String?]] = [:]
    var newColumns = 0
    var indexEdits: [Int: [Int: String?]] = [:]
    var newIndexes = 0
    var editing: (row: Int, old: ColumnDef, new: ColumnDef)?
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
            .frame(height: 240)
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
                        Button("Edit…") { if let row { openForm(row) } }.disabled(row.map { $0 >= baseColumns } ?? true)
                    }
                    Text(showIndexes ? "New index: type a name, then pick its columns (in order), algorithm and unique."
                                     : "Double-click a cell to edit it; type and NULL are picked from a menu.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let e = draft.editing, !showIndexes { editor(e) }
                if !draft.isEmpty {
                    HStack {
                        let count = draft.columnEdits.keys.filter { $0 < baseColumns }.count + draft.newColumns
                            + draft.newIndexes
                        Text("\(count) unsaved change\(count == 1 ? "" : "s")").foregroundStyle(.secondary)
                        if incomplete { Text("· new rows need a name\(showIndexes ? " and columns" : "")").font(.caption).foregroundStyle(.orange) }
                        Spacer()
                        Button("Discard") { discard() }
                        Button("Save Changes…") { pending = ("Save changes to \(name)?", columnSQL + indexSQL) }
                            .keyboardShortcut("s", modifiers: .command)
                            .disabled((columnSQL + indexSQL).isEmpty || incomplete)
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).lineLimit(6) }
            Divider()
            HStack {
                Button("Delete Table…", role: .destructive) { action(.delete) }
                Spacer()
                Button("Open Structure") { action(.structure) }
                Button("Open Data") { action(.openNewTab) }.keyboardShortcut(draft.editing == nil && draft.isEmpty ? .defaultAction : nil)
            }
        }
        .padding(14)
        .frame(width: 600)
        .disabled(running)
        .task { await reload() }
        // With the form open, selecting another existing row edits that column instead.
        .onChange(of: row) { _, r in if let r, r < baseColumns, let e = draft.editing, e.row != r, e.row >= 0 { openForm(r) } }
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
                       onDoubleClick: { r, _ in if r < baseColumns { openForm(r) } },
                       menuForCell: { r, c in
                           let changeable = r >= baseColumns || kind != .sqlite
                           if c == tc, changeable { return ColumnType.names(kind) }
                           if c == nullc, changeable { return ["YES", "NO"] }
                           return nil
                       },
                       editsOnSingleClick: { r in r >= baseColumns || draft.columnEdits[r] != nil })
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
        draft.editing = nil
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

    private func openForm(_ r: Int) {
        guard session != nil, let c = column(r) else { return }
        row = r; error = nil
        draft.editing = (r, c, c)
    }

    @ViewBuilder private func editor(_ e: (row: Int, old: ColumnDef, new: ColumnDef)) -> some View {
        let new = Binding(get: { draft.editing?.new ?? e.new }, set: { draft.editing?.new = $0 })
        let type = Binding(get: { ColumnType(new.wrappedValue.type) }, set: { new.wrappedValue.type = $0.sql })
        let isNew = e.row < 0
        let sql = session.map { s in
            isNew ? [Session.addColumnSQL(kind, table: s.quoteTable(name), column: new.wrappedValue)]
                  : Session.alterColumnSQL(kind, table: s.quoteTable(name), from: e.old, to: new.wrappedValue)
        } ?? []
        let locked = kind == .sqlite && !isNew  // SQLite: rename only
        let numeric = type.wrappedValue.base.contains("numeric") || type.wrappedValue.base.contains("decimal")
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "New Column" : "Edit Column \(e.old.name)").font(.headline)
            // Labels right-aligned in one column, fields in the other.
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("Name", text: new.name, prompt: Text("column_name")).labelsHidden()
                }
                GridRow {
                    Text("Type")
                    HStack(spacing: 8) {
                        Picker("Type", selection: type.base) {
                            ForEach(ColumnType.choices(kind, current: e.old.type), id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(width: 200)
                        if type.wrappedValue.takesArguments {
                            Text(numeric ? "Precision" : "Length").foregroundStyle(.secondary)
                            TextField(numeric ? "Precision" : "Length", text: type.arguments, prompt: Text(numeric ? "10,2" : "255"))
                                .labelsHidden().frame(width: 70)
                                .help("Digits only, e.g. 255 or 10,2. Leave empty for no limit.")
                        }
                        Spacer(minLength: 0)
                    }
                    .disabled(locked)
                }
                GridRow {
                    Text("Default")
                    TextField("Default", text: new.defaultSQL, prompt: Text("none (SQL expression, e.g. 0 or now())")).labelsHidden().disabled(locked)
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Toggle("Allow NULL", isOn: new.nullable).disabled(locked)
                }
            }
            if kind == .sqlite && !isNew { Text("SQLite can only rename a column; other changes need the table rebuilt.").font(.caption).foregroundStyle(.secondary) }
            if !type.wrappedValue.argumentsValid { Text("Length must be digits, e.g. 255 or 10,2.").font(.caption).foregroundStyle(.red) }
            Text(isNew && new.wrappedValue.name.isEmpty ? "Name the new column." : sql.isEmpty ? "No changes" : sql.joined(separator: ";\n") + ";")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel") { draft.editing = nil }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add…" : "Apply…") {
                    pending = (isNew ? "Add column \(new.wrappedValue.name) to \(name)?" : "Change column \(e.old.name) of \(name)?", sql)
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sql.isEmpty || new.wrappedValue.name.isEmpty || !type.wrappedValue.argumentsValid)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
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
/// A local event monitor scoped to this view's frame, so other parts of the window aren't affected.
struct ScrollModifierMonitor: NSViewRepresentable {
    let zoom: (CGFloat) -> Void

    final class V: NSView {
        var zoom: (CGFloat) -> Void = { _ in }
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, e.window === self.window,
                      self.bounds.contains(self.convert(e.locationInWindow, from: nil)) else { return e }
                if e.modifierFlags.contains(.control) {
                    let d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 200 : e.scrollingDeltaY / 20
                    if d != 0 { self.zoom(1 + max(-0.5, min(0.5, d))) }
                    return nil
                }
                if e.modifierFlags.contains(.shift), e.scrollingDeltaX == 0, e.scrollingDeltaY != 0,
                   let cg = e.cgEvent?.copy() { // wheel mice only send vertical deltas
                    cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: cg.getIntegerValueField(.scrollWheelEventDeltaAxis1))
                    cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
                    cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
                    cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
                    cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
                    cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
                    return NSEvent(cgEvent: cg) ?? e
                }
                return e
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.zoom = zoom; return v }
    func updateNSView(_ v: V, context: Context) { v.zoom = zoom }
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
