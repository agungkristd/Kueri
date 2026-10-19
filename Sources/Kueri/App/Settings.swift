import AppKit
import SwiftUI

// MARK: Preferences

/// User preferences (UserDefaults), read where they're used so a change applies on the next use.
enum Prefs {
    static let pageSizeKey = "pageSize", maxRowsKey = "maxRows", timeoutKey = "queryTimeout"
    static let gridFontKey = "gridFontSize", editorFontKey = "editorFontSize", fontFamilyKey = "monoFontFamily"
    static let reopenTabsKey = "reopenTabs", newTabKey = "newTabOpens", saveHistoryKey = "saveHistory"

    private static func int(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
        let v = UserDefaults.standard.object(forKey: key) as? Int ?? fallback
        return min(max(v, range.lowerBound), range.upperBound)
    }
    private static func bool(_ key: String, _ fallback: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? fallback }

    static var pageSize: Int { int(pageSizeKey, 300, 50...5000) }
    static var maxRows: Int { int(maxRowsKey, 10_000, 1000...200_000) }
    /// Seconds a statement may run on the server; 0 = no limit. Applies to new connections.
    static var queryTimeout: Int { int(timeoutKey, 0, 0...86_400) }
    static var gridFontSize: CGFloat { CGFloat(int(gridFontKey, 12, 9...20)) }
    static var editorFontSize: CGFloat { CGFloat(int(editorFontKey, 13, 9...24)) }
    static var reopenTabs: Bool { bool(reopenTabsKey, true) }
    /// ⌘T: "connection" opens a new window tab, "query" a new query tab in the current connection.
    static var newTabOpensQuery: Bool { UserDefaults.standard.string(forKey: newTabKey) == "query" }
    static var saveHistory: Bool { bool(saveHistoryKey, true) }
    /// Font of the grid and the SQL editor; empty = the system's SF Mono.
    static var fontFamily: String { UserDefaults.standard.string(forKey: fontFamilyKey) ?? "" }
    static func mono(_ size: CGFloat) -> NSFont {
        let f = fontFamily
        return f.isEmpty ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : NSFontManager.shared.font(withFamily: f, traits: [], weight: 5, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
    /// Installed fixed-width families, for the Settings picker (Core Text, off the main thread).
    nonisolated static func monoFamilies() async -> [String] {
        await Task.detached {
            let mono = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: [kCTFontSymbolicTrait: CTFontSymbolicTraits.traitMonoSpace.rawValue]] as CFDictionary)
            let found = CTFontCollectionCreateMatchingFontDescriptors(CTFontCollectionCreateWithFontDescriptors([mono] as CFArray, nil)) as? [CTFontDescriptor] ?? []
            return Set(found.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }.filter { !$0.hasPrefix(".") }).sorted()
        }.value
    }
}

// MARK: Keymap

enum KeyAction: String, CaseIterable, Identifiable {
    case run, stop, save, filterRows, formatSQL, toggleEditor, history, processes, toggleSidebar, toggleDetails, switchDatabase, newTab, renameConnection
    var id: String { rawValue }
    var title: String {
        switch self {
        case .run: "Run query"
        case .stop: "Stop query"
        case .save: "Save changes"
        case .filterRows: "Filter result rows"
        case .formatSQL: "Format SQL"
        case .toggleEditor: "Show / hide SQL editor"
        case .history: "Query history"
        case .processes: "Server processes"
        case .toggleSidebar: "Show / hide sidebar"
        case .toggleDetails: "Show / hide row details"
        case .switchDatabase: "Switch database"
        case .newTab: "New tab"
        case .renameConnection: "Rename connection"
        }
    }
    var group: String {
        switch self {
        case .run, .stop, .save, .filterRows, .formatSQL, .toggleEditor: "Query"
        case .history, .processes, .toggleSidebar, .toggleDetails: "View"
        case .switchDatabase, .newTab, .renameConnection: "Connection"
        }
    }
    var defaultShortcut: Shortcut {
        switch self {
        case .run: Shortcut(key: "\r", modifiers: [.command])
        case .stop: Shortcut(key: ".", modifiers: [.command])
        case .save: Shortcut(key: "s", modifiers: [.command])
        case .filterRows: Shortcut(key: "f", modifiers: [.command])
        case .formatSQL: Shortcut(key: "f", modifiers: [.command, .shift])
        case .toggleEditor: Shortcut(key: "e", modifiers: [.command, .shift])
        case .history: Shortcut(key: "y", modifiers: [.command])
        case .processes: Shortcut(key: "p", modifiers: [.command, .shift])
        case .toggleSidebar: Shortcut(key: "b", modifiers: [.command])
        case .toggleDetails: Shortcut(key: "b", modifiers: [.command, .shift])
        case .switchDatabase: Shortcut(key: "k", modifiers: [.command])
        case .newTab: Shortcut(key: "t", modifiers: [.command])
        case .renameConnection: Shortcut(key: "r", modifiers: [.command, .shift])
        }
    }
}

/// A key plus modifiers, stored as text (lowercased key, "\r" for Return).
struct Shortcut: Codable, Equatable {
    var key: String
    var flags: UInt

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        flags = modifiers.intersection([.command, .shift, .option, .control]).rawValue
    }
    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: flags) }

    var keyboardShortcut: KeyboardShortcut {
        var m: EventModifiers = []
        if modifiers.contains(.command) { m.insert(.command) }
        if modifiers.contains(.shift) { m.insert(.shift) }
        if modifiers.contains(.option) { m.insert(.option) }
        if modifiers.contains(.control) { m.insert(.control) }
        let k: KeyEquivalent = switch key {
        case "\r": .return
        case "\t": .tab
        case "\u{1b}": .escape
        case "\u{7f}": .delete
        default: KeyEquivalent(Character(key))
        }
        return KeyboardShortcut(k, modifiers: m)
    }

    /// "⇧⌘E", in the order macOS menus use.
    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let names = ["\r": "↩", "\t": "⇥", "\u{1b}": "⎋", "\u{7f}": "⌫", " ": "Space", ".": "."]
        return s + (names[key] ?? key.uppercased())
    }

    /// From a key press while recording; nil when it can't be a shortcut (no ⌘ / ⌃ / ⌥).
    init?(event e: NSEvent) {
        let m = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !m.intersection([.command, .control, .option]).isEmpty,
              let chars = e.charactersIgnoringModifiers?.lowercased(), let c = chars.first else { return nil }
        let key = e.keyCode == 36 || e.keyCode == 76 ? "\r" : String(c)
        self.init(key: key, modifiers: m)
    }
}

@MainActor @Observable final class Keymap {
    static let shared = Keymap()
    private static let key = "keymap"
    private(set) var overrides: [String: Shortcut]

    init() {
        overrides = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Shortcut].self, from: $0) } ?? [:]
    }

    func shortcut(_ a: KeyAction) -> Shortcut { overrides[a.rawValue] ?? a.defaultShortcut }
    func keyboardShortcut(_ a: KeyAction) -> KeyboardShortcut { shortcut(a).keyboardShortcut }
    func display(_ a: KeyAction) -> String { shortcut(a).display }

    /// The action already using this shortcut, if any (other than `a`).
    func conflict(_ s: Shortcut, for a: KeyAction) -> KeyAction? {
        KeyAction.allCases.first { $0 != a && shortcut($0) == s }
    }

    func set(_ s: Shortcut, for a: KeyAction) { overrides[a.rawValue] = s == a.defaultShortcut ? nil : s; persist() }
    func reset(_ a: KeyAction) { overrides[a.rawValue] = nil; persist() }
    func resetAll() { overrides = [:]; persist() }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(overrides), forKey: Self.key)
    }
}

extension View {
    /// Keyboard shortcut from the user's keymap.
    func shortcut(_ a: KeyAction) -> some View { keyboardShortcut(Keymap.shared.keyboardShortcut(a)) }
}

// MARK: Settings window (⌘,)

/// Settings window with AppKit toolbar tabs, as Safari has. SwiftUI's Settings scene swapped each tab
/// icon for a slightly different image while switching (24×24 → 25×23 and back, measured), and
/// NSTabViewController re-attached the tab's form on every switch (30–150 ms each time). Here a tab is
/// built on its first visit and afterwards only hidden and shown again.
@MainActor final class SettingsWindow: NSObject, NSToolbarDelegate {
    static let width: CGFloat = 560, height: CGFloat = 480
    private static var shared: SettingsWindow?
    static func show() {
        if shared == nil { shared = SettingsWindow() }
        shared!.window.makeKeyAndOrderFront(nil)
    }

    private struct Tab { let title: String, symbol: String, make: () -> NSView }
    private let tabs: [Tab] = [
        Tab(title: "General", symbol: "gearshape") { NSHostingView(rootView: GeneralSettings()) },
        Tab(title: "Appearance", symbol: "paintbrush") { NSHostingView(rootView: AppearanceSettings()) },
        Tab(title: "Query", symbol: "tablecells") { NSHostingView(rootView: QuerySettings()) },
        Tab(title: "Privacy", symbol: "hand.raised") { NSHostingView(rootView: PrivacySettings()) },
        Tab(title: "Keymap", symbol: "keyboard") { NSHostingView(rootView: KeymapSettings()) },
    ]
    private var built: [String: NSView] = [:]
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: true)

    private override init() {
        super.init()
        let toolbar = NSToolbar(identifier: "settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        select(tabs[0].title)
        window.center()
    }

    private func select(_ title: String) {
        window.toolbar?.selectedItemIdentifier = .init(title)
        window.title = title
        if built[title] == nil, let tab = tabs.first(where: { $0.title == title }), let content = window.contentView {
            let v = tab.make()
            v.frame = content.bounds
            v.autoresizingMask = [.width, .height]
            content.addSubview(v)
            built[title] = v
        }
        for (t, v) in built { v.isHidden = t != title }
    }

    @objc private func clicked(_ item: NSToolbarItem) { select(item.itemIdentifier.rawValue) }

    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { tabs.map { .init($0.title) } }
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { tabs.map { .init($0.title) } }
    func toolbarSelectableItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { tabs.map { .init($0.title) } }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let tab = tabs.first(where: { $0.title == id.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(clicked(_:))
        return item
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.reopenTabsKey) private var reopenTabs = true
    @AppStorage(Prefs.newTabKey) private var newTab = "connection"
    var body: some View {
        Form {
            Section {
                Toggle("Reopen connection tabs at startup", isOn: $reopenTabs)
                Picker("\(Keymap.shared.display(.newTab)) opens", selection: $newTab) {
                    Text("A new connection tab").tag("connection")
                    Text("A new query tab in this connection").tag("query")
                }
            } footer: {
                Text("Reopened tabs connect again to the database they were on.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettings: View {
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue
    @AppStorage(Prefs.gridFontKey) private var gridFont = 12
    @AppStorage(Prefs.editorFontKey) private var editorFont = 13
    @AppStorage(Prefs.fontFamilyKey) private var family = ""
    @State private var families: [String] = []
    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: Binding(get: { Appearance(rawValue: appearance) ?? .system },
                                                   set: { appearance = $0.rawValue; $0.apply() })) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Also in View › Appearance (⌃⌘1, ⌃⌘2, ⌃⌘3).").font(.caption).foregroundStyle(.secondary)
            }
            Section("Data grid and SQL editor") {
                Picker("Font", selection: $family) {
                    Text("SF Mono (System)").tag("")
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Data grid: \(gridFont) pt", value: $gridFont, in: 9...20)
                Stepper("SQL editor: \(editorFont) pt", value: $editorFont, in: 9...24)
                FontPreview(grid: CGFloat(gridFont), editor: CGFloat(editorFont))
                    .id(family) // Prefs reads the stored family; redraw when it changes
            }
        }
        .formStyle(.grouped)
        .task { families = await Prefs.monoFamilies().filter { $0 != "SF Mono" } } // took ~1 s on the main thread
    }
}

/// How the grid and the editor will look with the chosen font and sizes.
private struct FontPreview: View {
    let grid: CGFloat, editor: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SQL editor").font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
            (Text("SELECT ").foregroundStyle(.blue) + Text("id, name ") + Text("FROM ").foregroundStyle(.blue)
             + Text("users ") + Text("WHERE ").foregroundStyle(.blue) + Text("email = ") + Text("'a@b.co'").foregroundStyle(.red)
             + Text(" -- 0O 1lI").foregroundStyle(.secondary))
                .font(Font(Prefs.mono(editor)))
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 4))
            Text("Data grid").font(.caption).foregroundStyle(.secondary).padding(.top, 10).padding(.bottom, 4)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                GridRow { Text("id"); Text("name"); Text("created_at") }.foregroundStyle(.secondary)
                GridRow { Text("1024"); Text("Ana"); Text("2026-10-19 08:30:00") }
                GridRow { Text("1025"); Text("NULL").foregroundStyle(.tertiary); Text("2026-10-19 09:05:12") }
            }
            .font(Font(Prefs.mono(grid)))
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

private struct QuerySettings: View {
    @AppStorage(Prefs.pageSizeKey) private var pageSize = 300
    @AppStorage(Prefs.maxRowsKey) private var maxRows = 10_000
    @AppStorage(Prefs.timeoutKey) private var timeout = 0
    var body: some View {
        Form {
            Section {
                Picker("Rows per page", selection: $pageSize) {
                    ForEach([100, 300, 500, 1000, 2000], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Result rows kept in memory", selection: $maxRows) {
                    ForEach([5_000, 10_000, 50_000, 100_000], id: \.self) { Text($0.formatted()).tag($0) }
                }
            } header: { Text("Grid") } footer: {
                Text("Browsing a table loads one page at a time. A query returning more rows than the limit shows the first ones; more rows use more memory.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Query timeout", selection: $timeout) {
                    Text("No limit").tag(0)
                    ForEach([30, 60, 300, 900, 3600], id: \.self) { Text($0 < 60 ? "\($0) seconds" : "\($0 / 60) minute\($0 == 60 ? "" : "s")").tag($0) }
                }
            } header: { Text("Server") } footer: {
                Text("PostgreSQL statement_timeout and MySQL max_execution_time (SELECT only). Applies to connections opened afterwards; SQLite and Redis aren't limited.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettings: View {
    @AppStorage(Prefs.saveHistoryKey) private var saveHistory = true
    @State private var confirmClear = false
    private var prefsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(Bundle.main.bundleIdentifier ?? "app.kueri").plist")
    }
    var body: some View {
        Form {
            Section {
                Toggle("Save query history", isOn: $saveHistory)
                HStack {
                    Text("\(QueryHistory.shared.entries.count) saved queries").foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") { reveal(QueryHistory.shared.url) }
                    Button("Clear History…", role: .destructive) { confirmClear = true }.disabled(QueryHistory.shared.entries.isEmpty)
                }
            } header: { Text("History") } footer: {
                Text("Queries that mention passwords or authentication are never saved. The file is readable only by your user account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text(prefsFile.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { reveal(prefsFile) }
                }
            } header: { Text("Connections") } footer: {
                Text("Saved connections, including passwords, are stored unencrypted in this file (readable only by your user account).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear all query history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { QueryHistory.shared.clearAll() }
        } message: { Text("Every saved query for every connection is removed. This can't be undone.") }
    }

    private func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.open(url.deletingLastPathComponent()) }
    }
}

private struct KeymapSettings: View {
    @State private var recording: KeyAction?
    @State private var message: String?
    @State private var monitor: Any?
    private let keymap = Keymap.shared

    var body: some View {
        Form {
            ForEach(["Query", "View", "Connection"], id: \.self) { group in
                Section(group) {
                    ForEach(KeyAction.allCases.filter { $0.group == group }) { a in
                        LabeledContent(a.title) {
                            HStack(spacing: 6) {
                                Button { start(a) } label: {
                                    Text(recording == a ? "Type a shortcut…" : keymap.display(a))
                                        .font(.body.monospaced()).frame(minWidth: 120)
                                }
                                .help("Click, then press the new shortcut (Esc cancels)")
                                Button { keymap.reset(a) } label: { Image(systemName: "arrow.uturn.backward") }
                                    .buttonStyle(.borderless).help("Back to \(a.defaultShortcut.display)")
                                    .disabled(keymap.shortcut(a) == a.defaultShortcut)
                            }
                        }
                    }
                }
            }
            Section {
                HStack {
                    if let message { Text(message).font(.callout).foregroundStyle(.orange) }
                    Spacer()
                    Button("Restore Defaults") { keymap.resetAll(); message = nil }.disabled(keymap.overrides.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { stop() }
    }

    private func start(_ a: KeyAction) {
        stop()
        recording = a; message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil } // Esc
            guard let s = Shortcut(event: e) else { message = "Use ⌘, ⌃ or ⌥ with a key."; return nil }
            if let other = keymap.conflict(s, for: a) {
                message = "\(s.display) is already used by “\(other.title)”."
            } else {
                keymap.set(s, for: a); message = nil
            }
            stop()
            return nil
        }
    }

    private func stop() {
        monitor.map(NSEvent.removeMonitor); monitor = nil
        recording = nil
    }
}
