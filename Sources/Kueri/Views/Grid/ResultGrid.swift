import AppKit
import SwiftUI

/// Cell-based NSTableView: cells are drawn, not instantiated as views, and only for visible
/// columns. SwiftUI's Table (~56 ms/scroll page) and view-based NSTableView (one NSTextField per
/// column per row: 285 columns ≈ 8.5k views, ~1.4 s to show) were both measured too slow.
/// Table that paints rows in an edit state with a light tint across the whole row (under the cells).
final class GridTable: NSTableView {
    var isTinted: (Int) -> Bool = { _ in false }
    /// Alternating rows on the window-background colour: the system pair is the darker text
    /// background, which is now the side panels' colour.
    override func drawBackground(inClipRect clip: NSRect) {
        super.drawBackground(inClipRect: clip)
        let rows = self.rows(in: clip)
        guard rows.length > 0 else { return }
        NSColor.labelColor.withAlphaComponent(0.035).setFill()
        for r in stride(from: rows.location | 1, to: rows.location + rows.length, by: 2) { rect(ofRow: r).intersection(clip).fill() }
    }
    override func keyDown(with e: NSEvent) {
        // Delete / forward delete: delete the selected rows (asks first).
        if [51, 117].contains(e.keyCode), let c = delegate as? ResultGrid.Coordinator, c.onDeleteRows != nil { return c.deleteSelected(self) }
        super.keyDown(with: e)
    }
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
    var showsLink = false
    private static let chevron = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .medium).applying(.init(hierarchicalColor: .secondaryLabelColor)))
    private static let arrow = NSImage(systemSymbolName: "arrow.right.circle.fill", accessibilityDescription: "Open referenced row")?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(hierarchicalColor: .secondaryLabelColor)))

    override func drawInterior(withFrame frame: NSRect, in view: NSView) {
        guard let img = showsMenuIndicator ? Self.chevron : showsLink ? Self.arrow : nil else { return super.drawInterior(withFrame: frame, in: view) }
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
    @AppStorage(Prefs.fontFamilyKey) private var fontFamily = ""
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
    /// Live-refreshing lists: new results keep the scroll position and the selected row.
    var keepPosition = false
    var onDoubleClick: (Int, Int) -> Void = { _, _ in }
    /// Cells edited by picking from a menu (double-click shows it on the cell); nil = not a menu cell.
    var menuForCell: (Int, Int) -> [String]? = { _, _ in nil }
    /// Menu cells holding a comma-separated list: items are ticked when in it, and every pick is passed on
    /// (the owner toggles it), e.g. an index's columns.
    var isMultiMenu: (Int, Int) -> Bool = { _, _ in false }
    /// Rows in an edit state (e.g. not saved yet): a single click edits the clicked cell or opens its menu.
    var editsOnSingleClick: (Int) -> Bool = { _ in false }
    /// Result columns not shown (still in `result`, so edits and menus keep their indexes).
    var hiddenColumns: Set<Int> = []
    /// Foreign-key columns: an arrow at the right of each value opens the row it points to.
    var links: Set<Int> = []
    var onFollow: (Int, Int) -> Void = { _, _ in }
    /// Deletes rows of `result` (menu and Delete key); nil = rows can't be deleted here.
    var onDeleteRows: (([Int]) -> Void)? = nil
    /// Every selected row of `result` after each selection change.
    var onSelectRows: ([Int]) -> Void = { _ in }
    /// Header sort arrow, and what a header click does (nil = headers don't sort).
    var sortOrder: (column: Int, ascending: Bool)? = nil
    var onSort: ((Int) -> Void)? = nil

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
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
        var links: Set<Int> = []
        var onFollow: (Int, Int) -> Void = { _, _ in }
        var onDeleteRows: (([Int]) -> Void)?
        var onSelectRows: ([Int]) -> Void = { _ in }
        var onSort: ((Int) -> Void)?
        var filter = ""
        /// Displayed row → row of `result` while filtering (nil = all rows, same index).
        var visible: [Int]?
        func src(_ row: Int) -> Int { visible.map { row < $0.count ? $0[row] : row } ?? row }
        func display(_ source: Int) -> Int? { visible.map { $0.firstIndex(of: source) } ?? source }
        /// Rows whose editing started here and isn't reflected in `edits` yet (typing hasn't been committed).
        var startedRows: Set<Int> = []
        static let editTint = NSColor.systemOrange.withAlphaComponent(0.13)

        /// Rows in an edit state: tinted, and a single click edits their cells.
        func inEditState(_ row: Int) -> Bool { edits[row] != nil || editsOnSingleClick(row) || startedRows.contains(row) }

        /// `row` is a displayed row; the started set keeps rows of `result`.
        func markStarted(_ row: Int, in tv: NSTableView) {
            guard !inEditState(src(row)) else { return }
            startedRows.insert(src(row))
            tv.setNeedsDisplay(tv.rect(ofRow: row))
        }
        private struct Pick { let row: Int, column: Int, value: String }

        @objc func menuPicked(_ item: NSMenuItem) {
            guard let p = item.representedObject as? Pick else { return }
            let current = edits[p.row]?[p.column] ?? result.rows.cell(p.row, p.column)
            if p.value != current || isMultiMenu(p.row, p.column) { onEdit(p.row, p.column, p.value) }
        }
        func canEdit(_ column: NSTableColumn?, row: Int) -> Bool {
            guard editable else { return false }
            guard let editableCell else { return true }
            return column.flatMap { Int($0.identifier.rawValue) }.map { editableCell(row, $0) } == true
        }
        /// Grid font (Settings); the NULL text is built once per font, not per cell.
        var font = Prefs.mono(Prefs.gridFontSize) { didSet { null = Self.null(font) } }
        lazy var null = Self.null(font)
        static func null(_ f: NSFont) -> NSAttributedString {
            NSAttributedString(string: "NULL", attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: f])
        }
        func edited(_ s: String?) -> NSAttributedString {
            NSAttributedString(string: s ?? "NULL", attributes: [.foregroundColor: NSColor.systemOrange, .font: font])
        }

        func numberOfRows(in tableView: NSTableView) -> Int { visible?.count ?? result.rows.count }

        // Right-click: copy the clicked cell, its row (tab-separated, like a spreadsheet) or the column name.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tv = menu.delegate.flatMap({ _ in table }), tv.clickedRow >= 0 else { return }
            let r = src(tv.clickedRow)
            let col = tv.clickedColumn >= 0 ? Int(tv.tableColumns[tv.clickedColumn].identifier.rawValue) : nil
            func value(_ c: Int) -> String? { (edits[r]?[c]) ?? result.rows.cell(r, c) }
            func add(_ title: String, _ text: String) {
                let mi = NSMenuItem(title: title, action: #selector(copyText(_:)), keyEquivalent: "")
                mi.target = self; mi.representedObject = text
                menu.addItem(mi)
            }
            if let col, col < result.columns.count {
                add("Copy Value", value(col) ?? "")
                add("Copy Column Name", result.columns[col])
            }
            add("Copy Row", result.columns.indices.map { value($0) ?? "NULL" }.joined(separator: "\t"))
            if let col, links.contains(col), value(col) != nil {
                menu.addItem(.separator())
                let mi = NSMenuItem(title: "Open Referenced Row", action: #selector(followClicked(_:)), keyEquivalent: "")
                mi.target = self; mi.representedObject = [r, col]
                menu.addItem(mi)
            }
            if onDeleteRows != nil {
                // The clicked row, or the whole selection when the click is inside it.
                let rows = tv.selectedRowIndexes.contains(tv.clickedRow) ? tv.selectedRowIndexes.map(src) : [r]
                menu.addItem(.separator())
                let mi = NSMenuItem(title: rows.count == 1 ? "Delete Row" : "Delete \(rows.count) Rows", action: #selector(deleteClicked(_:)), keyEquivalent: "")
                mi.target = self; mi.representedObject = rows
                menu.addItem(mi)
            }
        }

        @objc func followClicked(_ item: NSMenuItem) {
            guard let p = item.representedObject as? [Int] else { return }
            onFollow(p[0], p[1])
        }
        @objc func deleteClicked(_ item: NSMenuItem) { onDeleteRows?(item.representedObject as? [Int] ?? []) }
        /// Delete key in the grid: the selected rows.
        func deleteSelected(_ tv: NSTableView) {
            guard let onDeleteRows, !tv.selectedRowIndexes.isEmpty else { return }
            onDeleteRows(tv.selectedRowIndexes.map(src))
        }

        @objc func copyText(_ item: NSMenuItem) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.representedObject as? String ?? "", forType: .string)
        }

        weak var table: NSTableView?

        func tableView(_ tv: NSTableView, didClick column: NSTableColumn) {
            if let i = Int(column.identifier.rawValue) { onSort?(i) }
        }

        func tableViewSelectionDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTableView else { return }
            let row = tv.selectedRow >= 0 ? src(tv.selectedRow) : nil
            let rows = tv.selectedRowIndexes.map(src)
            // Deferred: updating SwiftUI state inside NSTableView's own event handling re-enters
            // the table (AppKit "reentrant operation" warning) and can cancel a starting cell edit.
            DispatchQueue.main.async { [selection, onSelectRows] in
                if selection.wrappedValue != row { selection.wrappedValue = row }
                onSelectRows(rows)
            }
        }

        func tableView(_ tv: NSTableView, willDisplayCell cell: Any, for column: NSTableColumn?, row: Int) {
            guard let cell = cell as? GridCell, let i = column.flatMap({ Int($0.identifier.rawValue) }) else { return }
            cell.showsMenuIndicator = menuForCell(src(row), i) != nil
            cell.showsLink = links.contains(i) && src(row) < result.rows.count && result.rows.cell(src(row), i) != nil

        }

        func tableView(_ tv: NSTableView, objectValueFor column: NSTableColumn?, row shown: Int) -> Any? {
            let row = src(shown)
            guard let column, let i = Int(column.identifier.rawValue), row < result.rows.count, i < result.rows.width(row) else { return nil }
            if let e = edits[row]?[i] { return edited(e) }
            return result.rows.cell(row, i) ?? null
        }

        // Return edits the selected cell; double-click is handled explicitly below.
        func tableView(_ tv: NSTableView, shouldEdit column: NSTableColumn?, row: Int) -> Bool {
            guard canEdit(column, row: src(row)) else { return false }
            openedWith = (tableView(tv, objectValueFor: column, row: row) as? NSAttributedString)?.string
                ?? tableView(tv, objectValueFor: column, row: row) as? String
            return true
        }
        /// What the cell editor showed when it opened. If the value changes elsewhere while it is
        /// open (Set NULL in Details, then Save), AppKit commits the editor's untouched text as an
        /// edit, which overwrote the NULL with the old text.
        var openedWith: String?

        @objc func clicked(_ tv: NSTableView) {
            // The arrow of a foreign-key cell: open the row it points to.
            if tv.clickedRow >= 0, tv.clickedColumn >= 0, let i = Int(tv.tableColumns[tv.clickedColumn].identifier.rawValue),
               links.contains(i), let e = NSApp.currentEvent {
                let cell = tv.frameOfCell(atColumn: tv.clickedColumn, row: tv.clickedRow)
                if tv.convert(e.locationInWindow, from: nil).x >= cell.maxX - GridCell.indicatorWidth,
                   result.rows.cell(src(tv.clickedRow), i) != nil {
                    return onFollow(src(tv.clickedRow), i)
                }
            }
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
                let current = edits[r]?[i] ?? result.rows.cell(r, i)
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
            let current = edits[row]?[i] ?? result.rows.cell(row, i)
            if text == (current ?? "NULL") || text == openedWith { return } // committed without typing anything
            onEdit(row, i, text)
        }

        /// However editing ended (Return, Tab, a click elsewhere, Esc; AppKit sends no commit for an
        /// unchanged cell), the started rows go back to normal; rows with real edits stay tinted.
        func controlTextDidEndEditing(_ n: Notification) {
            openedWith = nil
            guard !startedRows.isEmpty, let tv = n.object as? NSTableView else { return }
            startedRows = []
            tv.needsDisplay = true
        }

        /// Esc in a cell editor: drop what was typed and leave editing.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard sel == #selector(NSResponder.cancelOperation(_:)), let tv = control as? NSTableView, tv.editedRow >= 0 else { return false }
            tv.abortEditing()
            tv.window?.makeFirstResponder(tv)
            startedRows = []; tv.needsDisplay = true
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Rows containing every word of `filter` somewhere in their cells; nil when not filtering.
    static func matching(_ r: QueryResult, _ filter: String) -> [Int]? {
        let words = filter.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        return r.rows.indices.filter { i in
            let text = (0..<r.rows.width(i)).compactMap { r.rows.cell(i, $0)?.lowercased() }.joined(separator: "\u{1}")
            return words.allSatisfy { text.contains($0) }
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = GridTable()
        tv.isTinted = { [weak c = context.coordinator] row in c.map { $0.inEditState($0.src(row)) } ?? false }
        tv.style = .plain
        tv.focusRingType = .none // selection highlight is enough; the ring framed the whole grid
        // Content column colour (lighter than the side panels); odd rows get a faint overlay in
        // didAdd, since the system alternating colours are the darker text background.
        tv.backgroundColor = .windowBackgroundColor
        tv.usesAlternatingRowBackgroundColors = false
        tv.gridStyleMask = .solidVerticalGridLineMask
        tv.columnAutoresizingStyle = .noColumnAutoresizing
        tv.allowsMultipleSelection = true
        tv.allowsColumnSelection = false // a header click sorts instead
        tv.rowHeight = Prefs.gridFontSize + 6
        tv.dataSource = context.coordinator
        tv.delegate = context.coordinator
        tv.target = context.coordinator
        tv.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let copyMenu = NSMenu()
        copyMenu.delegate = context.coordinator
        tv.menu = copyMenu
        context.coordinator.table = tv
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
        c.onFollow = onFollow
        c.onDeleteRows = onDeleteRows
        c.onSelectRows = onSelectRows
        c.onSort = onSort
        guard let tv = sv.documentView as? NSTableView else { return }
        defer { // after columns are rebuilt for a new result
            for col in tv.tableColumns {
                let on = sortOrder.map { String($0.column) == col.identifier.rawValue } ?? false
                let image = on ? NSImage(named: sortOrder!.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") : nil
                if tv.indicatorImage(in: col) != image { tv.setIndicatorImage(image, in: col) }
            }
        }
        if c.links != links { c.links = links; tv.reloadData() } // keys arrive with the first browse
        let font = Prefs.mono(Prefs.gridFontSize)
        if c.font != font { // font or size changed in Settings
            c.font = font
            tv.rowHeight = font.pointSize + 6
            for col in tv.tableColumns { (col.dataCell as? NSCell)?.font = font }
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
        let shownColumns = result.columns.indices.filter { !hiddenColumns.contains($0) }
        if tv.tableColumns.map(\.title) != shownColumns.map({ result.columns[$0] }) {
            // Empty the table before touching columns: AppKit redraws visible rows while
            // columns change, and must not see old row indexes against the new data.
            c.result = QueryResult()
            tv.reloadData()
            tv.tableColumns.forEach(tv.removeTableColumn)
            let charWidth = ("0" as NSString).size(withAttributes: [.font: c.font]).width
            for i in shownColumns {
                let name = result.columns[i]
                let col = NSTableColumn(identifier: .init(String(i)))
                col.title = name
                col.isEditable = true // gated by shouldEdit
                let cell = GridCell()
                cell.isEditable = true // NSCell defaults to non-editable; shouldEdit still gates it
                cell.font = c.font
                cell.lineBreakMode = .byTruncatingTail
                cell.truncatesLastVisibleLine = true
                col.dataCell = cell
                col.headerCell.alignment = .center
                // Fits the wider of the header (its own font, room for the sort arrow) and the first rows
                // (monospaced: longest value × one character's width).
                let chars = (0..<min(50, result.rows.count)).map { result.rows.cell($0, i)?.count ?? 4 }.max() ?? 0
                let header = (name as NSString).size(withAttributes: [.font: col.headerCell.font ?? .systemFont(ofSize: 11)]).width + 22
                let content = CGFloat(chars) * charWidth + 10 + (menuForCell(0, i) != nil || links.contains(i) ? GridCell.indicatorWidth : 0)
                col.width = min(400, max(36, header, content))
                tv.addTableColumn(col)
            }
        }
        let keptRow = keepPosition && tv.selectedRow >= 0 ? tv.selectedRow : nil
        let keptScroll = sv.contentView.bounds.origin
        c.result = result
        c.filter = filter
        c.visible = Self.matching(result, filter)
        tv.reloadData()
        if keepPosition {
            if let keptRow, keptRow < tv.numberOfRows { tv.selectRowIndexes([keptRow], byExtendingSelection: false) }
            sv.contentView.scroll(to: keptScroll); sv.reflectScrolledClipView(sv.contentView)
            return
        }
        tv.scrollRowToVisible(0)
    }
}
