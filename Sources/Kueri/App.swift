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

/// Puts each new window into the tab group of an existing one, regardless of the system
/// "prefer tabs" setting.
struct TabJoiner: NSViewRepresentable {
    var workspace: Bool
    final class V: NSView {
        var workspace = false { didSet { if workspace != oldValue { DispatchQueue.main.async { self.chrome() } } } }
        private var closing: Any?
        deinit { closing.map(NotificationCenter.default.removeObserver) }
        override func viewDidMoveToWindow() {
            guard let w = window else { return }
            // Closing the other tabs leaves a lone connection screen: hide its tab bar again.
            closing = closing ?? NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
                guard n.object as? NSWindow !== self?.window else { return }
                DispatchQueue.main.async { self?.chrome() }
            }
            // Keeps SwiftUI's own tabbingIdentifier: a new window only opens straight into the tab group
            // when it matches the existing windows.
            w.tabbingMode = .preferred
            let host = NSApp.windows.first(where: { $0 !== w && $0.isVisible && $0.tabbingIdentifier == w.tabbingIdentifier })
            let joining = host != nil && w.tabbedWindows?.count ?? 1 <= 1
            if joining { w.alphaValue = 0 } // shown only once it's a tab, not as a window first
            DispatchQueue.main.async {
                if joining, let host {
                    host.addTabbedWindow(w, ordered: .above)
                    w.alphaValue = 1
                    w.makeKeyAndOrderFront(nil)
                }
                self.chrome()
            }
        }
        /// A connection keeps the tab bar visible so tabs are discoverable; a lone connection screen
        /// shows just the plain title bar instead of a title bar plus a one-tab bar.
        func chrome() {
            guard let w = window else { return }
            // In a workspace the toolbar has its own (renamable) title and the tab shows it too.
            w.titleVisibility = workspace ? .hidden : .visible
            let show = workspace || (w.tabbedWindows?.count ?? 1) > 1
            if let g = w.tabGroup, g.isTabBarVisible != show { w.toggleTabBar(nil) }
        }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.workspace = workspace; return v }
    func updateNSView(_ v: V, context: Context) { v.workspace = workspace }
}

/// The tab shows the chosen connection while the toolbar keeps the app name.
struct TabTitle: NSViewRepresentable {
    var title: String
    final class V: NSView {
        var title = "" { didSet { window?.tab.title = title } }
        override func viewDidMoveToWindow() { window?.tab.title = title }
        override func viewWillMove(toWindow w: NSWindow?) { if w == nil { window?.tab.title = nil } } // back to the window title
    }
    func makeNSView(context: Context) -> V { let v = V(); v.title = title; return v }
    func updateNSView(_ v: V, context: Context) { v.title = title }
}
