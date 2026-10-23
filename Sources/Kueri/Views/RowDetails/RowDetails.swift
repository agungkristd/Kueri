import SwiftUI

/// Inspector for the selected row: field, type, value (JSON pretty-printed).
/// Fields are edited in place; edits are shared with the grid and saved from the Save bar (⌘S).
struct RowDetails: View {
    let result: QueryResult
    let row: Int?
    var readOnlyReason: String?
    @Binding var edits: [Int: String?] // column → new value (nil = NULL), for the selected row
    var enumValues: [String: [String]] = [:] // by column name: edited with a picker instead of text

    @State private var search = ""
    @State private var expanded: Set<Int> = []
    @State private var clippedJSON: Set<Int> = [] // JSON fields whose 8-line view hides wrapped lines (reported by the view)
    @State private var copied: Int?               // field whose value was just copied (brief checkmark)
    @State private var fieldWidths: [Int: CGFloat] = [:] // each field's text width, for wrapped-line counts

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search fields and values…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            if let row, row < result.rows.count {
                if let readOnlyReason {
                    Text(readOnlyReason).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.bottom, 8)
                }
                ScrollView {
                    // Padding inside the scroll content so the scroller never overlaps the fields.
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(fields(row), id: \.self) { i in field(i, result.rows[row][i]) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
            } else {
                ContentUnavailableView("No row selected", systemImage: "sidebar.right",
                                       description: Text("Select a row to see its fields."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // clippedJSON is not reset here: the JSON view only reports a change, so a field that stays
        // clipped on the next row would never be reported again and the button would vanish.
        .onChange(of: row) { expanded = [] }
    }

    /// Fields whose name or value contains the search text.
    private func fields(_ row: Int) -> [Int] {
        guard !search.isEmpty else { return Array(result.columns.indices) }
        return result.columns.indices.filter {
            result.columns[$0].localizedCaseInsensitiveContains(search)
                || (result.rows[row][$0]?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    @ViewBuilder private func field(_ i: Int, _ value: String?) -> some View {
        let json = value.flatMap(prettyJSON)   // display only: never written back
        let changed = edits[i] != nil
        let current = changed ? edits[i]! : value
        let isNull = current == nil
        let editable = readOnlyReason == nil
        // JSON shows formatted and is edited as shown; nothing is written unless the text changes
        // (or Pretty / Minify is chosen). Stays in the JSON editor while an edit is half-typed.
        let jsonView = json != nil && current != nil
        let text = jsonView ? (changed ? current! : json!) : (current ?? "")
        // While searching, show matching values in full so the hit isn't hidden below the fold.
        let open = expanded.contains(i) || (!search.isEmpty && text.localizedCaseInsensitiveContains(search))
        let multiline = text.contains("\n") || text.count > 40
        let options = editable && !jsonView ? choices(i) : nil
        let clipped = Self.clipped(text, jsonView: jsonView, editable: editable, width: fieldWidths[i] ?? 0)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(marked(AttributedString(result.columns[i]))).font(.callout)
                if changed { Circle().fill(.orange).frame(width: 6, height: 6).help("Edited") }
                Spacer()
                Text(json != nil && (result.types[safe: i] ?? "").isEmpty ? "json" : result.types[safe: i] ?? "")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let options {
                // A stored value outside the list (e.g. a label renamed since) stays selectable.
                let all = options + (current.map { options.contains($0) ? [] : [$0] } ?? [])
                MenuButton(font: JSONTextView.font) {
                    all.map { v in MenuEntry.item(choiceLabel(v, i), checked: v == current) { pick(i, v, stored: value) } }
                        + [.separator, .item("NULL", checked: current == nil) { pick(i, nil, stored: value) }]
                } label: {
                    // Same box as the text fields, so the form reads as one column.
                    HStack(spacing: 4) {
                        Text(current.map { choiceLabel($0, i) } ?? "NULL").foregroundStyle(current == nil ? .tertiary : .primary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(changed ? AnyShapeStyle(.orange) : AnyShapeStyle(.quaternary)))
                    .contentShape(Rectangle())
                }
            } else {
              VStack(alignment: .leading, spacing: 4) {
                Group {
                    if jsonView {
                        JSONTextView(text: text, editable: editable, search: search, maxLines: open ? nil : 8, onChange: { new in
                            // Back to the formatted original (or the stored text) counts as unchanged.
                            if new == json || new == value { edits.removeValue(forKey: i) } else { edits[i] = .some(new) }
                        }, onClipped: { c in if c != clippedJSON.contains(i) { if c { clippedJSON.insert(i) } else { clippedJSON.remove(i) } } })
                    } else if editable {
                        TextField(isNull ? "NULL" : "", text: Binding(
                            get: { current ?? "" },
                            set: { new in
                                // Compared with the raw stored value; typing into NULL makes it a value.
                                if new == (value ?? "") && !(value == nil && !new.isEmpty) { edits.removeValue(forKey: i) }
                                else { edits[i] = .some(new) }
                            }), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(open ? 1...200 : 1...3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onExitCommand { NSApp.keyWindow?.makeFirstResponder(nil) } // Esc ends editing
                    } else {
                        Text(isNull ? AttributedString("NULL") : marked(AttributedString(text)))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(isNull ? .tertiary : .primary)
                            .lineLimit(open ? nil : 2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // The text's real width (an estimate from the panel width was a few points off and
                // counted a line that wasn't there).
                .background(GeometryReader { g in
                    Color.clear.onAppear { fieldWidths[i] = g.size.width }
                        .onChange(of: g.size.width) { if fieldWidths[i] != $1 { fieldWidths[i] = $1 } }
                })
                .padding(.trailing, 18) // room for the menu
                .overlay(alignment: .topTrailing) {
                    fieldMenu(i, value: current, reformat: jsonView, isNull: isNull, editable: editable, jsonView: jsonView, multiline: multiline, open: open, changed: changed)
                }
                // One click to see the whole value; Expand in the menu was two clicks and easy to miss.
                if !isNull, open || clipped || (jsonView && clippedJSON.contains(i)) {
                    Button { if open { expanded.remove(i) } else { expanded.insert(i) } } label: {
                        Label(open ? "Show less" : "Show all", systemImage: open ? "chevron.up" : "chevron.down")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
              }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(changed ? AnyShapeStyle(.orange) : AnyShapeStyle(.quaternary)))
            }
        }
    }
}

/// One entry of a menu opened from a Details button (no title: a separator).
struct MenuEntry {
    var title: String?
    var enabled = true, checked = false
    var run: () -> Void = {}
    static let separator = MenuEntry()
    static func item(_ title: String, enabled: Bool = true, checked: Bool = false, _ run: @escaping () -> Void) -> MenuEntry {
        MenuEntry(title: title, enabled: enabled, checked: checked, run: run)
    }
}

/// Opens an AppKit menu, built only when clicked: a SwiftUI Menu or Picker keeps a pop-up button
/// per field, and SwiftUI kept updating those (with their accessibility) without end, freezing
/// the app at full CPU. Over `view` it opens like a pop-up button (as wide as it, the checked
/// item on top of it); otherwise at the pointer.
@MainActor func popUpMenu(_ entries: [MenuEntry], from view: NSView? = nil, font: NSFont? = nil) {
    let menu = NSMenu()
    menu.autoenablesItems = false
    if let font { menu.font = font }
    for e in entries {
        guard let title = e.title else { menu.addItem(.separator()); continue }
        let m = ClosureMenuItem(title, e.run)
        m.isEnabled = e.enabled; m.state = e.checked ? .on : .off
        menu.addItem(m)
    }
    guard let view, view.window != nil else { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil); return }
    menu.minimumWidth = view.bounds.width
    let checked = menu.items.first { $0.state == .on }
    let top = view.isFlipped ? 0 : view.bounds.height, bottom = view.bounds.height - top
    menu.popUp(positioning: checked, at: NSPoint(x: 0, y: checked == nil ? bottom : top), in: view)
}

/// A button whose menu opens from it like a pop-up button, without being one (see popUpMenu).
struct MenuButton<Label: View>: View {
    var font: NSFont?
    let entries: () -> [MenuEntry]
    @ViewBuilder let label: () -> Label
    @State private var anchor = Anchor()

    final class Anchor { weak var view: NSView? }
    struct AnchorView: NSViewRepresentable {
        let anchor: Anchor
        func makeNSView(context: Context) -> NSView { let v = NSView(); anchor.view = v; return v }
        func updateNSView(_ v: NSView, context: Context) { anchor.view = v }
    }

    var body: some View {
        Button { popUpMenu(entries(), from: anchor.view, font: font) } label: { label() }
            .buttonStyle(.plain)
            .background(AnchorView(anchor: anchor))
    }
}

extension RowDetails {
    /// The values a column can take, when it's an enum or a (Postgres) boolean.
    func choices(_ i: Int) -> [String]? {
        if let v = enumValues[result.columns[i]] { return v }
        return ["bool", "boolean"].contains(result.types[safe: i] ?? "") ? ["t", "f"] : nil
    }

    func choiceLabel(_ v: String, _ i: Int) -> String {
        ["bool", "boolean"].contains(result.types[safe: i] ?? "") ? (v == "t" ? "TRUE" : v == "f" ? "FALSE" : v) : v
    }

    /// Everything a field can do, behind one chevron in the corner of its box, so the
    /// value keeps the full width.
    func fieldMenu(_ i: Int, value: String?, reformat: Bool, isNull: Bool, editable: Bool, jsonView: Bool, multiline: Bool, open: Bool, changed: Bool) -> some View {
        Button {
            // Copies the value as stored (raw JSON, not the formatted view).
            var items: [MenuEntry] = [.item(isNull ? "Copy (NULL copies nothing)" : "Copy Value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value ?? "", forType: .string)
                copied = i
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == i { copied = nil } }
            }]
            if multiline { items.append(.item(open ? "Collapse" : "Expand") { if open { expanded.remove(i) } else { expanded.insert(i) } }) }
            if editable {
                items.append(.separator)
                // Rewrites the value; for jsonb the server keeps its own layout once saved.
                if reformat, let v = value {
                    items.append(.item("Pretty") { if let p = prettyJSON(v) { setReformatted(i, p) } })
                    items.append(.item("Minify") { if let m = minifyJSON(v) { setReformatted(i, m) } })
                }
                items.append(.item("Set NULL", enabled: !isNull) { edits[i] = .some(nil) })
                items.append(.item("Set Empty String") { edits[i] = .some("") })
                if changed { items.append(.item("Revert") { edits.removeValue(forKey: i) }) }
            }
            popUpMenu(items)
        } label: { FieldIcon(name: copied == i ? "checkmark" : "chevron.down") }
        .buttonStyle(.plain)
        .help("Copy, expand, set NULL…")
    }

    /// Does the closed view cut the value off? Lines beyond that view's cap (JSON 8, field 3, text 2)
    /// once wrapped at `width` (the user's values were one long line that wrapped past the cap).
    /// Texts over 160 characters always count as clipped, so only short ones are ever measured.
    nonisolated static func clipped(_ text: String, jsonView: Bool, editable: Bool, width: CGFloat = 0) -> Bool {
        let cap = jsonView ? 8 : editable ? 3 : 2
        if text.count > 160 || text.reduce(1, { $0 + ($1 == "\n" ? 1 : 0) }) > cap { return true }
        guard width > 20 else { return false }
        let font = JSONTextView.font
        let h = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
        // One line measured the same way: the layout's line height is rounded, the font metrics aren't.
        let line = ("x" as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
        return h > (CGFloat(cap) + 0.5) * line // half a line of slack: layout engines round differently
    }

    func pick(_ i: Int, _ new: String?, stored: String?) {
        if new == stored { edits.removeValue(forKey: i) } else { edits[i] = .some(new) }
    }

    /// A reformatted JSON value; back to unchanged when it matches what's stored (or how it's shown).
    func setReformatted(_ i: Int, _ text: String) {
        let stored = row.flatMap { result.rows[$0][i] }
        if text == stored || text == stored.flatMap(prettyJSON) { edits.removeValue(forKey: i) } else { edits[i] = .some(text) }
    }

    /// Yellow background on every case-insensitive occurrence of the search text.
    func marked(_ s: AttributedString) -> AttributedString { markMatches(s, search) }
}
