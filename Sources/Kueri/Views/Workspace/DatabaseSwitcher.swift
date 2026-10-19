import AppKit
import SwiftUI

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

struct DatabaseDropdown: View {
    @Bindable var session: Session
    let newDatabase: () -> Void
    let close: () -> Void
    @State private var search = ""
    @State private var highlighted: String?
    @State private var monitor: Any?
    @State private var frame = CGRect.zero
    @FocusState private var focused: Bool

    private var filtered: [String] {
        session.databases.filter { nameMatches(search, $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search for database…", text: $search)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if let db = highlighted ?? filtered.first { open(db) } }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onExitCommand(perform: close)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            if filtered.isEmpty {
                Text("No databases match “\(search)”").foregroundStyle(.secondary).padding(.vertical, 10)
            } else {
                DatabaseList(items: filtered, current: session.conn.database, highlighted: $highlighted, pick: open)
                    .frame(height: min(CGFloat(filtered.count) * DatabaseList.rowHeight + 8, 340))
            }
            Divider()
            Button { close(); newDatabase() } label: {
                Label("New Database…", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 7)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .background(GeometryReader { g in Color.clear.onAppear { frame = g.frame(in: .global) }.onChange(of: g.frame(in: .global)) { frame = $1 } })
        .onAppear {
            focused = true
            highlighted = session.conn.database
            // Like a menu: a click anywhere outside closes it (the click still goes through).
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { e in
                if let w = e.window, let content = w.contentView {
                    let p = CGPoint(x: e.locationInWindow.x, y: content.bounds.height - e.locationInWindow.y)
                    if !frame.insetBy(dx: 0, dy: -34).contains(p) { DispatchQueue.main.async { close() } }
                }
                return e
            }
        }
        .onDisappear { monitor.map(NSEvent.removeMonitor); monitor = nil }
    }

    private func move(_ step: Int) {
        let list = filtered
        guard !list.isEmpty else { return }
        let i = highlighted.flatMap(list.firstIndex(of:)) ?? -step
        highlighted = list[min(max(i + step, 0), list.count - 1)]
    }

    private func open(_ db: String) { close(); if db != session.conn.database { session.switchDatabase(db) } }
}

/// The dropdown's rows in an NSTableView, which only makes the visible ones: as SwiftUI rows all
/// 107 databases were built on every open (~230 ms, measured).
struct DatabaseList: NSViewRepresentable {
    static let rowHeight: CGFloat = 26
    let items: [String]
    let current: String
    @Binding var highlighted: String?
    let pick: (String) -> Void

    final class Table: NSTableView {
        var hover: (Int) -> Void = { _ in }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self))
        }
        override func mouseMoved(with e: NSEvent) { hover(row(at: convert(e.locationInWindow, from: nil))) }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: DatabaseList
        let icon = NSImage(systemSymbolName: "cylinder.split.1x2", accessibilityDescription: nil)
        let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Current database")
        var syncing = false
        init(_ p: DatabaseList) { parent = p }
        func numberOfRows(in t: NSTableView) -> Int { parent.items.count }
        func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
            let cell = t.makeView(withIdentifier: .init("db"), owner: nil) as? NSTableCellView ?? makeCell()
            let db = parent.items[row]
            cell.textField?.stringValue = db
            cell.toolTip = db
            (cell.subviews.last as? NSImageView)?.image = db == parent.current ? check : nil
            return cell
        }
        private func makeCell() -> NSTableCellView {
            let c = NSTableCellView(); c.identifier = .init("db")
            let iv = NSImageView(image: icon ?? NSImage()), tf = NSTextField(labelWithString: ""), mark = NSImageView()
            iv.contentTintColor = .controlAccentColor
            mark.contentTintColor = .secondaryLabelColor
            tf.lineBreakMode = .byTruncatingMiddle
            tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            [iv, tf, mark].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; c.addSubview($0) }
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6), iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 8), tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                mark.leadingAnchor.constraint(greaterThanOrEqualTo: tf.trailingAnchor, constant: 6),
                mark.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8), mark.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.textField = tf; c.imageView = iv
            return c
        }
        func tableViewSelectionDidChange(_ n: Notification) {
            guard !syncing, let t = n.object as? NSTableView, t.selectedRow >= 0 else { return }
            parent.highlighted = parent.items[t.selectedRow]
        }
        @objc func clicked(_ t: NSTableView) { if t.clickedRow >= 0 { parent.pick(parent.items[t.clickedRow]) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let t = Table()
        t.headerView = nil
        t.rowHeight = Self.rowHeight
        t.style = .inset
        t.backgroundColor = .clear
        t.focusRingType = .none
        t.refusesFirstResponder = true // typing stays in the search field
        t.addTableColumn(NSTableColumn(identifier: .init("db")))
        t.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        t.dataSource = context.coordinator
        t.delegate = context.coordinator
        t.target = context.coordinator
        t.action = #selector(Coordinator.clicked(_:))
        t.hover = { [weak t] row in // hover highlights, like a menu
            guard let t, row >= 0, t.selectedRow != row else { return }
            t.selectRowIndexes([row], byExtendingSelection: false)
        }
        let sv = FillScrollView()
        sv.documentView = t
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator, old = c.parent.items
        c.parent = self
        guard let t = sv.documentView as? NSTableView else { return }
        if old != items || t.numberOfRows != items.count { t.reloadData() }
        if let h = highlighted, let i = items.firstIndex(of: h), t.selectedRow != i {
            c.syncing = true
            t.selectRowIndexes([i], byExtendingSelection: false)
            c.syncing = false
            t.scrollRowToVisible(i)
        }
    }
}
