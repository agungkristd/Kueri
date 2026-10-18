import SwiftUI
import os

// MARK: Saved connections, passwords included, in UserDefaults
// (~/Library/Preferences/local.kueri.plist, mode 0600). Not Keychain on purpose: with
// ad-hoc signing every rebuild is a "new app" to Keychain and re-prompted for each password.
// Limitation: password stored in plain text; move to Keychain once the app has a stable signing identity

struct Conn: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case sqlite = "SQLite", postgres = "PostgreSQL", mysql = "MySQL / MariaDB", redis = "Redis"
        var shortName: String { self == .mysql ? "MySQL" : rawValue }
        var icon: String {
            switch self {
            case .postgres, .mysql: "cylinder.split.1x2"
            case .sqlite: "doc"
            case .redis: "memorychip"
            }
        }
        var defaults: (port: String, user: String, database: String) {
            switch self {
            case .postgres: ("5432", "postgres", "postgres")
            case .mysql: ("3306", "root", "")
            case .redis: ("6379", "", "0")
            case .sqlite: ("", "", "")
            }
        }
    }
    var id = UUID()
    var name = "New connection"
    var kind = Kind.postgres
    var host = "localhost", port = "5432", user = "postgres", database = "postgres"
    var path = ""
    var password: String? // optional so connections saved before this field still decode
    var allowPublicKeyRetrieval: Bool? // MySQL caching_sha2 without TLS; nil = off
    var allowCleartextPassword: Bool?  // Postgres "password" auth / Redis AUTH to non-local hosts; nil = off
    var isProduction: Bool?            // asks before risky queries, saves and imports
    var tls: TLSMode?                  // nil = the default for the kind (Postgres prefer, others off)
    var useSSH: Bool?                  // tunnel through ssh; host/port are then as seen from the SSH server
    var sshHost: String?, sshPort: String?, sshUser: String?, sshKey: String?
    var tlsMode: TLSMode { tls ?? (kind == .postgres ? .prefer : .off) }
}

@Observable final class Store {
    var conns: [Conn] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(conns), forKey: "conns") }
    }
    init() {
        LegacyMigration.run() // before reading, so connections saved under the old name show up
        conns = (UserDefaults.standard.data(forKey: "conns").flatMap { try? JSONDecoder().decode([Conn].self, from: $0) }) ?? []
    }
}

/// One-time import from the app's previous name (LiteTable, bundle id local.litetable): connections,
/// panel settings and query history. Copies only; never deletes the old data.
enum LegacyMigration {
    static func run(defaults d: UserDefaults = .standard, old: UserDefaults? = UserDefaults(suiteName: "local.litetable"),
                    support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        if d.data(forKey: "conns") == nil, let old, old.data(forKey: "conns") != nil {
            for k in ["conns", "showDetails", "showEditor"] { if let v = old.object(forKey: k) { d.set(v, forKey: k) } }
        }
        let fm = FileManager.default
        let oldHistory = support.appendingPathComponent("LiteTable/history.json")
        let newHistory = support.appendingPathComponent("Kueri/history.json")
        if !fm.fileExists(atPath: newHistory.path), fm.fileExists(atPath: oldHistory.path) {
            try? fm.createDirectory(at: newHistory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: oldHistory, to: newHistory)
        }
    }
}

// MARK: Open session: one serial queue per connection, UI never blocks

@MainActor @Observable final class Session {
    private(set) var conn: Conn
    private var db: Database
    private let queue = DispatchQueue(label: "db")
    var tables: [String] = []
    var databases: [String] = []
    var schemas: [String] = []
    var schema = "public"     // Postgres schema shown in the sidebar
    var sql = ""
    var result = QueryResult()
    var selectedRow: Int?
    /// Unsaved edits, row → column → new value (nil = NULL). Shared by the grid and Details panel.
    var edits: [Int: [Int: String?]] = [:]
    var editCount: Int { edits.values.reduce(0) { $0 + $1.count } }
    var saving = false
    var table: String?        // table behind `result`, when it came from browse()
    var primaryKey: [String] = []
    var browsed: (query: String, table: String, offset: Int)?
    var offset = 0            // first row of the current page when `table` is set
    // Table tabs: the fields above always hold the active tab; other tabs are parked in `tabs`.
    var tabs: [WorkTab] = []
    var activeTab = UUID()
    var kind = TabKind.data
    var diagram: DiagramModel?
    // Column lists for autocomplete, per table of the current database.
    var history = QueryHistory.shared
    var tunnel: SSHTunnel?   // kept alive for the session; ssh stops when the session goes away
    var serverVersion = ""   // "PostgreSQL 16.8", shown in the connection bar
    var pendingConfirm: PendingConfirm?   // production safety question the workspace should show
    var columnCache: [String: [ColumnInfo]] = [:]
    var columnCacheLoading: Set<String> = []
    var error: String?
    var busy = false

    init(conn: Conn, db: Database) {
        self.conn = conn; self.db = db
        tabs = [WorkTab(id: activeTab)]
    }

    /// Runs `work` on the session's serial queue (the connection is not thread-safe).
    func onQueue<T>(_ work: @escaping (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in queue.async { [db] in c.resume(with: Result { try work(db) }) } }
    }

    /// Connects and loads the sidebar lists, off the main thread.
    /// Right after launch macOS can refuse LAN connections ("No route to host") while it checks the
    /// Local Network permission, even when it's granted; the same connection works seconds later.
    private static func connectRetryingLocal(_ c: Conn) async throws
        -> (Database, tables: [String], databases: [String], schemas: [String], tunnel: SSHTunnel?, version: String) {
        var attempt = 0
        while true {
            do { return try await connect(c) }
            catch where attempt < 3 && isLocalNetwork(c.host) && error.localizedDescription.contains("No route to host") {
                attempt += 1
                log.notice("LAN connect to \(c.host, privacy: .public) refused, retry \(attempt)")
                try await Task.sleep(for: .milliseconds(700 * attempt))
            }
        }
    }
    private static let log = Logger(subsystem: "app.kueri", category: "connect")

    /// Private / link-local addresses and .local names: what macOS's Local Network permission covers.
    nonisolated static func isLocalNetwork(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.hasSuffix(".local") || h.hasPrefix("10.") || h.hasPrefix("192.168.") || h.hasPrefix("169.254.") { return true }
        let p = h.split(separator: ".").compactMap { Int($0) }
        return p.count == 4 && p[0] == 172 && (16...31).contains(p[1])
    }

    /// Connects (through an SSH tunnel when configured; an existing tunnel is reused when switching
    /// databases) and loads the sidebar lists, off the main thread.
    private static func connect(_ c: Conn, tunnel existing: SSHTunnel? = nil) async throws
        -> (Database, tables: [String], databases: [String], schemas: [String], tunnel: SSHTunnel?, version: String) {
        let pw = c.password ?? ""
        return try await Task.detached {
            var tunnel = existing
            if c.useSSH == true, c.kind != .sqlite, tunnel == nil {
                tunnel = try SSHTunnel(sshHost: c.sshHost ?? "", sshPort: c.sshPort ?? "22", sshUser: c.sshUser ?? "",
                                       keyPath: c.sshKey, dbHost: c.host, dbPort: c.port.isEmpty ? c.kind.defaults.port : c.port)
            }
            let via = c.useSSH == true ? tunnel.map { (host: "127.0.0.1", port: String($0.localPort)) } : nil
            let db: Database = switch c.kind {
            case .sqlite: try SQLiteDB(path: c.path)
            case .postgres: try PostgresDB(host: c.host, port: c.port, user: c.user, password: pw, database: c.database,
                                           allowCleartextPassword: c.allowCleartextPassword ?? false, tls: c.tlsMode, via: via)
            case .mysql: try MySQLDB(host: c.host, port: c.port, user: c.user, password: pw, database: c.database,
                                     allowPublicKeyRetrieval: c.allowPublicKeyRetrieval ?? false, tls: c.tlsMode, via: via)
            case .redis: try RedisDB(host: c.host, port: c.port, user: c.user, password: pw, database: c.database,
                                     allowCleartextPassword: c.allowCleartextPassword ?? false, tls: c.tlsMode, via: via)
            }
            // Query timeout from Settings, enforced by the server for this session.
            let timeout = Prefs.queryTimeout
            if timeout > 0 {
                switch c.kind {
                case .postgres: _ = try? db.query("SET statement_timeout = \(timeout * 1000)")
                case .mysql: _ = try? db.query("SET SESSION max_execution_time = \(timeout * 1000)")
                default: break
                }
            }
            return (db, try db.tables(), (try? db.databases()) ?? [], (try? db.schemas()) ?? [], tunnel, (try? db.serverVersion()) ?? "")
        }.value
    }

    static func open(_ c: Conn) async throws -> Session {
        let (db, tables, databases, schemas, tunnel, version): (Database, [String], [String], [String], SSHTunnel?, String)
        do { (db, tables, databases, schemas, tunnel, version) = try await connectRetryingLocal(c) }
        catch where Self.isLocalNetwork(c.host) && error.localizedDescription.contains("No route to host") {
            // macOS blocks the LAN until Kueri is allowed; it reports that as "No route to host".
            // The hint goes first: error labels show only the first lines.
            throw DBError("""
                macOS is blocking Kueri from the local network. Turn on Kueri in System Settings › Privacy & Security › \
                Local Network (off and on again if it's already on), then connect again.\n\n
                """ + error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let s = Session(conn: c, db: db)
        s.tunnel = tunnel
        s.serverVersion = version
        s.tables = tables
        s.databases = databases
        s.schemas = schemas
        s.schema = schemas.contains("public") ? "public" : (schemas.first ?? "public")
        return s
    }

    var switchingTo: String?

    func rename(_ name: String) { conn.name = name }

    /// Dialect-quoted table name, for generated DDL.
    func quoteTable(_ t: String) -> String { db.quoteTable(t) }
    func schemaOf(_ t: String) -> String? { db.schemaOf(t) }

    /// Unconnected session for UI checks (`--bench`); queries would fail.
    static func preview(_ c: Conn) -> Session {
        let s = Session(conn: c, db: try! SQLiteDB(path: ":memory:"))
        s.history = QueryHistory(url: FileManager.default.temporaryDirectory.appendingPathComponent("kueri-preview-\(UUID()).json"))
        return s
    }

    /// Switches database inside this session: the views stay, only connection and lists change.
    /// (Rebuilding the whole workspace per switch blocked the main thread ~120 ms.)
    func switchDatabase(_ name: String) {
        guard name != conn.database, switchingTo == nil else { return }
        guard !tabs.contains(where: { $0.id != activeTab && !$0.edits.isEmpty }), edits.isEmpty else {
            error = "Save or discard unsaved changes first."; return
        }
        var c = conn
        c.database = name
        switchingTo = name; error = nil
        Task {
            defer { switchingTo = nil }
            do {
                let (newDB, t, d, sc, _, _) = try await Self.connect(c, tunnel: tunnel)
                // Old connection is released once queued work holding it finishes.
                db = newDB; conn = c; tables = t; databases = d; schemas = sc
                schema = sc.contains("public") ? "public" : (sc.first ?? "public")
                columnCache = [:]; columnCacheLoading = []
                resetTabs()
            } catch { self.error = error.localizedDescription }
        }
    }

    func run(_ text: String? = nil, confirmed: Bool = false) {
        let q = text ?? sql
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !busy else { return }
        if conn.isProduction == true, !confirmed {
            let reasons = riskyReasons(q, kind: conn.kind)
            if !reasons.isEmpty {
                pendingConfirm = PendingConfirm(title: "Run this on production \(conn.name)?", details: reasons, button: "Run on Production") { [weak self] in
                    self?.run(q, confirmed: true)
                }
                return
            }
        }
        // A new result would silently drop unsaved edits.
        guard edits.isEmpty else { error = "Save or discard \(editCount) unsaved change(s) first."; return }
        busy = true; error = nil
        // Rows are editable only when the result is exactly a sidebar browse of one table.
        let source = browsed?.query == q ? browsed?.table : nil
        let pageOffset = browsed?.offset ?? 0
        let tab = activeTab
        let started = Date()
        queue.async { [db] in
            let r = Result { try db.query(q) }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let t = try? db.tables()
            let sc = try? db.schemas() // a CREATE SCHEMA run from the editor shows up right away
            let pk = source.flatMap { try? db.primaryKey($0) } ?? []
            DispatchQueue.main.async {
                self.busy = false
                if source == nil { // user-run queries only; sidebar browsing would flood the history
                    let rows: Int? = (try? r.get()).map { $0.columns.isEmpty ? $0.affected : $0.rows.count }
                    let err: String? = if case .failure(let e) = r { e.localizedDescription } else { nil }
                    self.history.add(HistoryEntry(sql: q, connectionID: self.conn.id, connection: self.conn.name, database: self.conn.database,
                                                  date: started, milliseconds: ms, rows: rows, error: err))
                }
                self.updateTab(tab) { w in
                    switch r {
                    case .success(let v):
                        w.result = v; w.selectedRow = nil; w.error = nil
                        w.table = source; w.primaryKey = pk; w.offset = source == nil ? 0 : pageOffset
                    case .failure(let e): w.error = e.localizedDescription
                    }
                }
                if let t { self.tables = t }
                if let sc { self.schemas = sc }
            }
        }
    }

    /// Why the selected row can't be edited, or nil if it can.
    var readOnlyReason: String? {
        if conn.kind == .redis { return "Read-only: editing Redis values isn't supported yet." }
        if table == nil { return "Read-only: open a table from the sidebar to edit." }
        if primaryKey.isEmpty { return "Read-only: \(table!) has no primary key." }
        if let k = primaryKey.first(where: { !result.columns.contains($0) }) { return "Read-only: key column \(k) not in result." }
        return nil
    }

    /// One UPDATE for all changed fields of a row, matched by primary key.
    /// Records an edit, or clears it when the value is back to the original.
    func setEdit(row: Int, column: Int, value: String??) {
        var r = edits[row] ?? [:]
        if let value, value != result.rows[safe: row]?[safe: column] { r[column] = value } else { r.removeValue(forKey: column) }
        edits[row] = r.isEmpty ? nil : r
    }

    /// Saves every edited row (one UPDATE per row). Rows that fail keep their edits.
    func saveAll(confirmed: Bool = false) {
        guard !saving, !edits.isEmpty else { return }
        if conn.isProduction == true, !confirmed {
            pendingConfirm = PendingConfirm(title: "Save \(editCount) change(s) to production \(conn.name)?",
                                            details: ["Rows are updated by primary key in \(table ?? "this table")."], button: "Save to Production") { [weak self] in
                self?.saveAll(confirmed: true)
            }
            return
        }
        saving = true; error = nil
        Task {
            defer { saving = false }
            for (row, changes) in edits.sorted(by: { $0.key < $1.key }) {
                do { try await save(row: row, changes: changes); edits[row] = nil }
                catch { self.error = "Row \(offset + row + 1): \(error.localizedDescription)"; return }
            }
        }
    }

    func save(row: Int, changes: [Int: String?]) async throws {
        guard readOnlyReason == nil, let table, row < result.rows.count, !changes.isEmpty else { return }
        let r = result.rows[row]
        let key = primaryKey.map { k in (k, r[result.columns.firstIndex(of: k)!]) }
        let set = changes.sorted { $0.key < $1.key }.map { (result.columns[$0.key], $0.value) }
        let n = try await withCheckedThrowingContinuation { c in
            queue.async { [db] in c.resume(with: Result { try db.update(table, set: set, key: key) }) }
        }
        guard n == 1 else { throw DBError(n == 0 ? "No row matched (changed or deleted meanwhile?)" : "\(n) rows matched the primary key") }
        for (i, v) in changes { result.rows[row][i] = v }
        result.id = UUID() // grid redraws the edited cells
    }

    /// Sidebar structure: column list for a table, fetched on the session queue.
    func columns(_ table: String, done: @escaping ([ColumnInfo]) -> Void) {
        queue.async { [db] in
            let cols = (try? db.columns(table)) ?? []
            DispatchQueue.main.async { done(cols) }
        }
    }

    /// Bypasses the serial queue on purpose: the query is blocking it.
    func cancel() { DispatchQueue.global().async { [db] in db.cancel() } }

    var canPage: Bool { table != nil && conn.kind != .redis }
    var hasNextPage: Bool { canPage && result.rows.count == pageSize }
    func page(_ delta: Int) {
        guard let table, canPage else { return }
        browse(table, offset: max(0, offset + delta * pageSize))
    }

    func browse(_ table: String, offset: Int = 0) {
        queue.async { [db] in
            let q = Result { try db.browseQuery(table, offset: offset) }
            DispatchQueue.main.async {
                switch q {
                case .success(let v): self.browsed = (v, table, offset); self.sql = v; self.run()
                case .failure(let e): self.error = e.localizedDescription
                }
            }
        }
    }
}

// MARK: Views

@main struct KueriApp: App {
    init() {
        let a = CommandLine.arguments
        ToolbarTooltips.install()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            SSHTunnel.terminateAll()
        }
        if a.contains("--selftest") { selfTest(); exit(0) }
        if a.contains("--bench") { MainActor.assumeIsolated { bench() }; exit(0) }
        if let i = a.firstIndex(of: "--probe"), a.count >= i + 8 { probe(Array(a[(i + 1)...])); exit(0) }
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Appearance.current.apply()
                // Restored windows otherwise open behind the app that was in front (the cooperative
                // NSApp.activate() isn't granted at launch).
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    @State private var store = Store()
    var body: some Scene {
        WindowGroup(id: "main") { RootView().environment(store) }
            .defaultSize(width: 1100, height: 700)
            .commands {
                TabCommands()
                AppearanceCommands()
            }
        Settings { SettingsView() }
    }
}

/// One connection per window; windows are merged into native macOS tabs (⌘T opens a new one).
struct RootView: View {
    @Environment(Store.self) private var store
    @State private var session: Session?
    // Per-window, restored by macOS together with the tab: lets each tab reconnect after a restart.
    @SceneStorage("connID") private var connID = ""
    @SceneStorage("database") private var database = ""
    @State private var restoring: String?
    @State private var restoreError: String?

    var body: some View {
        Group {
            if let session {
                WorkspaceView(session: session, close: { self.session = nil; connID = ""; database = "" },
                              rename: { rename(session, $0) })
                    // Window title feeds the tab; the toolbar shows a rename button instead of the plain title.
                    .navigationTitle((session.conn.isProduction == true ? "PROD · " : "")
                                     + (session.conn.kind == .sqlite || session.conn.database.isEmpty
                                        ? session.conn.name : "\(session.conn.name) — \(session.conn.database)"))
                    .onChange(of: session.conn.database) { _, db in database = db }
            } else if let restoring {
                ProgressView("Reconnecting to \(restoring)…").navigationTitle(restoring)
            } else {
                ConnectionsView(notice: restoreError, onOpen: { s in
                    session = s; connID = s.conn.id.uuidString; database = s.conn.database; restoreError = nil
                })
                .navigationTitle("New Connection")
            }
        }
        .background(TabJoiner())
        .task { await restore() }
    }

    private func rename(_ s: Session, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        s.rename(n)
        if let i = store.conns.firstIndex(where: { $0.id == s.conn.id }) { store.conns[i].name = n }
    }

    private func restore() async {
        guard session == nil, Prefs.reopenTabs, let c = Self.restorable(store.conns, connID: connID, database: database) else { return }
        restoring = c.name
        defer { restoring = nil }
        do { session = try await Session.open(c) }
        catch { restoreError = "Couldn't reconnect to \(c.name): \(error.localizedDescription)" }
    }

    /// The saved connection a restored tab should reopen, with the database it was last on.
    static func restorable(_ conns: [Conn], connID: String, database: String) -> Conn? {
        guard var c = conns.first(where: { $0.id.uuidString == connID }) else { return nil }
        if !database.isEmpty { c.database = database }
        return c
    }
}

/// Selects the whole text when a field gains focus, so a value can be replaced by just typing.
struct SelectAllOnFocus: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focused($focused).onChange(of: focused) { _, isFocused in
            // .default mode only: the click's mouse tracking runs in .eventTracking mode and places the
            // caret on mouse-up, so selecting earlier (e.g. DispatchQueue.main.async) gets undone.
            if isFocused {
                RunLoop.main.perform(inModes: [.default]) {
                    // The focused field's editor, directly (not via the key window's responder chain).
                    let w = NSApp.keyWindow?.firstResponder is NSText ? NSApp.keyWindow : NSApp.windows.first { $0.firstResponder is NSText }
                    (w?.firstResponder as? NSText)?.selectAll(nil)
                }
            }
        }
    }
}

extension View {
    func selectAllOnFocus() -> some View { modifier(SelectAllOnFocus()) }
}

/// SwiftUI's `.help` doesn't reach bridged NSToolbarItems (their toolTip stayed nil, measured),
/// so tooltips are set on each item as AppKit adds it, by label. Also covers Run ⇄ Stop swaps.
enum ToolbarTooltips {
    @MainActor static var byLabel: [String: String] {
        let k = Keymap.shared
        return [
            "Run": "Run query (\(k.display(.run)))",
            "Stop": "Stop query (\(k.display(.stop)))",
            "SQL Editor": "Show/hide SQL editor (\(k.display(.toggleEditor)))",
            "History": "Show query history in the sidebar (\(k.display(.history)))",
            "Disconnect": "Disconnect",
            "Processes": "Server processes: see and kill client connections (\(k.display(.processes)))",
            "New Tab": "New connection tab",
            "Sidebar": "Show/hide tables (\(k.display(.toggleSidebar)))",
            "Details": "Show/hide row details (\(k.display(.toggleDetails)))",
        ]
    }
    @MainActor static func apply(_ item: NSToolbarItem) {
        if let tip = byLabel[item.label] { item.toolTip = tip }
    }
    static func install() {
        NotificationCenter.default.addObserver(forName: NSToolbar.willAddItemNotification, object: nil, queue: .main) { n in
            guard let item = n.userInfo?["item"] as? NSToolbarItem else { return }
            apply(item)
            DispatchQueue.main.async { apply(item) } // label can be filled in just after insertion
        }
    }
}

struct NewTabButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button { openWindow(id: "main") } label: { Label("New Tab", systemImage: "plus.rectangle.on.rectangle") }
            .help("New connection tab (⌘T)")
    }
}

struct RenameConnectionKey: FocusedValueKey { typealias Value = () -> Void }
struct SwitchDatabaseKey: FocusedValueKey { typealias Value = () -> Void }
struct NewQueryTabKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var switchDatabase: (() -> Void)? {
        get { self[SwitchDatabaseKey.self] }
        set { self[SwitchDatabaseKey.self] = newValue }
    }
    /// Set by the focused tab's workspace; lets File › Rename Connection… open its rename popover.
    var renameConnection: (() -> Void)? {
        get { self[RenameConnectionKey.self] }
        set { self[RenameConnectionKey.self] = newValue }
    }
    var newQueryTab: (() -> Void)? {
        get { self[NewQueryTabKey.self] }
        set { self[NewQueryTabKey.self] = newValue }
    }
}

/// App theme: follow the system, or force light / dark. Remembered across launches.
enum Appearance: String, CaseIterable {
    case system, light, dark
    static let key = "appearance"
    static var current: Appearance { UserDefaults.standard.string(forKey: key).flatMap(Appearance.init) ?? .system }
    var title: String { rawValue.capitalized }
    @MainActor func apply() {
        NSApp?.appearance = switch self { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
    }
}

struct AppearanceCommands: Commands {
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Picker("Appearance", selection: Binding(get: { Appearance(rawValue: appearance) ?? .system },
                                                    set: { appearance = $0.rawValue; $0.apply() })) {
                ForEach(Array(Appearance.allCases.enumerated()), id: \.element) { i, a in
                    Text(a.title).tag(a).keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: [.command, .control])
                }
            }
        }
    }
}

struct TabCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.renameConnection) private var renameConnection
    @FocusedValue(\.switchDatabase) private var switchDatabase
    @FocusedValue(\.newQueryTab) private var newQueryTab
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                if Prefs.newTabOpensQuery, let newQueryTab { newQueryTab() } else { openWindow(id: "main") }
            }
            .shortcut(.newTab)
            Button("New Connection Tab") { openWindow(id: "main") }
            Button("Rename Connection…") { renameConnection?() }
                .shortcut(.renameConnection)
                .disabled(renameConnection == nil)
            Button("Switch Database…") { switchDatabase?() }
                .shortcut(.switchDatabase)
                .disabled(switchDatabase == nil)
        }
    }
}

/// Puts each new window into the tab group of an existing one, regardless of the system
/// "prefer tabs" setting.
struct TabJoiner: NSViewRepresentable {
    final class V: NSView {
        override func viewDidMoveToWindow() {
            guard let w = window else { return }
            w.tabbingMode = .preferred
            w.titleVisibility = .hidden // tabs still show the title; the toolbar has its own (renamable) one
            w.tabbingIdentifier = "Kueri"
            DispatchQueue.main.async {
                // Always show the tab bar so connection tabs are discoverable, even with one tab.
                if w.tabGroup?.isTabBarVisible == false { w.toggleTabBar(nil) }
                guard w.tabbedWindows?.count ?? 1 <= 1,
                      let host = NSApp.windows.first(where: { $0 !== w && $0.isVisible && $0.tabbingIdentifier == "Kueri" })
                else { return }
                host.addTabbedWindow(w, ordered: .above)
                w.makeKeyAndOrderFront(nil)
            }
        }
    }
    func makeNSView(context: Context) -> V { V() }
    func updateNSView(_ v: V, context: Context) {}
}

struct ConnectionsView: View {
    @Environment(Store.self) private var store
    @State private var selection: UUID?
    @State private var draft = Conn()
    @State private var error: String?
    @State private var connecting = false
    @State private var tested: String?
    @State private var pendingDelete: Conn?
    @FocusState private var renaming: Bool
    var notice: String?
    let onOpen: (Session) -> Void

    var body: some View {
        NavigationSplitView {
            List(store.conns, selection: $selection) { c in
                HStack {
                    Image(systemName: c.kind.icon).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading) {
                        Text(c.name)
                        Text(c.kind == .sqlite ? c.path : "\(c.user)@\(c.host):\(c.port)/\(c.database)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { pendingDelete = c } label: { Image(systemName: "trash").foregroundStyle(.red) }
                        .buttonStyle(.borderless)
                        .help("Delete \(c.name)")
                }
                // Every other row slightly shaded, like the grid, so long lists stay easy to follow.
                .listRowBackground(rowBackground(c))
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let c = store.conns.first(where: { ids.contains($0.id) }) {
                    Button("Connect") { open(c) }
                    Button("Rename") { selection = c.id; draft = c; error = nil; renaming = true }
                    Button("Delete", role: .destructive) { pendingDelete = c }
                }
            } primaryAction: { ids in // double-click / Return
                if let c = store.conns.first(where: { ids.contains($0.id) }) { open(c) }
            }
            .toolbar {
                Button { new() } label: { Label("New", systemImage: "plus") }
                NewTabButton()
            }
            .confirmationDialog("Delete \"\(pendingDelete?.name ?? "")\"?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete", role: .destructive) { if let c = pendingDelete { delete(c) } }
            } message: { Text("Its saved password is removed too.") }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            // Fills the detail area: header on top, fields below (scrolling only if the window is short),
            // actions in a bar along the bottom edge.
            VStack(spacing: 0) {
                header.padding(.horizontal, 28).padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                ScrollView {
                    fields.frame(maxWidth: 900, alignment: .leading)
                        .padding(.horizontal, 28).padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer.padding(.horizontal, 8)
                    .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .onChange(of: draft.kind) { old, new in
            // Only swap defaults the user hasn't customised.
            let o = old.defaults, n = new.defaults
            if draft.port == o.port { draft.port = n.port }
            if draft.user == o.user { draft.user = n.user }
            if draft.database == o.database { draft.database = n.database }
        }
        .onChange(of: selection) { _, id in
            guard let c = store.conns.first(where: { $0.id == id }) else { return }
            draft = c; error = nil; tested = nil
        }
        .onChange(of: draft) { old, new in if old.id == new.id { tested = nil } } // a changed form needs a new test
    }

    private var summary: String {
        switch draft.kind {
        case .sqlite: draft.path.isEmpty ? "No file chosen" : draft.path
        default:
            (draft.user.isEmpty ? "" : draft.user + "@") + (draft.host.isEmpty ? "localhost" : draft.host)
                + (draft.port.isEmpty ? "" : ":" + draft.port) + (draft.database.isEmpty ? "" : "/" + draft.database)
                + (draft.useSSH == true ? " via \(draft.sshHost ?? "ssh")" : "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: draft.kind.icon).font(.system(size: 22)).foregroundStyle(.secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $draft.name, prompt: Text("Connection name"))
                    .labelsHidden().textFieldStyle(.plain).font(.title3.weight(.semibold))
                    .selectAllOnFocus().focused($renaming).onSubmit { save() }
                Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if draft.isProduction == true {
                Text("Production").font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(ConnectionBar.production))
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).frame(width: 96, alignment: .trailing).gridColumnAlignment(.trailing)
    }

    /// Labels right-aligned in one column, fields in the other; long explanations live in tooltips.
    private var fields: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                label("Type")
                Picker("Type", selection: $draft.kind) {
                    ForEach([Conn.Kind.postgres, .mysql, .sqlite, .redis], id: \.self) { Label($0.shortName, systemImage: $0.icon).tag($0) }
                }
                .labelsHidden().frame(width: 300, alignment: .leading)
            }
            if draft.kind == .sqlite {
                GridRow {
                    label("File")
                    HStack {
                        TextField("File", text: $draft.path, prompt: Text("/path/to/database.sqlite")).labelsHidden().selectAllOnFocus()
                        Button("Choose…") { pickFile() }
                    }
                }
            } else {
                GridRow {
                    label("Host")
                    HStack(spacing: 8) {
                        TextField("Host", text: $draft.host, prompt: Text("localhost")).labelsHidden().selectAllOnFocus()
                        Text("Port").foregroundStyle(.secondary)
                        TextField("Port", text: $draft.port, prompt: Text(draft.kind.defaults.port)).labelsHidden().selectAllOnFocus().frame(width: 70)
                    }
                }
                GridRow {
                    label(draft.kind == .redis ? "User (ACL)" : "User")
                    TextField("User", text: $draft.user, prompt: Text(draft.kind == .redis ? "optional" : draft.kind.defaults.user))
                        .labelsHidden().selectAllOnFocus()
                }
                GridRow {
                    label("Password")
                    SecureField("Password", text: Binding(get: { draft.password ?? "" }, set: { draft.password = $0.isEmpty ? nil : $0 }),
                                prompt: Text("none")).labelsHidden().selectAllOnFocus()
                }
                GridRow {
                    label(draft.kind == .redis ? "DB index" : "Database")
                    TextField("Database", text: $draft.database, prompt: Text(draft.kind == .redis ? "0" : "optional")).labelsHidden().selectAllOnFocus()
                }
                GridRow { Divider().gridCellColumns(2) }
                GridRow {
                    label("TLS / SSL")
                    HStack {
                        Picker("TLS / SSL", selection: Binding(get: { draft.tlsMode }, set: { draft.tls = $0 })) {
                            ForEach(TLSMode.allCases.filter { draft.kind != .redis || $0 != .prefer }, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 300, alignment: .leading)
                        .help("Required encrypts without checking the certificate (fine for a self-signed home server). Verify also checks the certificate and host name.")
                    }
                }
                if draft.kind == .postgres || draft.kind == .redis {
                    GridRow {
                        Color.clear.frame(width: 96, height: 1)
                        Toggle("Allow cleartext password", isOn: Binding(get: { draft.allowCleartextPassword ?? false },
                                                                        set: { draft.allowCleartextPassword = $0 }))
                            .help(draft.kind == .redis
                                  ? "Without TLS Verify or SSH, a Redis password is only sent to localhost unless this is on."
                                  : "Only for servers using the 'password' auth method.")
                    }
                }
                if draft.kind == .mysql {
                    GridRow {
                        Color.clear.frame(width: 96, height: 1)
                        Toggle("Allow public key retrieval", isOn: Binding(get: { draft.allowPublicKeyRetrieval ?? false },
                                                                          set: { draft.allowPublicKeyRetrieval = $0 }))
                            .help("MySQL 8 needs it to log in without TLS Verify. Only enable on a network you trust.")
                    }
                }
                GridRow {
                    Color.clear.frame(width: 96, height: 1)
                    Toggle("Connect over SSH", isOn: Binding(get: { draft.useSSH ?? false }, set: { draft.useSSH = $0 }))
                        .help("Uses your ~/.ssh config, keys and ssh-agent (no password login). Host and port above are as seen from the SSH server.")
                }
                if draft.useSSH == true {
                    GridRow {
                        label("SSH host")
                        HStack(spacing: 8) {
                            TextField("SSH host", text: Binding(get: { draft.sshHost ?? "" }, set: { draft.sshHost = $0 }), prompt: Text("bastion.example.com"))
                                .labelsHidden().selectAllOnFocus()
                            Text("Port").foregroundStyle(.secondary)
                            TextField("SSH port", text: Binding(get: { draft.sshPort ?? "22" }, set: { draft.sshPort = $0 }), prompt: Text("22"))
                                .labelsHidden().selectAllOnFocus().frame(width: 70)
                        }
                    }
                    GridRow {
                        label("SSH user")
                        TextField("SSH user", text: Binding(get: { draft.sshUser ?? "" }, set: { draft.sshUser = $0 }), prompt: Text(NSUserName()))
                            .labelsHidden().selectAllOnFocus()
                    }
                    GridRow {
                        label("Key")
                        HStack {
                            TextField("Key", text: Binding(get: { draft.sshKey ?? "" }, set: { draft.sshKey = $0 }), prompt: Text("ssh-agent / ~/.ssh/config"))
                                .labelsHidden()
                            Button("Choose…") { pickKey() }
                        }
                    }
                }
            }
            GridRow { Divider().gridCellColumns(2) }
            GridRow {
                Color.clear.frame(width: 96, height: 1)
                Toggle("Production database", isOn: Binding(get: { draft.isProduction ?? false }, set: { draft.isProduction = $0 }))
                    .help("Marks the connection in red and asks before UPDATE/DELETE without WHERE, DROP, TRUNCATE, saving edits and importing.")
            }
        }
        .textFieldStyle(.roundedBorder)
        .toggleStyle(.checkbox)
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            if connecting { ProgressView().controlSize(.small) }
            if let error = error ?? notice {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .lineLimit(3).textSelection(.enabled).font(.callout)
            } else if let tested {
                Label(tested, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            }
            Spacer()
            Button("Test Connection") { test() }.disabled(connecting)
            Button("Save") { save() }
            Button("Connect") { connect() }.keyboardShortcut(.defaultAction).disabled(connecting)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    /// Connects with the current form, reports the server version, and disconnects.
    func test() {
        connecting = true; error = nil; tested = nil
        let c = draft
        Task {
            defer { connecting = false }
            do {
                let s = try await Session.open(c)
                tested = "Connected" + (s.serverVersion.isEmpty ? "" : " · \(s.serverVersion)")
            } catch { self.error = error.localizedDescription }
        }
    }

    private func rowBackground(_ c: Conn) -> some View {
        let odd = !(store.conns.firstIndex(of: c) ?? 0).isMultiple(of: 2)
        return RoundedRectangle(cornerRadius: 6).fill(odd ? Color.primary.opacity(0.06) : .clear).padding(.horizontal, 10)
    }

    func new() { draft = Conn(); selection = nil }

    func save() {
        if let i = store.conns.firstIndex(where: { $0.id == draft.id }) { store.conns[i] = draft } else { store.conns.append(draft) }
        selection = draft.id
    }

    func delete(_ c: Conn) {
        store.conns.removeAll { $0.id == c.id }
        if draft.id == c.id { new() }
    }

    func pickKey() {
        let p = NSOpenPanel()
        p.showsHiddenFiles = true
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if p.runModal() == .OK, let u = p.url { draft.sshKey = u.path }
    }

    func pickFile() {
        let p = NSOpenPanel()
        p.allowsOtherFileTypes = true
        if p.runModal() == .OK, let u = p.url {
            draft.path = u.path
            if draft.name == Conn().name { draft.name = u.lastPathComponent }
        }
    }

    func open(_ c: Conn) {
        selection = c.id
        draft = c
        connect()
    }

    func connect() {
        save()
        connecting = true; error = nil
        Task {
            defer { connecting = false }
            do { onOpen(try await Session.open(draft)) } catch { self.error = error.localizedDescription }
        }
    }
}

struct WorkspaceView: View {
    @Bindable var session: Session
    let close: () -> Void
    var rename: (String) -> Void = { _ in }
    @State private var renaming = false
    @State private var dbPicker = false
    @State private var filter = ""
    @AppStorage("showDetails") private var showDetails = true
    @AppStorage("showEditor") private var showEditor = true
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var pendingAction: (action: TableAction, table: String)?
    enum SidebarTab { case items, diagram, history }
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
                    DatabaseSwitcher(session: session, open: $dbPicker, newDatabase: { pendingDatabase = true })
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
                    case (.diagram, .data): session.showDiagram(session.table ?? "") // no table open: whole database
                    case (.diagram, .structure(let t)): session.showDiagram(t)
                    case (.items, .diagram(let t)): session.openTable(t)
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
                            onSelect: { sidebarTab == .diagram ? session.showDiagram($0) : session.openTable($0) },
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
        } detail: {
          VStack(spacing: 0) {
            TabStrip(session: session)
            switch session.kind {
            case .structure(let t):
                StructureView(session: session, table: t)
            case .diagram:
                DiagramView(model: session.diagram, error: session.error,
                            structure: { t in try? await session.onQueue { try $0.structure(t) } },
                            onAction: { handle($0, $1) }, session: session)
            case .data:
            VSplitView {
                if showEditor {
                    SQLEditor(text: $session.sql, completer: SQLCompleter(session: session),
                              cacheVersion: session.columnCache.count)
                        .frame(minHeight: 80, idealHeight: 160)
                }
                VStack(spacing: 0) {
                    if let e = session.error {
                        Text(e).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    ResultGrid(result: session.result, selection: $session.selectedRow, edits: session.edits,
                               editable: session.readOnlyReason == nil,
                               onEdit: { r, c, v in session.setEdit(row: r, column: c, value: v) },
                               filter: rowFilter)
                    if session.editCount > 0 { SaveBar(session: session) }
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
            .focusedSceneValue(\.renameConnection) { renaming = true }
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
                DispatchQueue.main.async { dbPicker = true }
            })
            .inspector(isPresented: $showDetails) {
                RowDetails(result: session.result, row: session.selectedRow, readOnlyReason: session.readOnlyReason,
                           edits: Binding(get: { session.selectedRow.flatMap { session.edits[$0] } ?? [:] },
                                          set: { new in if let r = session.selectedRow { session.edits[r] = new.isEmpty ? nil : new } }))
                    .inspectorColumnWidth(min: 220, ideal: 300, max: 600)
            }
        }
        // Window-level toolbar: placement no longer depends on which split-view columns are visible.
        .toolbar {
            ToolbarItem(placement: .navigation) { ConnectionTitle(session: session, rename: rename, editing: $renaming) }
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
            NewTabButton()
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
        .modifier(HideToolbarTitle()) // the ConnectionTitle replaces it; the window title still names the tab
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

/// Connection name in the toolbar; click (or ⇧⌘R) turns it into an in-place text field, like
/// renaming in Finder. Return saves, Esc cancels.
struct ConnectionTitle: View {
    let session: Session
    let rename: (String) -> Void
    @Binding var editing: Bool
    @State private var name = ""
    @State private var hovering = false
    @FocusState private var nameFocused: Bool
    var body: some View {
        Group {
            if editing {
                TextField("Connection name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .focused($nameFocused)
                    .selectAllOnFocus()
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: nameFocused) { _, f in if !f && editing { commit() } } // click elsewhere = save
            } else {
                Button { editing = true } label: {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 6) {
                                Text(session.conn.name).font(.headline).lineLimit(1)
                                if session.conn.isProduction == true {
                                    // Real status, not decoration: this connection asks before risky queries.
                                    Text("Production").font(.caption.weight(.semibold)).foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.75, green: 0.16, blue: 0.16)))
                                        .help("Production: Kueri asks before risky queries, saves and imports")
                                }
                            }
                            if session.conn.kind != .sqlite, !session.conn.database.isEmpty {
                                Text(session.conn.database).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                            .opacity(hovering ? 1 : 0) // rename affordance only on hover
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(hovering ? 0.6 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Rename connection (⇧⌘R)")
            }
        }
        .onChange(of: editing) { _, on in
            if on { name = session.conn.name; DispatchQueue.main.async { nameFocused = true } }
        }
    }
    private func commit() {
        guard editing else { return }
        editing = false
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { rename(name) }
    }
}

extension WorkspaceView {
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
    @Binding var open: Bool
    var newDatabase: () -> Void = {}
    @State private var buttonHeight: CGFloat = 28
    var body: some View {
        Button { open.toggle() } label: {
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
            if open {
                DatabaseDropdown(session: session, newDatabase: newDatabase) { open = false }
                    .offset(y: buttonHeight + 4)
            }
        }
    }
}

/// Shown under the grid whenever there are unsaved edits, whether or not Details is open.
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


/// Cell-based NSTableView: cells are drawn, not instantiated as views, and only for visible
/// columns. SwiftUI's Table (~56 ms/scroll page) and view-based NSTableView (one NSTextField per
/// column per row: 285 columns ≈ 8.5k views, ~1.4 s to show) were both measured too slow.
/// Table that paints rows in an edit state with a light tint across the whole row (under the cells).
final class GridTable: NSTableView {
    var isTinted: (Int) -> Bool = { _ in false }
    override func drawRow(_ row: Int, clipRect: NSRect) {
        if isTinted(row), !isRowSelected(row) {
            ResultGrid.Coordinator.editTint.setFill()
            rect(ofRow: row).fill(using: .sourceOver)
        }
        super.drawRow(row, clipRect: clipRect)
    }
}

struct GridEditRequest: Equatable { let row: Int, column: Int; var id = UUID() }

/// Grid cell; cells picked from a menu show a pop-up chevron at the right, like a pop-up button.
final class GridCell: NSTextFieldCell {
    static let indicatorWidth: CGFloat = 18
    var showsMenuIndicator = false
    private static let chevron = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .medium).applying(.init(hierarchicalColor: .secondaryLabelColor)))

    override func drawInterior(withFrame frame: NSRect, in view: NSView) {
        guard showsMenuIndicator, let img = Self.chevron else { return super.drawInterior(withFrame: frame, in: view) }
        var text = frame; text.size.width -= Self.indicatorWidth
        super.drawInterior(withFrame: text, in: view)
        let s = img.size
        img.draw(in: NSRect(x: frame.maxX - Self.indicatorWidth + (Self.indicatorWidth - s.width) / 2, y: frame.midY - s.height / 2,
                            width: s.width, height: s.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

struct ResultGrid: NSViewRepresentable {
    let result: QueryResult
    @AppStorage(Prefs.gridFontKey) private var fontSize = 12 // re-renders when changed in Settings
    var selection: Binding<Int?> = .constant(nil)
    var edits: [Int: [Int: String?]] = [:]
    var editable = false
    var onEdit: (Int, Int, String?) -> Void = { _, _, _ in }
    /// Which cells edit inline (nil = all); a double-click elsewhere calls `onDoubleClick(row, column)`.
    var editableCell: ((Int, Int) -> Bool)? = nil
    /// Starts editing this cell once (e.g. the name of a row just added); a new id asks again.
    var editRequest: GridEditRequest? = nil
    /// Shows only rows whose cells contain every word (any order and case); edits and selection still
    /// refer to rows of `result`.
    var filter = ""
    var onDoubleClick: (Int, Int) -> Void = { _, _ in }
    /// Cells edited by picking from a menu (double-click shows it on the cell); nil = not a menu cell.
    var menuForCell: (Int, Int) -> [String]? = { _, _ in nil }
    /// Menu cells holding a comma-separated list: items are ticked when in it, and every pick is passed on
    /// (the owner toggles it), e.g. an index's columns.
    var isMultiMenu: (Int, Int) -> Bool = { _, _ in false }
    /// Rows in an edit state (e.g. not saved yet): a single click edits the clicked cell or opens its menu.
    var editsOnSingleClick: (Int) -> Bool = { _ in false }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var result = QueryResult()
        var selection: Binding<Int?> = .constant(nil)
        var edits: [Int: [Int: String?]] = [:]
        var editable = false
        var onEdit: (Int, Int, String?) -> Void = { _, _, _ in }
        var editableCell: ((Int, Int) -> Bool)?
        var lastEditRequest: UUID?
        var onDoubleClick: (Int, Int) -> Void = { _, _ in }
        var menuForCell: (Int, Int) -> [String]? = { _, _ in nil }
        var isMultiMenu: (Int, Int) -> Bool = { _, _ in false }
        var editsOnSingleClick: (Int) -> Bool = { _ in false }
        var filter = ""
        /// Displayed row → row of `result` while filtering (nil = all rows, same index).
        var visible: [Int]?
        func src(_ row: Int) -> Int { visible.map { row < $0.count ? $0[row] : row } ?? row }
        func display(_ source: Int) -> Int? { visible.map { $0.firstIndex(of: source) } ?? source }
        /// Rows whose editing started here and isn't reflected in `edits` yet (typing hasn't been committed).
        var startedRows: Set<Int> = []
        static let editTint = NSColor.systemOrange.withAlphaComponent(0.13)

        /// Rows in an edit state: tinted, and a single click edits their cells.
        func inEditState(_ row: Int) -> Bool { editsOnSingleClick(row) || startedRows.contains(row) }

        /// `row` is a displayed row; the started set keeps rows of `result`.
        func markStarted(_ row: Int, in tv: NSTableView) {
            guard !inEditState(src(row)) else { return }
            startedRows.insert(src(row))
            tv.setNeedsDisplay(tv.rect(ofRow: row))
        }
        private struct Pick { let row: Int, column: Int, value: String }

        @objc func menuPicked(_ item: NSMenuItem) {
            guard let p = item.representedObject as? Pick else { return }
            let current = edits[p.row]?[p.column] ?? result.rows[p.row][p.column]
            if p.value != current || isMultiMenu(p.row, p.column) { onEdit(p.row, p.column, p.value) }
        }
        func canEdit(_ column: NSTableColumn?, row: Int) -> Bool {
            guard editable else { return false }
            guard let editableCell else { return true }
            return column.flatMap { Int($0.identifier.rawValue) }.map { editableCell(row, $0) } == true
        }
        static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        static func edited(_ s: String?) -> NSAttributedString {
            NSAttributedString(string: s ?? "NULL", attributes: [.foregroundColor: NSColor.systemOrange, .font: font])
        }
        static let null = NSAttributedString(string: "NULL", attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        ])

        func numberOfRows(in tableView: NSTableView) -> Int { visible?.count ?? result.rows.count }

        func tableViewSelectionDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTableView else { return }
            let row = tv.selectedRow >= 0 ? src(tv.selectedRow) : nil
            // Deferred: updating SwiftUI state inside NSTableView's own event handling re-enters
            // the table (AppKit "reentrant operation" warning) and can cancel a starting cell edit.
            DispatchQueue.main.async { [selection] in
                if selection.wrappedValue != row { selection.wrappedValue = row }
            }
        }

        func tableView(_ tv: NSTableView, willDisplayCell cell: Any, for column: NSTableColumn?, row: Int) {
            guard let cell = cell as? GridCell, let i = column.flatMap({ Int($0.identifier.rawValue) }) else { return }
            cell.showsMenuIndicator = menuForCell(src(row), i) != nil

        }

        func tableView(_ tv: NSTableView, objectValueFor column: NSTableColumn?, row shown: Int) -> Any? {
            let row = src(shown)
            guard let column, let i = Int(column.identifier.rawValue), row < result.rows.count, i < result.rows[row].count else { return nil }
            if let e = edits[row]?[i] { return Self.edited(e) }
            return result.rows[row][i] ?? Self.null
        }

        // Return edits the selected cell; double-click is handled explicitly below.
        func tableView(_ tv: NSTableView, shouldEdit column: NSTableColumn?, row: Int) -> Bool { canEdit(column, row: src(row)) }

        @objc func clicked(_ tv: NSTableView) {
            guard tv.clickedRow >= 0, tv.clickedColumn >= 0, inEditState(src(tv.clickedRow)) else { return }
            let column = tv.tableColumns[tv.clickedColumn], r = src(tv.clickedRow)
            // Only cells that edit or have a menu; a click elsewhere just selects.
            guard let i = Int(column.identifier.rawValue), menuForCell(r, i) != nil || canEdit(column, row: r) else { return }
            doubleClicked(tv)
        }

        @objc func doubleClicked(_ tv: NSTableView) {
            guard tv.clickedRow >= 0, tv.clickedColumn >= 0 else { return }
            let column = tv.tableColumns[tv.clickedColumn], r = src(tv.clickedRow)
            if let i = Int(column.identifier.rawValue), let items = menuForCell(r, i) {
                let current = edits[r]?[i] ?? result.rows[r][i]
                let multi = isMultiMenu(r, i)
                let ticked = Set((current ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                let menu = NSMenu()
                var selected: NSMenuItem?
                for v in items {
                    let mi = NSMenuItem(title: v, action: #selector(menuPicked(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = Pick(row: r, column: i, value: v)
                    if multi ? ticked.contains(v) : v == current { mi.state = .on; selected = selected ?? mi }
                    menu.addItem(mi)
                }
                // Opens over the cell with the current value under the pointer, like a pop-up button.
                let cell = tv.frameOfCell(atColumn: tv.clickedColumn, row: tv.clickedRow)
                markStarted(tv.clickedRow, in: tv)
                menu.popUp(positioning: multi ? nil : selected, at: NSPoint(x: cell.minX, y: cell.maxY - 2), in: tv)
            } else if canEdit(column, row: r) {
                markStarted(tv.clickedRow, in: tv)
                tv.editColumn(tv.clickedColumn, row: tv.clickedRow, with: nil, select: true)
            }
            else if let i = Int(column.identifier.rawValue) { onDoubleClick(r, i) }
        }

        func tableView(_ tv: NSTableView, setObjectValue value: Any?, for column: NSTableColumn?, row shown: Int) {
            let row = src(shown)
            guard let column, let i = Int(column.identifier.rawValue), row < result.rows.count else { return }
            let text = (value as? NSAttributedString)?.string ?? value as? String ?? ""
            let current = edits[row]?[i] ?? result.rows[row][i]
            if text == (current ?? "NULL") { return } // committed without changes
            onEdit(row, i, text)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Rows containing every word of `filter` somewhere in their cells; nil when not filtering.
    static func matching(_ r: QueryResult, _ filter: String) -> [Int]? {
        let words = filter.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        return r.rows.indices.filter { i in
            let text = r.rows[i].compactMap { $0?.lowercased() }.joined(separator: "\u{1}")
            return words.allSatisfy { text.contains($0) }
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = GridTable()
        tv.isTinted = { [weak c = context.coordinator] row in c.map { $0.inEditState($0.src(row)) } ?? false }
        tv.style = .plain
        tv.focusRingType = .none // selection highlight is enough; the ring framed the whole grid
        tv.usesAlternatingRowBackgroundColors = true
        tv.gridStyleMask = .solidVerticalGridLineMask
        tv.columnAutoresizingStyle = .noColumnAutoresizing
        tv.allowsMultipleSelection = true
        tv.rowHeight = Prefs.gridFontSize + 6
        tv.dataSource = context.coordinator
        tv.delegate = context.coordinator
        tv.target = context.coordinator
        tv.doubleAction = #selector(Coordinator.doubleClicked(_:))
        tv.action = #selector(Coordinator.clicked(_:))
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.focusRingType = .none
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        c.selection = selection
        c.editable = editable
        c.onEdit = onEdit
        c.editableCell = editableCell
        defer {
            if let r = editRequest, r.id != c.lastEditRequest, let tv = sv.documentView as? NSTableView {
                c.lastEditRequest = r.id
                DispatchQueue.main.async {
                    guard r.row < tv.numberOfRows, let col = tv.tableColumns.firstIndex(where: { $0.identifier.rawValue == String(r.column) }) else { return }
                    tv.selectRowIndexes([r.row], byExtendingSelection: false)
                    tv.scrollRowToVisible(r.row)
                    c.markStarted(r.row, in: tv)
                    tv.editColumn(col, row: r.row, with: nil, select: true)
                }
            }
        }
        c.onDoubleClick = onDoubleClick
        c.menuForCell = menuForCell
        c.isMultiMenu = isMultiMenu
        c.editsOnSingleClick = editsOnSingleClick
        guard let tv = sv.documentView as? NSTableView else { return }
        let size = Prefs.gridFontSize
        if tv.rowHeight != size + 6 { // font size changed in Settings
            tv.rowHeight = size + 6
            for col in tv.tableColumns { (col.dataCell as? NSCell)?.font = .monospacedSystemFont(ofSize: size, weight: .regular) }
            tv.reloadData()
        }
        if c.result.id == result.id {
            if c.filter != filter { c.filter = filter; c.visible = Self.matching(result, filter); tv.deselectAll(nil); tv.reloadData() }
            if c.edits != edits {
                if edits.isEmpty { c.startedRows = [] } // saved or discarded: back to the normal state
                c.edits = edits; tv.reloadData()  // cheap for cell-based tables
            }
            return
        }
        c.edits = edits
        c.startedRows = []
        if tv.tableColumns.map(\.title) != result.columns {
            // Empty the table before touching columns: AppKit redraws visible rows while
            // columns change, and must not see old row indexes against the new data.
            c.result = QueryResult()
            tv.reloadData()
            tv.tableColumns.forEach(tv.removeTableColumn)
            for (i, name) in result.columns.enumerated() {
                let col = NSTableColumn(identifier: .init(String(i)))
                col.title = name
                col.isEditable = true // gated by shouldEdit
                let cell = GridCell()
                cell.isEditable = true // NSCell defaults to non-editable; shouldEdit still gates it
                cell.font = .monospacedSystemFont(ofSize: Prefs.gridFontSize, weight: .regular)
                cell.lineBreakMode = .byTruncatingTail
                cell.truncatesLastVisibleLine = true
                col.dataCell = cell
                // Width from header + first rows, ~7.3pt per monospaced char.
                let chars = result.rows.prefix(50).map { $0[i]?.count ?? 4 }.max() ?? 0
                col.width = min(400, max(60, CGFloat(max(chars, name.count)) * 7.3 + 16)) + (menuForCell(0, i) != nil ? GridCell.indicatorWidth : 0)
                tv.addTableColumn(col)
            }
        }
        c.result = result
        c.filter = filter
        c.visible = Self.matching(result, filter)
        tv.reloadData()
        tv.scrollRowToVisible(0)
    }
}
