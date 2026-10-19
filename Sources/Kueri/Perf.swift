import AppKit
import SwiftUI

// Performance and resource report: Kueri --perf <pg:database | file.sqlite> [table]
// Times the main paths against a real database and prints the process memory after each step.

@MainActor func perf(_ target: String, table wanted: String?) {
    setvbuf(stdout, nil, _IONBF, 0)
    /// Physical footprint, the "Memory" column of Activity Monitor.
    func rss() -> Double {
        var info = task_vm_info_data_t(), n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
        return Double(info.phys_footprint) / 1_048_576
    }
    func cpu() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1_000_000
    }
    func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    func wait(_ limit: Double = 60, until done: () -> Bool) {
        let end = Date().addingTimeInterval(limit)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }
    func row(_ step: String, _ ms: Double?, _ note: String = "") {
        let time = ms.map { String(format: "%8.0f ms", $0) } ?? "           "
        print(step.padding(toLength: 44, withPad: " ", startingAt: 0), time, String(format: "%7.0f MB", rss()), " ", note)
    }
    func timed(_ f: () -> Void) -> Double { let s = Date(); f(); return Date().timeIntervalSince(s) * 1000 }
    func find<T: NSView>(_ v: NSView, _ t: T.Type) -> T? { (v as? T) ?? v.subviews.lazy.compactMap { find($0, t) }.first }
    func host<V: View>(_ view: V, _ size: CGSize) -> (NSWindow, NSView) {
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        let h = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        w.contentView = h; w.orderFrontRegardless()
        h.layoutSubtreeIfNeeded(); h.display()
        return (w, h)
    }

    let conn = target.hasPrefix("pg:") ? Conn(name: "perf", kind: .postgres, database: String(target.dropFirst(3)))
                                       : Conn(name: "perf", kind: .sqlite, path: target)
    print("Kueri performance report:", conn.kind.rawValue, conn.kind == .sqlite ? conn.path : conn.database)
    print("step".padding(toLength: 44, withPad: " ", startingAt: 0), "    time", "   memory")
    row("start (process, nothing open)", nil)
    let cpu0 = cpu()

    var session: Session?, failure: Error?
    let connect = timed {
        var done = false
        Task { do { session = try await Session.open(conn) } catch { failure = error }; done = true }
        wait { done }
    }
    guard let s = session else { print("connect failed:", failure.map { "\($0)" } ?? "timeout"); return }
    row("connect + list tables", connect, "\(s.tables.count) tables")

    // The first table unless one is named (name a wide, large one for the heaviest case).
    let table = wanted ?? s.tables.first ?? ""
    guard !table.isEmpty else { print("no tables"); return }
    let open = timed { s.openTable(table); spin(0.01); wait { !s.busy } }
    row("open table (first page)", open, "\(table): \(s.result.rows.count) rows × \(s.result.columns.count) cols")

    var (w, h) = host(ResultGrid(result: s.result), CGSize(width: 1200, height: 800))
    let draw = timed { h.layoutSubtreeIfNeeded(); h.display() }
    row("draw grid", draw)
    if let sv = find(h, NSScrollView.self) {
        let pages = 60
        let scroll = timed {
            for i in 1...pages {
                sv.contentView.scroll(to: CGPoint(x: 0, y: CGFloat(i) * sv.contentView.bounds.height))
                sv.reflectScrolledClipView(sv.contentView); sv.display()
            }
        }
        row("scroll \(pages) pages", scroll, String(format: "%.1f ms per page (60 fps = 16.7)", scroll / Double(pages)))
        let sideways = timed {
            for i in 1...pages {
                sv.contentView.scroll(to: CGPoint(x: CGFloat(i) * 300, y: 0))
                sv.reflectScrolledClipView(sv.contentView); sv.display()
            }
        }
        row("scroll \(pages) pages sideways", sideways, String(format: "%.1f ms per page", sideways / Double(pages)))
    }
    w.close()

    if !s.databases.isEmpty {
        let (ww, wh) = host(WorkspaceView(session: s, close: {}), CGSize(width: 1200, height: 800))
        spin(0.5)
        func toggle(_ on: Bool) -> Double { timed { s.dbPicker = on; wh.layoutSubtreeIfNeeded(); spin(0.001); wh.layoutSubtreeIfNeeded(); wh.display() } }
        let times = (0..<5).map { _ in (toggle(true), toggle(false)) }
        let still = (0..<5).map { _ in timed { wh.layoutSubtreeIfNeeded(); spin(0.001); wh.layoutSubtreeIfNeeded(); wh.display() } }.sorted()[2]
        row("  (measuring overhead, nothing changed)", still)
        row("database dropdown open / close (workspace)", times.map(\.0).sorted()[2],
            String(format: "close %.0f ms, %d databases", times.map(\.1).sorted()[2], s.databases.count))
        ww.close()
        let alone = timed { let (dw, dh) = host(DatabaseDropdown(session: s, newDatabase: {}, close: {}), CGSize(width: 300, height: 500)); dh.display(); dw.close() }
        row("database dropdown alone", alone)
    }

    let quoted = conn.kind == .sqlite ? "\"\(table)\"" : table.split(separator: ".").map { "\"\($0)\"" }.joined(separator: ".")
    s.sql = "SELECT * FROM \(quoted) LIMIT 10000"
    let query = timed { s.run(); spin(0.01); wait { !s.busy } }
    row("query 10,000 rows", query, "\(s.result.rows.count) rows × \(s.result.columns.count) cols")
    (w, h) = host(ResultGrid(result: s.result), CGSize(width: 1200, height: 800))
    row("draw grid (10,000 rows)", timed { h.layoutSubtreeIfNeeded(); h.display() })
    w.close()

    let structure = timed { s.openStructure(table); wait { !s.result.rows.isEmpty && !s.busy } }
    row("structure", structure, "\(s.result.rows.count) columns")

    let model = timed { s.showDiagram(""); wait { s.diagram != nil } }
    row("diagram: read schema", model, "\(s.diagram?.tables.count ?? 0) tables, \(s.diagram?.links.count ?? 0) relations")
    var diagramHost: NSView?
    let render = timed {
        let (dw, dh) = host(DiagramView(model: s.diagram), CGSize(width: 1200, height: 800))
        w = dw; diagramHost = dh
        dh.layoutSubtreeIfNeeded(); dh.display()
    }
    row("diagram: draw", render)
    spin(0.3)
    if let dh = diagramHost, let canvas = find(dh, DiagramCanvas.self) {
        let p = NSPoint(x: 600, y: 400) // window coordinates
        let steps = 20
        let zoom = timed { for i in 0..<steps { canvas.setZoom(canvas.zoom * (i < steps / 2 ? 1.1 : 1 / 1.1), at: p); dh.display() } }
        row("diagram: \(steps) zoom steps", zoom, String(format: "%.1f ms per step", zoom / Double(steps)))
    }
    w.close()

    spin(1)
    let busyCPU = cpu() - cpu0
    let idle0 = cpu(); spin(5); let idle = (cpu() - idle0) / 5 * 100
    row("idle 5 s afterwards", nil, String(format: "CPU %.1f%%", idle))
    print(String(format: "CPU time for all steps: %.2f s", busyCPU))

    // Everything at once, as in a busy session: three connection windows, table tabs, large
    // results and the diagram, while the visible grid keeps scrolling.
    print("\nFull load")
    var sessions = [s]
    for _ in 0..<2 {
        var extra: Session?, done = false
        Task { extra = try? await Session.open(conn); done = true }
        wait { done }
        if let extra { sessions.append(extra) }
    }
    row("3 connections open", nil)
    let tables = Array(s.tables.prefix(10))
    let opened = timed { for t in tables { s.openTable(t, inNewTab: true); spin(0.01); wait { !s.busy } } }
    row("\(tables.count) table tabs", opened)
    let queries = timed {
        for x in sessions {
            _ = x.newTab()
            x.sql = "SELECT * FROM \(quoted) LIMIT 10000"
            x.run(); spin(0.01); wait { !x.busy }
        }
    }
    row("3 queries of 10,000 × \(s.result.columns.count) (one per connection)", queries)
    let (dw, dh) = host(DiagramView(model: s.diagram), CGSize(width: 1200, height: 800))
    row("whole-database diagram shown", nil, "tabs per connection: \(sessions.map { $0.tabs.count })")
    let (gw, gh) = host(ResultGrid(result: s.result), CGSize(width: 1200, height: 800))
    if let sv = find(gh, NSScrollView.self) {
        // Moves the grid once per 60 fps frame for 3 s; AppKit draws it as it would on screen.
        func scrolling(_ label: String, _ position: (Int) -> CGPoint) {
            sv.contentView.scroll(to: .zero); sv.reflectScrolledClipView(sv.contentView)
            let c0 = cpu(), t0 = Date()
            var frame = 0
            while Date().timeIntervalSince(t0) < 3 {
                frame += 1
                sv.contentView.scroll(to: position(frame)); sv.reflectScrolledClipView(sv.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
            }
            row(label, nil, String(format: "CPU %.0f%% of one core", (cpu() - c0) / 3 * 100))
        }
        let page = sv.contentView.bounds.height
        scrolling("scroll like a trackpad (30 pt a frame)") { CGPoint(x: 0, y: CGFloat($0) * 30) }
        scrolling("scroll a page a frame") { CGPoint(x: 0, y: CGFloat($0) * page) }
        scrolling("jump around, also sideways") { CGPoint(x: CGFloat($0 % 7) * 400, y: CGFloat($0 % 400) * page / 3) }
    }
    var info = task_vm_info_data_t(), n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
    row("peak", nil, String(format: "highest memory so far %.0f MB", Double(info.ledger_phys_footprint_peak) / 1_048_576))
    let idleFull0 = cpu(); spin(5)
    row("idle 5 s with all of it open", nil, String(format: "CPU %.1f%%", (cpu() - idleFull0) / 5 * 100))

    gw.close(); dw.close(); _ = dh; _ = gh
    weak var second = sessions.last
    for x in sessions { for t in x.tabs.map(\.id) { x.closeTab(t) } }
    s.diagram = nil
    sessions = []
    spin(2)
    malloc_zone_pressure_relief(nil, 0) // hand freed pages back, as the system does under pressure
    row("after closing all tabs and 2 connections", nil, second == nil ? "closed connections freed" : "a closed connection is still alive")
}
