import AppKit
import SwiftUI

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
                Picker("Theme", selection: Appearance.selection($appearance)) {
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
