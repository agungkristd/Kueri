import AppKit
import SwiftUI

@main struct KueriApp: App {
    init() {
        let a = CommandLine.arguments
        // New windows (⌘T) open straight into the tab group, whatever the system "prefer tabs" setting
        // is. TabJoiner alone can't: SwiftUI shows a new window before any of its views are attached.
        UserDefaults.standard.set("always", forKey: "AppleWindowTabbingMode")
        ToolbarTooltips.install()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            SSHTunnel.terminateAll()
        }
        if a.contains("--selftest") { selfTest(); exit(0) }
        if let i = a.firstIndex(of: "--perf"), i + 1 < a.count {
            MainActor.assumeIsolated { perf(a[i + 1], table: i + 2 < a.count ? a[i + 2] : nil) }; exit(0)
        }
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
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { SettingsWindow.show() }.keyboardShortcut(",", modifiers: .command)
                }
            }
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
                WorkspaceView(session: session, close: { self.session = nil; connID = ""; database = "" })
                    // Window title feeds the tab.
                    .navigationTitle((session.conn.isProd ? "PROD · " : "")
                                     + (session.conn.kind == .sqlite || session.conn.database.isEmpty
                                        ? session.conn.name : "\(session.conn.name) — \(session.conn.database)"))
                    .onChange(of: session.conn.database) { _, db in database = db }
            } else if let restoring {
                ProgressView("Reconnecting to \(restoring)…").navigationTitle(restoring)
            } else {
                ConnectionsView(notice: restoreError, onOpen: { s in
                    session = s; connID = s.conn.id.uuidString; database = s.conn.database; restoreError = nil
                })
            }
        }
        .background(TabJoiner(workspace: session != nil || restoring != nil))
        .task { await restore() }
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

struct RenameConnectionKey: FocusedValueKey { typealias Value = () -> Void }

struct SwitchDatabaseKey: FocusedValueKey { typealias Value = () -> Void }

struct NewQueryTabKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
    var switchDatabase: (() -> Void)? {
        get { self[SwitchDatabaseKey.self] }
        set { self[SwitchDatabaseKey.self] = newValue }
    }
    /// Set by the connections screen; File › Rename Connection… focuses the name field.
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
    /// The stored raw value as a picker selection; choosing one applies it right away.
    @MainActor static func selection(_ raw: Binding<String>) -> Binding<Appearance> {
        Binding(get: { Appearance(rawValue: raw.wrappedValue) ?? .system }, set: { raw.wrappedValue = $0.rawValue; $0.apply() })
    }
    @MainActor func apply() {
        NSApp?.appearance = switch self { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
    }
}

struct AppearanceCommands: Commands {
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Picker("Appearance", selection: Appearance.selection($appearance)) {
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
    /// The same path as the tab bar's "+": AppKit makes the window a tab before it's shown.
    /// openWindow shows a separate window first and only then can it be moved into the tabs.
    private func newConnectionTab() {
        if !NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil) { openWindow(id: "main") }
    }
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                if Prefs.newTabOpensQuery, let newQueryTab { newQueryTab() } else { newConnectionTab() }
            }
            .shortcut(.newTab)
            Button("New Connection Tab") { newConnectionTab() }
            Button("Rename Connection…") { renameConnection?() }
                .shortcut(.renameConnection)
                .disabled(renameConnection == nil)
            Button("Switch Database…") { switchDatabase?() }
                .shortcut(.switchDatabase)
                .disabled(switchDatabase == nil)
        }
    }
}
