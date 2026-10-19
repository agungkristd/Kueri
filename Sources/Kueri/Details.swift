import SwiftUI

/// Re-indents JSON text without re-parsing into dictionaries, so key order is kept.
/// Returns nil when the value isn't a JSON object/array.
func prettyJSON(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let f = t.first, f == "{" || f == "[",
          (try? JSONSerialization.jsonObject(with: Data(t.utf8), options: [.fragmentsAllowed])) != nil else { return nil }
    var out = "", depth = 0, inString = false, escaped = false
    func newline() { out += "\n" + String(repeating: "  ", count: depth) }
    for c in t {
        if inString {
            out.append(c)
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            continue
        }
        switch c {
        case "\"": inString = true; out.append(c)
        case "{", "[": out.append(c); depth += 1; newline()
        case "}", "]":
            depth -= 1
            while out.last?.isWhitespace == true { out.removeLast() }
            if out.last != "{" && out.last != "[" { newline() } // keep empty containers as {} / []
            out.append(c)
        case ",": out.append(c); newline()
        case ":": out += ": "
        case " ", "\n", "\t", "\r": continue
        default: out.append(c)
        }
    }
    return out
}

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

func markMatches(_ s: AttributedString, _ query: String) -> AttributedString {
    guard !query.isEmpty else { return s }
    var out = s
    var from = out.startIndex
    while from < out.endIndex, let r = out[from...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
        out[r].backgroundColor = .yellow.opacity(0.45)
        out[r].foregroundColor = .primary
        from = r.upperBound
    }
    return out
}

/// Colors formatted JSON (keys, strings, numbers, literals). Characters are never added or
/// removed, only attributed. Very large values are returned plain to keep the panel light.
func highlightJSON(_ s: String) -> AttributedString {
    var out = AttributedString(s)
    guard s.utf8.count <= 200_000 else { return out }
    let chars = Array(s)
    var idx = out.startIndex
    var i = 0
    func color(_ n: Int, _ c: Color) {
        let end = out.index(idx, offsetByCharacters: n)
        out[idx..<end].foregroundColor = c
        idx = end; i += n
    }
    while i < chars.count {
        let c = chars[i]
        if c == "\"" {
            var j = i + 1, esc = false
            while j < chars.count { if esc { esc = false } else if chars[j] == "\\" { esc = true } else if chars[j] == "\"" { break }; j += 1 }
            let len = min(j + 1, chars.count) - i
            var k = i + len
            while k < chars.count, chars[k] == " " { k += 1 }
            color(len, k < chars.count && chars[k] == ":" ? .teal : .green) // key vs string value
        } else if c == "-" || c.isNumber {
            var j = i; while j < chars.count, "-+.eE0123456789".contains(chars[j]) { j += 1 }
            color(j - i, .orange)
        } else if let lit = ["true", "false", "null"].first(where: { String(chars[i..<min(i + $0.count, chars.count)]) == $0 }) {
            color(lit.count, .pink)
        } else if "{}[],:".contains(c) {
            color(1, .secondary)
        } else {
            idx = out.index(afterCharacter: idx); i += 1
        }
    }
    return out
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}


/// A field control's icon: same symbol size, weight, colour and box for every button in the row.
struct FieldIcon: View {
    let name: String
    var body: some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }
}
