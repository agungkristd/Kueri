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
        if let ed = tv.currentEditor() as? NSTextView {
            ed.insertText("zz", replacementRange: ed.selectedRange())
            ed.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        }
        check("Esc leaves the cell editor without a change", tv.editedRow == -1 && got == nil)
        tv.abortEditing()
        // Into a cell and out again (click elsewhere / Return) without typing: no edit.
        for c in [0, 1] {
            let c2 = tv.delegate as? ResultGrid.Coordinator
            c2?.markStarted(0, in: tv) // as a double-click does
            tv.editColumn(c, row: 0, with: nil, select: true)
            win.makeFirstResponder(tv)
            check("leaving an untouched cell (column \(c)) records no edit and drops the tint", got == nil && c2?.inEditState(0) == false)
            got = nil
        }
        check("double-click wired to editing", tv.doubleAction != nil && tv.target is ResultGrid.Coordinator)
        ds.tableView?(tv, setObjectValue: "a", for: col, row: 0)
        check("unchanged commit ignored", got == nil)
        ds.tableView?(tv, setObjectValue: "NULL", for: col, row: 1)
        check("unchanged NULL commit ignored", got == nil)
        ds.tableView?(tv, setObjectValue: "b", for: col, row: 0)
        check("edit reported", got?.0 == 0 && got?.1 == 1 && got?.2 == "b")
        // Editor opened on "a", then Details set the cell NULL; closing the untouched editor must not bring "a" back.
        got = nil
        if let c2 = tv.delegate as? ResultGrid.Coordinator {
            _ = c2.tableView(tv, shouldEdit: col, row: 0)
            c2.edits = [0: [1: nil]]
            ds.tableView?(tv, setObjectValue: "a", for: col, row: 0)
            check("stale editor text doesn't overwrite a NULL set in Details", got == nil)
            ds.tableView?(tv, setObjectValue: "typed", for: col, row: 0)
            check("typed text in that editor still counts", got?.2 == "typed")
            c2.edits = [:]; c2.openedWith = nil; got = nil
        }
        // ⌘Z: Edit › Undo drives the window's undo manager, so the hosted view must be handed that same one.
        final class Seen { var um: UndoManager? }
        struct Probe: View { let seen: Seen; @Environment(\.undoManager) var um; var body: some View { Color.clear.onAppear { seen.um = um } } }
        let seen = Seen(), uw = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        uw.contentView = NSHostingView(rootView: Probe(seen: seen)); uw.orderFrontRegardless(); RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check("hosted view sees the window's undo manager", seen.um != nil && seen.um === uw.undoManager)
        check("ownership list SQL embeds the role as a literal",
              Session.transferOwnershipListSQL(owner: "o'r").contains("quote_ident('o''r')") && !Session.transferOwnershipListSQL(owner: "x").contains("'x\""))
        check("owner SQL quotes both identifiers",
              Session.alterOwnerSQL(database: "my\"db", owner: "sai_app") == "ALTER DATABASE \"my\"\"db\" OWNER TO \"sai_app\"")
        // A query stuck on a dead connection holds `busy`; Reconnect must release it or every click is dropped.
        let rs = Session.preview(Conn(name: "mem", kind: .sqlite, path: ":memory:"))
        rs.busy = true; rs.error = "server closed the connection unexpectedly"
        rs.reconnect()
        for _ in 0..<40 where rs.reconnecting || rs.busy { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check("Reconnect clears busy and the error", !rs.busy && rs.error == nil && !rs.connectionLost)
        let us = Session.preview(Conn(name: "mem", kind: .sqlite, path: ":memory:"))
        us.result = small; us.undoManager = uw.undoManager
        // Edits in one event share an undo group (as typing does); separate events undo one by one.
        us.setEdit(row: 0, column: 1, value: .some("b")); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        us.setEdit(row: 0, column: 1, value: .some("c")); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        uw.undoManager?.undo(); check("⌘Z takes back the last edit", us.edits[0]?[1] == "b")
        uw.undoManager?.undo(); check("⌘Z again leaves no edits", us.edits.isEmpty)
        uw.undoManager?.redo(); check("⌘⇧Z redoes it", us.edits[0]?[1] == "b")
        us.discardEdits(); check("Discard clears the undo history too", us.edits.isEmpty && uw.undoManager?.canUndo == false)
        uw.close()
        editHost.rootView = ResultGrid(result: small, edits: [0: [1: "b"]], editable: true)
        editHost.layoutSubtreeIfNeeded()
        let shown = ds.tableView?(tv, objectValueFor: col, row: 0) as? NSAttributedString
        check("edited cell shows pending value", shown?.string == "b")
        check("an edited row stays tinted", (tv.delegate as? ResultGrid.Coordinator)?.inEditState(0) == true
              && (tv.delegate as? ResultGrid.Coordinator)?.inEditState(1) == false)
    } else { check("grid found", false) }

    // Several rows: ⌘/⇧-click selection is reported, and Delete deletes all of it (filtered rows map back).
    var picked: [Int] = [], deleted: [Int] = []
    let five = QueryResult(columns: ["id"], rows: (0..<5).map { [String($0)] })
    let multiHost = NSHostingView(rootView: ResultGrid(result: five, filter: "", onDeleteRows: { deleted = $0 }, onSelectRows: { picked = $0 }))
    win.contentView = multiHost; multiHost.layoutSubtreeIfNeeded()
    if let tv = findTable(multiHost) as? GridTable {
        tv.selectRowIndexes([1, 3], byExtendingSelection: false)
        // The report is deferred to the main queue, which can't run inside bench; check what it sends.
        (tv.delegate as? ResultGrid.Coordinator)?.onSelectRows(tv.selectedRowIndexes.map { $0 })
        check("multi-row selection reported", picked == [1, 3])
        tv.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                          context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!)
        check("Delete key deletes every selected row", deleted == [1, 3])
    } else { check("multi grid found", false) }

    // Tabs: a second window joins the first one's tab group
    let w1 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let w2 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    w1.contentView = NSHostingView(rootView: TabJoiner(workspace: true)); w1.orderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    w2.contentView = NSHostingView(rootView: TabJoiner(workspace: true)); w2.orderFront(nil)
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
    // Zoomed out, the diagram is smaller than the view: a table can still be dragged to its edge.
    if let model = ts.diagram {
        let dw = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let dh = NSHostingView(rootView: DiagramView(model: model))
        dw.contentView = dh; dw.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func canvasIn(_ v: NSView) -> DiagramCanvas? { (v as? DiagramCanvas) ?? v.subviews.lazy.compactMap(canvasIn).first }
        if let canvas = canvasIn(dh), let sv = canvas.enclosingScrollView {
            canvas.setZoom(0.2); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            func event(_ type: NSEvent.EventType, _ w: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: w, modifierFlags: [], timestamp: 0, windowNumber: dw.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let grab = canvas.convert(CGPoint(x: 430, y: 50), to: nil)   // header of the focused table
            let edge = sv.convert(CGPoint(x: 8, y: sv.bounds.midY), to: nil)
            let emptyBefore = canvas.menu(for: event(.rightMouseDown, edge)) == nil
            canvas.mouseDown(with: event(.leftMouseDown, grab))
            canvas.mouseDragged(with: event(.leftMouseDragged, edge))
            canvas.mouseUp(with: event(.leftMouseUp, edge))
            check("zoomed-out diagram: table drags to the view's edge", emptyBefore && canvas.menu(for: event(.rightMouseDown, edge)) != nil)
        } else { check("diagram canvas found", false) }
        dw.close()
    }
    // Details: enum columns and booleans get a picker, other columns a text field.
    let picks = RowDetails(result: QueryResult(columns: ["kind", "active", "name"], types: ["kind_t", "bool", "text"], rows: [["a", "t", "x"]]),
                           row: 0, edits: .constant([:]), enumValues: ["kind": ["a", "b"]])
    check("Details offers enum and boolean values", picks.choices(0) == ["a", "b"] && picks.choices(1) == ["t", "f"]
          && picks.choices(2) == nil && picks.choiceLabel("t", 1) == "TRUE")
    // No pop-up button per field: SwiftUI kept re-updating those without end (full-CPU freeze).
    do {
        let pw = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let ph = NSHostingView(rootView: RowDetails(result: QueryResult(columns: ["kind", "active", "doc"], types: ["kind_t", "bool", "jsonb"], rows: [["a", "t", #"{"x": [1, 2]}"#]]),
                                                    row: 0, edits: .constant([:]), enumValues: ["kind": ["a", "b"]]).frame(width: 320, height: 400))
        pw.contentView = ph; pw.orderFrontRegardless(); RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func popups(_ v: NSView) -> Int { (v is NSPopUpButton ? 1 : 0) + v.subviews.reduce(0) { $0 + popups($1) } }
        check("Details fields keep no pop-up buttons", popups(ph) == 0)
        // Same for the sidebar footer: its schema Picker and "+" Menu looped the sidebar after a wake.
        let fs = Session.preview(Conn(name: "pg", kind: .postgres)); fs.schemas = ["public", "audit"]; fs.schema = "audit"
        let fh = NSHostingView(rootView: SidebarFooter(session: fs, newSchema: {}, newDatabase: {}).frame(width: 260))
        pw.contentView = fh; RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check("sidebar footer keeps no pop-up buttons", popups(fh) == 0)
        // JSON values are measured off-screen (sizing the shown text view from sizeThatFits looped
        // SwiftUI layout at full CPU); the measure must still follow the width and the line cap.
        let long = "{" + (1...80).map { #""key\#($0)": "value \#($0) with some words to wrap""# }.joined(separator: ", ") + "}"
        let jc = NSHostingController(rootView: JSONTextView(text: long)), capped = NSHostingController(rootView: JSONTextView(text: long, maxLines: 8))
        let narrow = jc.sizeThatFits(in: NSSize(width: 120, height: 1e6)).height, wide = jc.sizeThatFits(in: NSSize(width: 900, height: 1e6)).height
        let cap = capped.sizeThatFits(in: NSSize(width: 120, height: 1e6)).height
        check("JSON height follows the width and the line cap", narrow > wide && wide > cap && cap > 0)
        // A long value gets a one-click "Show all" under it (Expand in the menu alone was two clicks).
        // SwiftUI buttons expose no accessibility tree to the bench, so the condition is what's checked.
        let pretty = prettyJSON(long) ?? long
        check("long JSON value counts as clipped", RowDetails.clipped(pretty, jsonView: true, editable: false))
        // One logical line that wraps past 3 lines in a narrow field (the user's `question` column).
        let q = "Gerak lurus beraturan (GLB) adalah gerak benda pada lintasan lurus dengan ..."
        check("wrapped text field counts as clipped at panel width", RowDetails.clipped(q, jsonView: false, editable: true, width: 170)
              && !RowDetails.clipped(q, jsonView: false, editable: true, width: 900))
        // Few logical lines but wrapped past the cap in a narrow panel (the user's case): the view reports it.
        var reported: [Bool] = []
        let wrapped = "{\n  \"value\": \"" + String(repeating: "lurus beraturan ", count: 20) + "\"\n}"
        let wc = NSHostingController(rootView: JSONTextView(text: wrapped, maxLines: 8, onClipped: { reported.append($0) }))
        _ = wc.sizeThatFits(in: NSSize(width: 120, height: 1e6)); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check("wrapped JSON beyond the cap reports clipped", reported == [true])
        _ = wc.sizeThatFits(in: NSSize(width: 3000, height: 1e6)); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check("wide enough to fit reports not clipped", reported == [true, false])
        // Hosted in a SwiftUI layout (the real Details path): SwiftUI may ask for the size before updateNSView.
        var hosted: [Bool] = []
        let hv = NSHostingView(rootView: VStack { JSONTextView(text: wrapped, maxLines: 8, onClipped: { hosted.append($0) }) }.frame(width: 230))
        pw.contentView = hv; RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check("clipping is reported from a hosted SwiftUI layout", hosted == [true])
        check("short values offer no Show all", !RowDetails.clipped("a\nb", jsonView: false, editable: false, width: 200) && !RowDetails.clipped("{\"x\": 1}", jsonView: true, editable: true, width: 200))
        pw.close()
    }
    // Moving to another row must not carry a picker's value over as an edit.
    do {
        var pending: [Int: [Int: String?]] = [:]
        let res = QueryResult(columns: ["type"], types: ["kind_t"], rows: [["MARKDOWN"], ["INTERACTIVE"], ["MARKDOWN"]])
        func details(_ r: Int) -> some View {
            RowDetails(result: res, row: r, edits: Binding(get: { pending[r] ?? [:] }, set: { pending[r] = $0.isEmpty ? nil : $0 }),
                       enumValues: ["type": ["MARKDOWN", "INTERACTIVE"]]).frame(width: 300, height: 300)
        }
        let pw = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let ph = NSHostingView(rootView: AnyView(details(0)))
        pw.contentView = ph; pw.orderFrontRegardless()
        for r in [1, 2, 1] { RunLoop.main.run(until: Date().addingTimeInterval(0.2)); ph.rootView = AnyView(details(r)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check("changing rows leaves no edits behind", pending.isEmpty)
        // Same with a text field focused (a click into a Details value, then another row in the grid).
        let tres = QueryResult(columns: ["id", "name"], types: ["int4", "text"], rows: [["1", "ana"], ["2", "budi"], ["3", "cici"]])
        func tdetails(_ r: Int) -> some View {
            RowDetails(result: tres, row: r, edits: Binding(get: { pending[r] ?? [:] }, set: { pending[r] = $0.isEmpty ? nil : $0 })).frame(width: 300, height: 300)
        }
        ph.rootView = AnyView(tdetails(0)); RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func fields(_ v: NSView) -> [NSTextField] { ((v as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []) + v.subviews.flatMap(fields) }
        if let f = fields(ph).first(where: { $0.stringValue == "1" }) {
            pw.makeKey(); pw.makeFirstResponder(f)
            for r in [1, 2] { RunLoop.main.run(until: Date().addingTimeInterval(0.2)); ph.rootView = AnyView(tdetails(r)) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3)); pw.makeFirstResponder(nil); RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            check("changing rows with a field focused leaves no edits behind", pending.isEmpty)
        } else { check("details id field found", false) }
        pw.close()
    }
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
    // Result filter in the real grid: only matching rows show, and an edit lands on the source row.
    let fres = QueryResult(columns: ["id", "name"], rows: [["1", "alpha"], ["2", "Kelas 1"], ["3", "beta"], ["4", "kelas 2"]])
    var edited: (Int, Int, String?)?
    let fhost = NSHostingView(rootView: ResultGrid(result: fres, editable: true, onEdit: { edited = ($0, $1, $2) }, filter: "kelas")
        .frame(width: 400, height: 200))
    let fwin = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    fwin.contentView = fhost; fwin.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    if let ft = findTable(fhost), let ds = ft.dataSource as? ResultGrid.Coordinator {
        let shown = (0..<ft.numberOfRows).map { (ds.tableView(ft, objectValueFor: ft.tableColumns[1], row: $0) as? String) ?? "" }
        check("result filter: shows only matching rows", shown == ["Kelas 1", "kelas 2"])
        ds.tableView(ft, setObjectValue: "Kelas 2B", for: ft.tableColumns[1], row: 1)
        check("result filter: edit on a filtered row goes to its source row", edited?.0 == 3 && edited?.2 == "Kelas 2B")
    } else { check("result filter: grid found", false) }
    fwin.close()
    // Keymap: default shortcuts are all different; a taken shortcut is reported as a conflict.
    let defaults = KeyAction.allCases.map(\.defaultShortcut)
    check("keymap: default shortcuts are unique", Set(defaults.map(\.display)).count == defaults.count)
    let fresh = Keymap()
    check("keymap: conflict found for a taken shortcut",
          fresh.overrides.isEmpty ? fresh.conflict(Shortcut(key: "s", modifiers: [.command]), for: .run) == .save : true)
    check("keymap: menu-style display", Shortcut(key: "\r", modifiers: [.command, .shift]).display == "⇧⌘↩"
          && KeyAction.toggleDetails.defaultShortcut.display == "⇧⌘B")
    // Theme: forcing light / dark changes what windows draw with; System follows macOS again.
    let themed = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.titled], backing: .buffered, defer: false)
    Appearance.dark.apply()
    let dark = themed.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    Appearance.light.apply()
    let light = themed.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
    Appearance.system.apply()
    check("appearance: dark and light are applied, system clears the override", dark && light && NSApp.appearance == nil)
}

