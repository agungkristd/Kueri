import AppKit
import SwiftUI

struct WorkspaceView: View {
    @Bindable var session: Session
    let close: () -> Void
    @State private var filter = ""
    @AppStorage("showDetails") private var showDetails = true
    @AppStorage("showEditor") private var showEditor = true
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var pendingAction: (action: TableAction, table: String)?
    enum SidebarTab { case items, diagram, history }
    enum RightTab { case row, table }
    @State private var rightTab = RightTab.row
    @State private var tableDraft = TableDraft()   // unsaved column / index edits of the panel's table
    /// The table the panel's Table tab shows: picked in the diagram, else the one being looked at.
    private var inspectedName: String? {
        switch session.kind {
        case .diagram: session.inspectedTable
        case .structure(let t): t
        case .data: session.table
        }
    }
    @State private var rowFilter = ""
    @FocusState private var filterFocused: Bool
    @State private var sidebarTab = SidebarTab.items
    @State private var pendingSchema = false
    @State private var pendingDatabase = false
    @State private var transferMode: TransferSheet.Mode?
    @State private var showProcesses = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            VStack(spacing: 0) {
                if !session.databases.isEmpty {
                    DatabaseSwitcher(session: session, newDatabase: { pendingDatabase = true })
                        .padding(.horizontal, 10).padding(.top, 8)
                        .zIndex(1) // the dropdown draws over the tabs and table list below
                }
                Picker("Sidebar", selection: $sidebarTab) {
                    Text("Items").tag(SidebarTab.items)
                    if session.conn.kind != .redis { Text("Diagram").tag(SidebarTab.diagram) }
                    Text("History").tag(SidebarTab.history)
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 10).padding(.top, 8)
                .onChange(of: sidebarTab) { _, tab in
                    // Diagram mode shows the current table's diagram; back to Items shows its data.
                    switch (tab, session.kind) {
                    // The whole database, with the table being looked at highlighted.
                    case (.diagram, .data): session.showDiagram("", highlight: session.table)
                    case (.diagram, .structure(let t)): session.showDiagram("", highlight: t)
                    case (.items, .diagram(let t)):
                        if let open = t.isEmpty ? session.diagram?.highlight : t { session.openTable(open) }
                    default: break
                    }
                }
                if sidebarTab == .history {
                    HistorySidebar(history: session.history, conn: session.conn) { sql in
                        if session.kind != .data { session.newTab() }
                        session.sql = sql
                        showEditor = true
                    }
                } else {
                TextField(session.conn.kind == .redis ? "Filter keys" : "Filter tables", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                SidebarList(items: session.visibleTables.filter { nameMatches(filter, $0) },
                            stripPrefix: session.schemaPrefix,
                            icon: session.conn.kind == .redis ? "key" : "tablecells",
                            expandable: session.conn.kind != .redis,
                            onSelect: { sidebarTab == .diagram ? session.showDiagram("", highlight: $0) : session.openTable($0) },
                            loadColumns: { session.columns($0, done: $1) },
                            actions: session.conn.kind == .redis ? [.openNewTab, .copyName] : TableAction.allCases.filter { $0 != .diagram },
                            onAction: { handle($0, $1) })
                    .overlay {
                        if session.visibleTables.isEmpty {
                            ContentUnavailableView(session.conn.kind == .redis ? "No keys" : "No tables",
                                                   systemImage: "tray",
                                                   description: Text(session.databases.isEmpty ? "" : "Pick another database or schema."))
                        }
                    }
                }
                if session.conn.kind != .redis {
                    SidebarFooter(session: session, newSchema: { pendingSchema = true }, newDatabase: { pendingDatabase = true },
                                  transfer: { transferMode = $0 })
                }
            }
            .sheet(isPresented: $pendingSchema) { NewSchemaSheet(session: session) { pendingSchema = false } }
            .sheet(isPresented: $pendingDatabase) { NewSchemaSheet(session: session, what: .database) { pendingDatabase = false } }
            .sheet(isPresented: $showProcesses) { ProcessListSheet(session: session) { showProcesses = false } }
            .sheet(isPresented: Binding(get: { transferMode != nil }, set: { if !$0 { transferMode = nil } })) {
                if let m = transferMode { TransferSheet(mode: m, session: session) { transferMode = nil } }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 260)
            .toolbar(removing: .sidebarToggle) // the toolbar's Sidebar button (with its keymap shortcut) does this
        } detail: {
          VStack(spacing: 0) {
            TabStrip(session: session)
            switch session.kind {
            case .structure(let t):
                StructureView(session: session, table: t)
            case .diagram:
                DiagramView(model: session.diagram, error: session.error,
                            onAction: { handle($0, $1) }, session: session,
                            onInspect: { name in session.inspectedTable = name; rightTab = .table; showDetails = true })
            case .data:
            VSplitView {
                if showEditor {
                    VStack(spacing: 0) {
                        SQLEditor(text: $session.sql, completer: SQLCompleter(session: session),
                                  cacheVersion: session.columnCache.count)
                        // Below the text, not over it: over the text view the pointer would be a text cursor.
                        if session.conn.kind != .redis {
                            HStack {
                                Spacer()
                                Button { formatQuery() } label: { Label("Format", systemImage: "text.alignleft").font(.callout) }
                                    .buttonStyle(.accessoryBarAction)
                                    .shortcut(.formatSQL)
                                    .help("Format SQL (\(Keymap.shared.display(.formatSQL)))")
                                    .disabled(session.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color(nsColor: .textBackgroundColor))
                        }
                    }
                    .frame(minHeight: 80, idealHeight: 160)
                }
                VStack(spacing: 0) {
                    if let e = session.error {
                        Text(e).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    ResultGrid(result: session.result, selection: $session.selectedRow, edits: session.edits,
                               editable: session.readOnlyReason == nil,
                               onEdit: { r, c, v in session.setEdit(row: r, column: c, value: v) },
                               filter: rowFilter, links: Set(session.links.keys),
                               onFollow: { r, c in session.follow(row: r, column: c) },
                               onDeleteRows: session.readOnlyReason == nil ? { session.deleteRows($0) } : nil,
                               onSelectRows: { session.selectedRows = $0 },
                               sortOrder: session.sortOrder, onSort: session.table == nil ? nil : { session.sort(by: $0) })
                    if session.editCount > 0 { SaveBar(session: session) }
                    SelectionBar(session: session)
                    HStack {
                        // Filters the rows already loaded (this page / result), without running a new query.
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(rowFilter.isEmpty ? .secondary : Color.accentColor)
                            TextField("Filter rows", text: $rowFilter).textFieldStyle(.plain).focused($filterFocused)
                                .onExitCommand { rowFilter = ""; filterFocused = false }
                            if !rowFilter.isEmpty {
                                Button { rowFilter = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                            }
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5)))
                        .frame(maxWidth: 260)
                        .help("Filter the loaded rows by any cell (\(Keymap.shared.display(.filterRows))). Esc clears.")
                        if !rowFilter.isEmpty {
                            let n = ResultGrid.matching(session.result, rowFilter)?.count ?? session.result.rows.count
                            Text("\(n) of \(session.result.rows.count) rows").monospacedDigit()
                        } else if !session.canPage || !session.result.message.isEmpty {
                            Text(session.result.message.isEmpty ? "\(session.result.rows.count) row(s)" : session.result.message)
                        }
                        Spacer()
                        if session.busy { ProgressView().controlSize(.small) }
                        if session.canPage {
                            let first = session.offset + 1, last = session.offset + session.result.rows.count
                            Text(last >= first ? "Rows \(first)–\(last)" : "No rows")
                                .monospacedDigit()
                            ControlGroup {
                                Button { session.page(-1) } label: { Image(systemName: "chevron.left").frame(width: 22) }
                                    .disabled(session.offset == 0 || session.busy)
                                    .help("Previous \(pageSize) rows")
                                Button { session.page(1) } label: { Image(systemName: "chevron.right").frame(width: 22) }
                                    .disabled(!session.hasNextPage || session.busy)
                                    .help("Next \(pageSize) rows")
                            }
                            .controlSize(.regular)
                            .fixedSize()
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 5)
                }
                .frame(minHeight: 150)
            }
            }
          }
            .sheet(isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })) {
                if let p = pendingAction {
                    TableActionSheet(action: p.action, table: p.table, session: session) { pendingAction = nil }
                }
            }
            .confirmationDialog(session.pendingConfirm?.title ?? "", isPresented: Binding(
                get: { session.pendingConfirm != nil }, set: { if !$0 { session.pendingConfirm = nil } }), presenting: session.pendingConfirm) { p in
                Button(p.button, role: .destructive) { session.pendingConfirm = nil; p.action() }
                Button("Cancel", role: .cancel) { session.pendingConfirm = nil }
            } message: { p in Text(p.details.joined(separator: "\n")) }
            .focusedSceneValue(\.newQueryTab) { session.newTab() }
            // History lives in the sidebar tab; its shortcut still toggles it (no toolbar button).
            .onChange(of: session.table) { rowFilter = "" } // another table: start unfiltered
            .background {
                Button("Filter Rows") { filterFocused = true }
                    .shortcut(.filterRows).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            }
            .background {
                Button("Query History") { withAnimation { columns = .all; sidebarTab = sidebarTab == .history ? .items : .history } }
                    .shortcut(.history).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            }
            .focusedSceneValue(\.switchDatabase, session.databases.isEmpty ? nil : {
                // The switcher lives in the sidebar: show it first, then open the picker.
                withAnimation { columns = .all }
                DispatchQueue.main.async { session.dbPicker = true }
            })
            .inspector(isPresented: $showDetails) {
                // Tabs like the left sidebar: the selected row, or the table's structure and indexes.
                VStack(spacing: 0) {
                    Picker("Panel", selection: $rightTab) {
                        Text("Row").tag(RightTab.row)
                        Text("Table").tag(RightTab.table)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                    if rightTab == .row {
                        RowDetails(result: session.result, row: session.selectedRow, readOnlyReason: session.readOnlyReason,
                                   edits: Binding(get: { session.selectedRow.flatMap { session.edits[$0] } ?? [:] },
                                                  set: { new in if let r = session.selectedRow { session.edits[r] = new.isEmpty ? nil : new } }))
                    } else if let t = inspectedName {
                        DiagramTableInfo(name: t, session: session, load: { t in try? await session.onQueue { try $0.structure(t) } },
                                         draft: $tableDraft) { handle($0, t) }
                            .id(t)
                    } else {
                        ContentUnavailableView("No table", systemImage: "tablecells",
                                               description: Text("Open a table, or double-click one in the diagram."))
                    }
                }
                .onChange(of: inspectedName) { _, t in if let t, t != tableDraft.table { tableDraft = TableDraft(table: t) } }
                .inspectorColumnWidth(min: 260, ideal: 380, max: 700)
            }
        }
        // Window-level toolbar: placement no longer depends on which split-view columns are visible.
        .toolbar {
            ToolbarItem(placement: .principal) { ConnectionBar(session: session) }
        }
        .toolbar {
          // Same position whether or not the sidebar is visible (window-level, not per split column).
          ToolbarItemGroup(placement: .automatic) {
            Spacer() // flexible space in a macOS toolbar: pushes the actions to the trailing edge
            if session.busy && session.conn.kind != .redis && session.conn.kind != .mysql {
                Button { session.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
                    .shortcut(.stop)
                    .help("Stop query (\(Keymap.shared.display(.stop)))")
            } else {
                Button { session.run() } label: { Label("Run", systemImage: "play.fill") }
                    .shortcut(.run)
                    .help("Run query (\(Keymap.shared.display(.run)))")
                    .disabled(session.busy || session.kind != .data || session.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button { withAnimation { showEditor.toggle() } } label: { Label("SQL Editor", systemImage: "rectangle.topthird.inset.filled") }
                .shortcut(.toggleEditor)
                .help("Show/hide SQL editor (\(Keymap.shared.display(.toggleEditor)))")
            if session.conn.kind != .sqlite {
                Button { showProcesses = true } label: { Label("Processes", systemImage: "person.2") }
                    .shortcut(.processes)
                    .help("Server processes: see and kill client connections (\(Keymap.shared.display(.processes)))")
            }
            Button { close() } label: { Label("Disconnect", systemImage: "eject") }
                .help("Disconnect")
            Button { withAnimation { columns = columns == .detailOnly ? .all : .detailOnly } } label: {
                Label("Sidebar", systemImage: "sidebar.left")
            }
            .shortcut(.toggleSidebar)
            .help("Show/hide tables (\(Keymap.shared.display(.toggleSidebar)))")
            Button { showDetails.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                .shortcut(.toggleDetails)
                .help("Show/hide row details (\(Keymap.shared.display(.toggleDetails)))")
          }
        }
        .modifier(HideToolbarTitle()) // the ConnectionBar says it all; the window title still names the tab
    }
}

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

struct HideToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.toolbar(removing: .title) } else { content }
    }
}

extension WorkspaceView {
    /// In the focused editor it's one undoable edit; otherwise the query text is replaced directly.
    func formatQuery() {
        showEditor = true
        if !NSApp.sendAction(#selector(SQLEditor.TextView.formatSQL(_:)), to: nil, from: nil) {
            session.sql = SQLFormatter.format(session.sql)
        }
    }

    func handle(_ action: TableAction, _ table: String) {
        switch action {
        case .openNewTab: session.openTable(table, inNewTab: true)
        case .structure: session.openStructure(table)
        case .diagram: session.showDiagram(table)
        case .copyName:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(table, forType: .string)
        case .clone, .truncate, .delete: pendingAction = (action, table)
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

/// Toolbar button + searchable popover. Replaces a SwiftUI Picker whose 107-item menu was
/// rebuilt on every state change (~250 ms main-thread stall per database switch, measured).
/// The list is only built while the popover is open.
struct DatabaseSwitcher: View {
    @Bindable var session: Session
    var newDatabase: () -> Void = {}
    @State private var buttonHeight: CGFloat = 28
    var body: some View {
        Button { session.dbPicker.toggle() } label: {
            HStack(spacing: 6) {
                if session.switchingTo != nil { ProgressView().controlSize(.mini) } else { Image(systemName: "cylinder.split.1x2") }
                Text(session.switchingTo ?? session.conn.database).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Switch database (\(Keymap.shared.display(.switchDatabase)))")
        .background(GeometryReader { g in Color.clear.onAppear { buttonHeight = g.size.height } })
        // A dropdown hanging from the button, exactly as wide as it (not a popover).
        .overlay(alignment: .top) {
            if session.dbPicker { // read here only: a binding from WorkspaceView re-ran its whole body
                DatabaseDropdown(session: session, newDatabase: newDatabase) { session.dbPicker = false }
                    .offset(y: buttonHeight + 4)
            }
        }
    }
}

/// Shown under the grid whenever there are unsaved edits, whether or not Details is open.
/// Several rows selected: how many, and a button to delete them. Its own view, so selecting
/// rows only redraws this bar.
struct SelectionBar: View {
    let session: Session
    var body: some View {
        let n = session.selectedRows.count
        if n > 1, session.readOnlyReason == nil, session.editCount == 0 {
            HStack {
                Text("\(n) rows selected")
                Text("⌘-click or ⇧-click to change").foregroundStyle(.secondary).font(.callout)
                Spacer()
                Button("Delete \(n) Rows…", role: .destructive) { session.deleteRows(session.selectedRows) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

struct SaveBar: View {
    @Bindable var session: Session
    var body: some View {
        HStack {
            Circle().fill(.orange).frame(width: 7, height: 7)
            Text("\(session.editCount) unsaved change\(session.editCount == 1 ? "" : "s")")
            Spacer()
            Button("Discard") { session.edits = [:]; session.error = nil }
                .disabled(session.saving)
            Button { session.saveAll() } label: {
                if session.saving { ProgressView().controlSize(.small) } else { Text("Save") }
            }
            .shortcut(.save)
            .buttonStyle(.borderedProminent)
            .disabled(session.saving)
            .help("Save changes (⌘S)")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
