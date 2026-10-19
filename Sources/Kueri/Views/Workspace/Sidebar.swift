import AppKit
import SwiftUI

/// Source-list NSOutlineView for the sidebar. Tables expand to their columns (name, type, key icon),
/// loaded on first expand. AppKit instead of SwiftUI's List, which rebuilt every row on each database
/// switch (40–100 ms stall with 239 tables, measured); this only creates the visible rows.
struct SidebarList: NSViewRepresentable {
    let items: [String]
    var stripPrefix = ""   // e.g. "audit." — the schema picker already says which schema this is
    let icon: String
    var expandable = true
    let onSelect: (String) -> Void
    var loadColumns: (String, @escaping ([ColumnInfo]) -> Void) -> Void = { _, done in done([]) }
    var actions: [TableAction] = []
    var onAction: (TableAction, String) -> Void = { _, _ in }

    final class TableNode {
        let name: String
        var columns: [ColumnInfo]?   // nil = not loaded yet
        init(_ name: String) { self.name = name }
    }
    final class ColumnNode {
        let info: ColumnInfo
        unowned let table: TableNode
        init(_ info: ColumnInfo, _ table: TableNode) { self.info = info; self.table = table }
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var nodes: [TableNode] = []
        var byName: [String: TableNode] = [:] // keeps loaded columns across filter changes
        var columnNodes: [ObjectIdentifier: [ColumnNode]] = [:]
        var icon = ""
        var expandable = true
        var onSelect: (String) -> Void = { _ in }
        var loadColumns: (String, @escaping ([ColumnInfo]) -> Void) -> Void = { _, done in done([]) }
        var image: NSImage?
        let keyImage = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Primary key")
        var reselecting = false
        var stripPrefix = ""
        var actions: [TableAction] = []
        var onAction: (TableAction, String) -> Void = { _, _ in }
        weak var outline: NSOutlineView?

        // Right-click menu, built for the clicked row (table or one of its columns).
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let ov = outline, ov.clickedRow >= 0 else { return }
            let item = ov.item(atRow: ov.clickedRow)
            guard let name = (item as? TableNode)?.name ?? (item as? ColumnNode)?.table.name else { return }
            let groups: [[TableAction]] = [[.openNewTab, .structure], [.copyName], [.clone, .truncate, .delete]]
            for group in groups {
                let available = group.filter(actions.contains)
                guard !available.isEmpty else { continue }
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                for a in available {
                    let mi = NSMenuItem(title: a.title, action: #selector(menuAction(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = MenuPick(action: a, table: name)
                    menu.addItem(mi)
                }
            }
        }
        final class MenuPick { let action: TableAction; let table: String; init(action: TableAction, table: String) { self.action = action; self.table = table } }
        @objc func menuAction(_ sender: NSMenuItem) {
            guard let p = sender.representedObject as? MenuPick else { return }
            onAction(p.action, p.table)
        }

        func children(_ t: TableNode) -> [ColumnNode] {
            if let c = columnNodes[ObjectIdentifier(t)] { return c }
            let c = (t.columns ?? []).map { ColumnNode($0, t) }
            columnNodes[ObjectIdentifier(t)] = c
            return c
        }

        func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil { return nodes.count }
            if let t = item as? TableNode { return children(t).count }
            return 0
        }
        func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let t = item as? TableNode { return children(t)[index] }
            return nodes[index]
        }
        func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard expandable, let t = item as? TableNode else { return false }
            return t.columns == nil || !(t.columns!.isEmpty)
        }

        // First expand: fetch columns, then expand for real.
        func outlineView(_ ov: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            guard let t = item as? TableNode else { return false }
            if t.columns != nil { return true }
            loadColumns(t.name) { [weak ov, weak self] cols in
                t.columns = cols
                self?.columnNodes[ObjectIdentifier(t)] = nil
                ov?.reloadItem(t, reloadChildren: true)
                if !cols.isEmpty { ov?.expandItem(t) }
            }
            return false
        }

        func outlineView(_ ov: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
            if let t = item as? TableNode {
                let cell = ov.makeView(withIdentifier: .init("table"), owner: nil) as? NSTableCellView ?? makeCell("table")
                cell.textField?.stringValue = stripPrefix.isEmpty || !t.name.hasPrefix(stripPrefix) ? t.name : String(t.name.dropFirst(stripPrefix.count))
                cell.imageView?.image = image
                return cell
            }
            guard let c = item as? ColumnNode else { return nil }
            let cell = ov.makeView(withIdentifier: .init("column"), owner: nil) as? ColumnCell ?? ColumnCell()
            cell.set(c.info, key: keyImage)
            return cell
        }

        private func makeCell(_ id: String) -> NSTableCellView {
            let c = NSTableCellView()
            c.identifier = .init(id)
            let iv = NSImageView(), tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
            tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            [iv, tf].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; c.addSubview($0) }
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16),
                iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.imageView = iv; c.textField = tf
            return c
        }

        func outlineViewSelectionDidChange(_ n: Notification) {
            guard !reselecting, let ov = n.object as? NSOutlineView else { return }
            let item = ov.item(atRow: ov.selectedRow)
            let name = (item as? TableNode)?.name ?? (item as? ColumnNode)?.table.name
            guard let name else { return }
            DispatchQueue.main.async { [onSelect] in onSelect(name) } // outside AppKit's event handling
        }
    }

    /// Column row: [key] name ............ type
    final class ColumnCell: NSTableCellView {
        let key = NSImageView(), nameField = NSTextField(labelWithString: ""), typeField = NSTextField(labelWithString: "")
        init() {
            super.init(frame: .zero)
            identifier = .init("column")
            nameField.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            typeField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            typeField.textColor = .secondaryLabelColor
            typeField.alignment = .right
            nameField.lineBreakMode = .byTruncatingTail
            typeField.lineBreakMode = .byTruncatingTail
            // When space is short the name truncates first; the type keeps its width (capped below).
            nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            typeField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            typeField.setContentHuggingPriority(.required, for: .horizontal)
            key.contentTintColor = .systemYellow
            [key, nameField, typeField].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
            NSLayoutConstraint.activate([
                key.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                key.centerYAnchor.constraint(equalTo: centerYAnchor),
                key.widthAnchor.constraint(equalToConstant: 12),
                key.heightAnchor.constraint(equalToConstant: 12),
                nameField.leadingAnchor.constraint(equalTo: key.trailingAnchor, constant: 4),
                nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
                typeField.leadingAnchor.constraint(greaterThanOrEqualTo: nameField.trailingAnchor, constant: 8),
                typeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                typeField.centerYAnchor.constraint(equalTo: centerYAnchor),
                typeField.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.45),
            ])
            textField = nameField
        }
        required init?(coder: NSCoder) { fatalError() }
        func set(_ c: ColumnInfo, key image: NSImage?) {
            nameField.stringValue = c.name
            typeField.stringValue = c.type
            key.image = c.isPrimaryKey ? image : nil
            toolTip = "\(c.name) — \(c.type)\(c.isPrimaryKey ? " (primary key)" : "")"
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let ov = NSOutlineView()
        ov.style = .sourceList
        ov.focusRingType = .none
        ov.headerView = nil
        ov.rowHeight = 22
        ov.indentationPerLevel = 8
        let col = NSTableColumn(identifier: .init("name"))
        col.resizingMask = .autoresizingMask
        ov.addTableColumn(col)
        ov.outlineTableColumn = col
        ov.autoresizesOutlineColumn = false // default widens the column past the sidebar on expand, clipping types
        ov.columnAutoresizingStyle = .uniformColumnAutoresizingStyle // the one column always fills the sidebar
        ov.dataSource = context.coordinator
        ov.delegate = context.coordinator
        let menu = NSMenu()
        menu.delegate = context.coordinator
        ov.menu = menu
        context.coordinator.outline = ov
        let sv = FillScrollView()
        sv.documentView = ov
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.focusRingType = .none
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onSelect = onSelect
        c.loadColumns = loadColumns
        c.expandable = expandable
        c.actions = actions
        c.onAction = onAction
        if c.stripPrefix != stripPrefix { c.stripPrefix = stripPrefix; c.nodes = [] } // force a reload with new labels
        if c.icon != icon {
            c.icon = icon
            c.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        }
        guard c.nodes.map(\.name) != items, let ov = sv.documentView as? NSOutlineView else { return }
        let selected = (ov.item(atRow: ov.selectedRow) as? TableNode)?.name
        let expanded = c.nodes.filter { ov.isItemExpanded($0) }.map(\.name)
        // Same names (filtering) reuse nodes and their loaded columns; a new database starts fresh.
        if Set(items).isSubset(of: c.byName.keys) || c.byName.isEmpty {
            c.nodes = items.map { c.byName[$0] ?? TableNode($0) }
        } else {
            c.byName = [:]; c.columnNodes = [:]
            c.nodes = items.map(TableNode.init)
        }
        for n in c.nodes { c.byName[n.name] = n }
        ov.reloadData()
        for n in c.nodes where expanded.contains(n.name) && n.columns != nil { ov.expandItem(n) }
        if let selected, let n = c.byName[selected], items.contains(selected) {
            c.reselecting = true // highlight only; must not trigger a browse
            ov.selectRowIndexes([ov.row(forItem: n)], byExtendingSelection: false)
            c.reselecting = false
        }
    }
}

/// Keeps a single-column table exactly as wide as the visible area. Column autoresizing alone
/// misses the case where the view is created narrow and grows (e.g. switching sidebar tabs).
final class FillScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let t = documentView as? NSTableView, t.tableColumns.count == 1 else { return }
        let w = max(contentSize.width - t.intercellSpacing.width, 40)
        if abs(t.tableColumns[0].width - w) > 0.5 { t.tableColumns[0].width = w }
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
