import SwiftUI
// Grid perf check: Kueri --bench (each scroll page should stay well under 16 ms)
@MainActor func bench() {
    let r = QueryResult(columns: (0..<8).map { "col\($0)" }, rows: (0..<10_000).map { i in (0..<8).map { "v\(i)-\($0)-abcdef0123456789" } })
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    func t(_ label: String, _ f: () -> Void) { let s = Date(); f(); print(label, String(format: "%.0f ms", Date().timeIntervalSince(s) * 1000)) }
    let host = NSHostingView(rootView: ResultGrid(result: QueryResult()))
    win.contentView = host
    win.orderFront(nil)
    t("empty layout") { host.layoutSubtreeIfNeeded(); host.display() }
    t("set 10k rows") { host.rootView = ResultGrid(result: r); host.layoutSubtreeIfNeeded(); host.display() }
    t("same rows again (parent re-render, e.g. typing)") { host.rootView = ResultGrid(result: r); host.layoutSubtreeIfNeeded(); host.display() }
    func scroll(_ label: String) {
        func find(_ v: NSView) -> NSScrollView? { (v as? NSScrollView) ?? v.subviews.lazy.compactMap(find).first }
        guard let sv = find(host) else { print("no scrollview"); return }
        t(label) { for i in 1...60 { sv.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(i) * 400)); sv.reflectScrolledClipView(sv.contentView); host.layoutSubtreeIfNeeded(); host.display() } }
    }
    scroll("scroll 60 pages, 8 cols")
    let wide = QueryResult(columns: (0..<40).map { "column_\($0)" }, rows: (0..<10_000).map { i in (0..<40).map { "v\(i)-\($0)-abcdef" } })
    t("set 10k rows x 40 cols") { host.rootView = ResultGrid(result: wide); host.layoutSubtreeIfNeeded(); host.display() }
    scroll("scroll 60 pages, 40 cols")
    let people = QueryResult(columns: (0..<285).map { "column_\($0)" }, rows: (0..<300).map { i in (0..<285).map { "v\(i)-\($0)" } })
    t("set 300 rows x 285 cols") { host.rootView = ResultGrid(result: people); host.layoutSubtreeIfNeeded(); host.display() }
    scroll("scroll 60 pages, 285 cols")
    t("10x re-render") { for _ in 0..<10 { host.rootView = ResultGrid(result: r); host.layoutSubtreeIfNeeded(); host.display() } }

    // Behaviour checks (print FAIL instead of assert: bench runs in release)
    func check(_ name: String, _ ok: Bool) { print(ok ? "ok  " : "FAIL", name) }
    var got: (Int, Int, String?)?
    let small = QueryResult(columns: ["id", "v"], rows: [["1", "a"], ["2", nil]])
    let editHost = NSHostingView(rootView: ResultGrid(result: small, editable: true, onEdit: { got = ($0, $1, $2) }))
    win.contentView = editHost; editHost.layoutSubtreeIfNeeded()
    func findTable(_ v: NSView) -> NSTableView? { (v as? NSTableView) ?? v.subviews.lazy.compactMap(findTable).first }
    if let tv = findTable(editHost), let ds = tv.dataSource {
        let col = tv.tableColumns[1]
        // Real editing, not just the delegate answer: cell must be editable and an editor must open.
        tv.editColumn(1, row: 0, with: nil, select: true)
        check("cell editor opens", tv.editedRow == 0 && tv.currentEditor() != nil)
        tv.abortEditing()
        check("double-click wired to editing", tv.doubleAction != nil && tv.target is ResultGrid.Coordinator)
        ds.tableView?(tv, setObjectValue: "a", for: col, row: 0)
        check("unchanged commit ignored", got == nil)
        ds.tableView?(tv, setObjectValue: "NULL", for: col, row: 1)
        check("unchanged NULL commit ignored", got == nil)
        ds.tableView?(tv, setObjectValue: "b", for: col, row: 0)
        check("edit reported", got?.0 == 0 && got?.1 == 1 && got?.2 == "b")
        editHost.rootView = ResultGrid(result: small, edits: [0: [1: "b"]], editable: true)
        editHost.layoutSubtreeIfNeeded()
        let shown = ds.tableView?(tv, objectValueFor: col, row: 0) as? NSAttributedString
        check("edited cell shows pending value", shown?.string == "b")
    } else { check("grid found", false) }

    // Tabs: a second window joins the first one's tab group
    let w1 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let w2 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    w1.contentView = NSHostingView(rootView: TabJoiner()); w1.orderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    w2.contentView = NSHostingView(rootView: TabJoiner()); w2.orderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check("second window joins as tab", w1.tabbedWindows?.contains(w2) == true)

    // Select-all on focus: focus a field the way a click does and inspect the field editor's selection.
    struct FocusProbe: View {
        @State var text = "New connection"
        var body: some View { TextField("Name", text: $text).selectAllOnFocus().frame(width: 200).padding() }
    }
    let fw = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
    let fh = NSHostingView(rootView: FocusProbe())
    fw.contentView = fh; fw.makeKeyAndOrderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    func findField(_ v: NSView) -> NSTextField? { (v as? NSTextField) ?? v.subviews.lazy.compactMap(findField).first }
    if let f = findField(fh) {
        // Mimic a real click: focus arrives on mouse-down, AppKit then tracks the mouse in
        // .eventTracking mode and places the caret on mouse-up, after which .default mode resumes.
        fw.makeFirstResponder(f)
        RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.2))
        RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.2))
        f.currentEditor()?.selectedRange = NSRange(location: 3, length: 0) // caret where the user clicked
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let ed = f.currentEditor()
        check("click selects all text (after mouse-up)", ed?.selectedRange == NSRange(location: 0, length: "New connection".utf16.count))
    } else { check("text field found", false) }

    // Rename from the connections list: programmatic focus must land in the Name field, all selected.
    struct RenameProbe: View {
        @State var text = "New connection"
        @FocusState var renaming: Bool
        var body: some View {
            VStack {
                TextField("Other", text: .constant("x"))
                TextField("Name", text: $text).selectAllOnFocus().focused($renaming)
                Button("Rename") { renaming = true }
            }.frame(width: 220).padding()
        }
    }
    let rw = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
    let rh = NSHostingView(rootView: RenameProbe())
    rw.contentView = rh; rw.makeKeyAndOrderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    func allFields(_ v: NSView) -> [NSTextField] { ((v as? NSTextField).map { [$0] } ?? []) + v.subviews.flatMap(allFields) }
    func findButton(_ v: NSView) -> NSButton? { (v as? NSButton) ?? v.subviews.lazy.compactMap(findButton).first }
    if let name = allFields(rh).first(where: { $0.placeholderString == "Name" }), let b = findButton(rh) {
        b.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        check("Rename focuses Name with all text selected", name.currentEditor()?.selectedRange == NSRange(location: 0, length: 14))
    } else { check("rename probe views found", false) }

    // Rename popover from the toolbar title: opens with the name selected, Rename passes the new name.
    struct TitleProbe: View {
        let session: Session
        @State var editing = false
        let onRename: (String) -> Void
        var body: some View {
            VStack {
                ConnectionTitle(session: session, rename: onRename, editing: $editing)
                Button("open-rename") { editing = true } // stands in for File › Rename Connection…
            }.padding(30)
        }
    }
    var renamed: String?
    let sess = Session.preview(Conn(name: "New connection", kind: .sqlite, path: ":memory:"))
    let tw = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    let th = NSHostingView(rootView: TitleProbe(session: sess, onRename: { renamed = $0 }))
    tw.contentView = th; tw.makeKeyAndOrderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
    buttons(th).first?.performClick(nil) // the only NSButton: "open-rename" (the title itself is .plain)
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    if let field = allFields(th).first(where: { $0.placeholderString == "Connection name" }) {
        check("rename field appears with current name", field.stringValue == "New connection")
        check("rename field has the name selected", field.currentEditor()?.selectedRange == NSRange(location: 0, length: 14))
        // Type over the selection and press Return, through the field editor like a keyboard would.
        if let ed = field.currentEditor() as? NSTextView {
            ed.insertText("staging db", replacementRange: ed.selectedRange())
            ed.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check("typing + Return renames", renamed == "staging db")
    } else { check("rename field appears", false) }

    // Table tabs, structure, diagram and table actions against a real (in-memory SQLite) session.
    let ts = Session.preview(Conn(name: "mem", kind: .sqlite, path: ":memory:"))
    func waitIdle() { let end = Date().addingTimeInterval(5); repeat { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } while ts.busy && Date() < end; RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    func awaitTask(_ f: @escaping () async throws -> Void) -> Error? {
        var done = false, err: Error?
        Task { do { try await f() } catch { err = error }; done = true }
        let end = Date().addingTimeInterval(5); while !done && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return err
    }
    _ = awaitTask { try await ts.execute("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO users VALUES (1,'ana'),(2,'budi'); CREATE TABLE upload_logs(id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id), status TEXT); INSERT INTO upload_logs VALUES (1,1,'ok')") }
    check("execute refreshes table list", ts.tables == ["upload_logs", "users"])
    ts.openTable("users"); waitIdle()
    let usersTab = ts.activeTab
    check("sidebar click opens table in current tab", ts.result.columns == ["id", "name"] && ts.tabs.count == 1)
    ts.openTable("upload_logs", inNewTab: true); waitIdle()
    check("open in new tab adds a tab", ts.tabs.count == 2 && ts.result.columns == ["id", "user_id", "status"])
    ts.selectTab(usersTab)
    check("switching back restores that tab's result", ts.result.columns == ["id", "name"] && ts.table == "users")
    // Result must land in the tab that ran it, even if the user switched away first.
    ts.sql = "SELECT 42 AS answer"; ts.run()
    let other = ts.tabs.first { $0.id != usersTab }!.id
    ts.selectTab(other)
    waitIdle()
    check("late result goes to its own tab", ts.result.columns == ["id", "user_id", "status"]
          && ts.tabList.first { $0.id == usersTab }?.result.columns == ["answer"])
    ts.openStructure("upload_logs")
    let end1 = Date().addingTimeInterval(5); while ts.result.rows.isEmpty && Date() < end1 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check("structure tab lists columns in table order", ts.kind == .structure("upload_logs") && ts.result.rows.map { $0[1] ?? "" } == ["id", "user_id", "status"] && ts.primaryKey == ["id"])
    ts.showDiagram("users")
    let end2 = Date().addingTimeInterval(5); while ts.diagram == nil && Date() < end2 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check("diagram includes related tables and the FK link", Set(ts.diagram?.tables.map(\.name) ?? []) == ["users", "upload_logs"]
          && ts.diagram?.links == [ForeignKey(fromTable: "upload_logs", fromColumn: "user_id", toTable: "users", toColumn: "id")])
    check("four tabs open", ts.tabs.count == 4)
    ts.closeTab(ts.activeTab)
    check("closing a tab activates a neighbour", ts.tabs.count == 3 && ts.kind == .structure("upload_logs"))
    check("clone copies table and data", awaitTask { try await ts.execute(ts.cloneSQL("users", to: "users_copy", withData: true)) } == nil && ts.tables.contains("users_copy"))
    _ = awaitTask { try await ts.execute(ts.truncateSQL("users_copy")) }
    ts.openTable("users_copy"); waitIdle()
    check("truncate empties the table", ts.tables.contains("users_copy") && ts.result.rows.isEmpty && ts.result.columns == ["id", "name"])
    _ = awaitTask { try await ts.execute(ts.dropSQL("users_copy")) }
    check("delete drops the table", !ts.tables.contains("users_copy"))
    // Context menu is wired on the sidebar outline.
    let sideHost = NSHostingView(rootView: SidebarList(items: ["users"], icon: "tablecells", onSelect: { _ in }, actions: TableAction.allCases))
    let sw = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    sw.contentView = sideHost; sw.orderFront(nil); RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    func findOutline(_ v: NSView) -> NSOutlineView? { (v as? NSOutlineView) ?? v.subviews.lazy.compactMap(findOutline).first }
    check("sidebar has a right-click menu", findOutline(sideHost)?.menu?.delegate is SidebarList.Coordinator)

    // Autocomplete: type through the real NSTextView, accept with Tab.
    let es = Session.preview(Conn(name: "mem", kind: .sqlite, path: ":memory:"))
    _ = awaitTask { try await es.execute("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT, nik TEXT)") }
    var sqlText = ""
    let edHost = NSHostingView(rootView: SQLEditor(text: Binding(get: { sqlText }, set: { sqlText = $0 }), completer: SQLCompleter(session: es)))
    let ew = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    ew.contentView = edHost; ew.orderFront(nil); RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    func findTV(_ v: NSView) -> SQLEditor.TextView? { (v as? SQLEditor.TextView) ?? v.subviews.lazy.compactMap(findTV).first }
    if let tv = findTV(edHost) {
        ew.makeFirstResponder(tv)
        func type(_ t: String) { tv.insertText(t, replacementRange: tv.selectedRange()); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        func tab() { tv.doCommand(by: #selector(NSResponder.insertTab(_:))); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        type("SEL"); check("ghost suggests keyword", tv.ghost == "ECT"); tab()
        check("Tab completes keyword", tv.string == "SELECT" && sqlText == "SELECT")
        tv.string = ""; type("select * fr"); tab()
        check("keywords complete in capitals", tv.string == "select * FROM")
        tv.string = ""; type("SELECT * FROM us"); tab()
        check("table name after FROM", tv.string == "SELECT * FROM users")
        type(" WHERE na")
        let end3 = Date().addingTimeInterval(3); while es.columnCache["users"] == nil && Date() < end3 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        type("m"); tab()
        check("column of referenced table", tv.string == "SELECT * FROM users WHERE name")
        tv.string = ""; type("SELECT u.ni FROM users u"); tv.setSelectedRange(NSRange(location: 11, length: 0)); type("")
        tv.string = "SELECT u.n FROM users u"; tv.setSelectedRange(NSRange(location: 10, length: 0)); type("i"); tab()
        check("alias.column", tv.string == "SELECT u.nik FROM users u")
        tv.string = ""; type("select * from users where users.")
        check("after table. the first column is suggested", tv.ghost == "id"); tab()
        check("Tab inserts it", tv.string == "select * from users where users.id")
        tv.string = "select * from users where users."; tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        var idx = 0
        let listed = tv.completions(forPartialWordRange: NSRange(location: tv.string.utf16.count, length: 0), indexOfSelectedItem: &idx)
        check("⌥Esc lists that table's columns", listed == ["id", "name", "nik"])
        tv.string = ""; type("SEL"); tv.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        check("Esc dismisses suggestion", tv.ghost == nil)
        tv.string = "SELECT"; tv.setSelectedRange(NSRange(location: 2, length: 0)); type("x")
        check("no suggestion mid-word", tv.ghost == nil)
        tv.string = ""; type("x"); tab()
        check("Tab without suggestion inserts a tab", tv.string == "x\t")
    } else { check("editor found", false) }

    // Tab bar: AppKit buttons, clicked through their real target/action path.
    let tb = Session.preview(Conn(name: "mem", kind: .sqlite, path: ":memory:"))
    tb.sql = "SELECT 1"; tb.newTab(); tb.sql = "SELECT 2"
    let tbFirst = tb.tabs[0].id, tbSecond = tb.activeTab
    let tbHost = NSHostingView(rootView: TabStrip(session: tb).frame(width: 600))
    let tbw = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
    tbw.contentView = tbHost; tbw.orderFront(nil); RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    func tbButtons(_ sel: String) -> [NSButton] {
        func all(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(all) }
        return all(tbHost).filter { $0.action.map(NSStringFromSelector) == sel }
    }
    tbButtons("select:").first?.performClick(nil); RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    check("tab click switches tab", tb.activeTab == tbFirst && tb.sql == "SELECT 1")
    check("tab buttons have tooltips", tbButtons("select:").allSatisfy { $0.toolTip == "Query" } && tbButtons("close:").allSatisfy { $0.toolTip == "Close tab" })
    tbButtons("select:").last?.performClick(nil); RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    check("clicking back restores the other tab", tb.activeTab == tbSecond && tb.sql == "SELECT 2")
    tbButtons("add:").first?.performClick(nil); RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    check("+ adds a tab", tb.tabs.count == 3)
    tbButtons("close:").first?.performClick(nil); RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    check("x closes that tab", tb.tabs.count == 2 && !tb.tabs.contains { $0.id == tbFirst })

    func waitIdleOn(_ x: Session) { let end = Date().addingTimeInterval(5); repeat { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } while x.busy && Date() < end; RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    // Query history: user-run queries are recorded (with errors), sidebar browsing isn't, re-runs dedupe.
    let hs = Session.preview(Conn(name: "mem", kind: .sqlite, path: ":memory:"))
    _ = awaitTask { try await hs.execute("CREATE TABLE h(id INTEGER PRIMARY KEY)") }
    hs.sql = "SELECT 1 AS one"; hs.run(); waitIdleOn(hs)
    hs.sql = "SELEC broken"; hs.run(); waitIdleOn(hs)
    hs.openTable("h"); waitIdleOn(hs)
    hs.sql = "SELECT 1 AS one"; hs.run(); waitIdleOn(hs)
    check("history records user queries newest first", hs.history.entries.map(\.sql) == ["SELECT 1 AS one", "SELEC broken"])
    check("history keeps the error", hs.history.entries.last?.error?.isEmpty == false && hs.history.entries.first?.rows == 1)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check("history persists to disk", QueryHistory(url: hs.history.url).entries.count == 2)
    // Per database: entries from another connection or database are not offered here.
    hs.history.add(HistoryEntry(sql: "SELECT * FROM other_db_table", connectionID: UUID(), connection: "staging", database: "postgres",
                                date: Date(), milliseconds: 1, rows: 0, error: nil))
    let panelEntries = hs.history.entries.filter { e in e.database == hs.conn.database && (e.connectionID.map { $0 == hs.conn.id } ?? (e.connection == hs.conn.name)) }
    check("history is scoped to this connection + database", panelEntries.map(\.sql) == ["SELECT 1 AS one", "SELEC broken"])
    hs.history.clear(hs.conn)
    check("clear only removes this database's history", hs.history.entries.map(\.sql) == ["SELECT * FROM other_db_table"])
    // Toolbar tooltips on the bridged NSToolbar, as in the real window.
    let ttHC = NSHostingController(rootView: WorkspaceView(session: Session.preview(Conn(name: "mem", kind: .sqlite, path: ":memory:")), close: {}))
    ttHC.sceneBridgingOptions = [.toolbars, .title]
    let ttw = NSWindow(contentViewController: ttHC)
    ttw.setContentSize(NSSize(width: 1100, height: 400)); ttw.orderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    let labelled = ttw.toolbar?.items.filter { !$0.label.isEmpty } ?? []
    check("every toolbar button has a tooltip", !labelled.isEmpty && labelled.allSatisfy { ($0.toolTip ?? "").isEmpty == false })
    check("Run tooltip names its shortcut", labelled.first { $0.label == "Run" }?.toolTip == "Run query (⌘↩)")

    // Production mode: a risky query waits for confirmation; a safe one runs straight away.
    var prodConn = Conn(name: "prod", kind: .sqlite, path: ":memory:"); prodConn.isProduction = true
    let ps = Session.preview(prodConn)
    _ = awaitTask { try await ps.execute("CREATE TABLE t(id INTEGER PRIMARY KEY); INSERT INTO t VALUES (1),(2)") }
    ps.sql = "DELETE FROM t"; ps.run(); waitIdleOn(ps)
    check("production: risky query asks first", ps.pendingConfirm != nil)
    ps.sql = "SELECT count(*) AS n FROM t"; ps.pendingConfirm = nil; ps.run(); waitIdleOn(ps)
    check("production: nothing deleted before confirming", ps.result.rows.first?.first == "2")
    ps.sql = "DELETE FROM t"; ps.run(); waitIdleOn(ps)
    ps.pendingConfirm?.action(); waitIdleOn(ps)
    ps.sql = "SELECT count(*) AS n FROM t"; ps.run(); waitIdleOn(ps)
    check("production: confirmed query runs", ps.result.rows.first?.first == "0")
}
