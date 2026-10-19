import SwiftUI

/// Inspector for the selected row: field, type, value (JSON pretty-printed).
/// Fields are edited in place; edits are shared with the grid and saved from the Save bar (⌘S).
struct RowDetails: View {
    let result: QueryResult
    let row: Int?
    var readOnlyReason: String?
    @Binding var edits: [Int: String?] // column → new value (nil = NULL), for the selected row

    @State private var search = ""
    @State private var expanded: Set<Int> = []
    @State private var rawEditing: Set<Int> = [] // JSON fields switched to their raw, editable text
    @State private var copied: Int?               // field whose value was just copied (brief checkmark)

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
        .onChange(of: row) { expanded = []; rawEditing = [] }
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
        // JSON shows formatted until the user asks to edit; editing always works on the raw value,
        // so saving never re-indents or reformats what's stored.
        let jsonView = json != nil && !changed && !rawEditing.contains(i)
        let text = jsonView ? json! : (current ?? "")
        // While searching, show matching values in full so the hit isn't hidden below the fold.
        let open = expanded.contains(i) || (!search.isEmpty && text.localizedCaseInsensitiveContains(search))
        let multiline = text.contains("\n") || text.count > 40
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(marked(AttributedString(result.columns[i]))).font(.callout)
                if changed { Circle().fill(.orange).frame(width: 6, height: 6).help("Edited") }
                Spacer()
                Text(json != nil && (result.types[safe: i] ?? "").isEmpty ? "json" : result.types[safe: i] ?? "")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 6) {
                if jsonView {
                    // No wrapping: long tokens scroll sideways so the structure stays readable.
                    ScrollView(.horizontal) {
                        Text(marked(highlightJSON(json!)))
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(open ? nil : 8)
                            .fixedSize(horizontal: true, vertical: false)
                            .textSelection(.enabled)
                            .padding(.bottom, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                        .lineLimit(open ? 1...200 : 1...(json != nil ? 8 : 3))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(isNull ? AttributedString("NULL") : marked(AttributedString(text)))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(isNull ? .tertiary : .primary)
                        .lineLimit(open ? nil : 2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // One row of same-sized plain icons: menu, edit JSON, copy, expand.
                HStack(spacing: 2) {
                    if editable && !jsonView {
                        Menu {
                            Button("Set NULL") { edits[i] = .some(nil) }.disabled(isNull)
                            Button("Set empty string") { edits[i] = .some("") }
                            if changed || rawEditing.contains(i) {
                                Button("Revert") { edits.removeValue(forKey: i); rawEditing.remove(i) }
                            }
                        } label: { FieldIcon(name: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("NULL / revert")
                    }
                    if editable && jsonView {
                        Button { rawEditing.insert(i) } label: { FieldIcon(name: "pencil") }
                            .buttonStyle(.borderless).help("Edit raw JSON (exactly as stored)")
                    }
                    // Copies the value as stored (raw JSON, not the formatted view).
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(current ?? "", forType: .string)
                        copied = i
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == i { copied = nil } }
                    } label: { FieldIcon(name: copied == i ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help(isNull ? "Copy (NULL copies nothing)" : "Copy value")
                    if multiline {
                        Button { if open { expanded.remove(i) } else { expanded.insert(i) } } label: {
                            FieldIcon(name: open ? "chevron.up" : "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .help(open ? "Collapse" : "Expand")
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(changed ? AnyShapeStyle(.orange) : AnyShapeStyle(.quaternary)))
        }
    }
}

extension RowDetails {
    /// Yellow background on every case-insensitive occurrence of the search text.
    func marked(_ s: AttributedString) -> AttributedString { markMatches(s, search) }
}
