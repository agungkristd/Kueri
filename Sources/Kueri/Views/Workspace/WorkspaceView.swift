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
    @State private var pendingOwner = false
    @State private var transferMode: TransferSheet.Mode?
    @State private var showProcesses = false
    @Environment(\.undoManager) private var undoManager // the window's: Edit › Undo and ⌘Z drive it

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            VStack(spacing: 0) {
                if !session.databases.isEmpty {
                    DatabaseSwitcher(session: session, newDatabase: { pendingDatabase = true }, changeOwner: { pendingOwner = true })
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
                SidebarSearchField(prompt: session.conn.kind == .redis ? "Filter keys" : "Filter tables", text: $filter)
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
                                  changeOwner: { pendingOwner = true },
                                  transfer: { transferMode = $0 })
                }
            }
            .sheet(isPresented: $pendingSchema) { NewSchemaSheet(session: session) { pendingSchema = false } }
            .sheet(isPresented: $pendingDatabase) { NewSchemaSheet(session: session, what: .database) { pendingDatabase = false } }
            .sheet(isPresented: $pendingOwner) { DatabaseOwnerSheet(session: session) { pendingOwner = false } }
            .sheet(isPresented: $showProcesses) { ProcessListSheet(session: session) { showProcesses = false } }
            .sheet(isPresented: Binding(get: { transferMode != nil }, set: { if !$0 { transferMode = nil } })) {
                if let m = transferMode { TransferSheet(mode: m, session: session) { transferMode = nil } }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 260)
            // Solid, darker than the content: the default sidebar material is lighter and changes
            // tone whenever the window gains or loses focus (asked for).
            .background(Color(nsColor: .textBackgroundColor).ignoresSafeArea())
            .toolbar(removing: .sidebarToggle) // the toolbar's Sidebar button (with its keymap shortcut) does this
        } detail: {
          VStack(spacing: 0) {
            TabStrip(session: session)
            ConnectionLostBar(session: session)
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
                            .background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                    .frame(minHeight: 80, idealHeight: 160)
                }
                VStack(spacing: 0) {
                    if let e = session.error, !session.connectionLost { // the banner above shows that one
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
                                                  set: { new in if let r = session.selectedRow { session.setRowEdits(r, new) } }),
                                   enumValues: session.enumValues)
                    } else if let t = inspectedName {
                        DiagramTableInfo(name: t, session: session, load: { t in try? await session.onQueue { try $0.structure(t) } },
                                         draft: $tableDraft) { handle($0, t) }
                            .id(t)
                    } else {
                        ContentUnavailableView("No table", systemImage: "tablecells",
                                               description: Text("Open a table, or double-click one in the diagram."))
                            .frame(maxHeight: .infinity) // fills the panel, so the tabs stay at the top
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .textBackgroundColor).ignoresSafeArea()) // like the sidebar
                .onChange(of: inspectedName) { _, t in if let t, t != tableDraft.table { tableDraft = TableDraft(table: t) } }
                .inspectorColumnWidth(min: 260, ideal: 380, max: 700)
            }
        }
        .onAppear { session.undoManager = undoManager }
        .onChange(of: undoManager.map(ObjectIdentifier.init)) { session.undoManager = undoManager }
        // Window-level toolbar: placement no longer depends on which split-view columns are visible.
        .toolbar {
            ToolbarItem(placement: .navigation) { ConnectionBar(session: session) } // leading, next to the window controls
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
