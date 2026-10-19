import SwiftUI

struct DiagramTableInfo: View {
    let name: String
    var session: Session?
    let load: (String) async -> QueryResult?
    @Binding var draft: TableDraft
    let action: (TableAction) -> Void
    @State private var result: QueryResult?        // structure as loaded
    @State private var indexes: QueryResult?
    @State private var structureGrid: QueryResult?  // + placeholder rows for new columns
    @State private var indexGrid: QueryResult?
    @State private var row: Int?
    @State private var indexRow: Int?
    @State private var showIndexes = false
    @State private var editRequest: GridEditRequest?
    @State private var pending: (title: String, sql: [String])?
    @State private var error: String?
    @State private var running = false

    private var kind: Conn.Kind { session?.conn.kind ?? .postgres }
    private func col(_ r: QueryResult?, _ n: String) -> Int? { r?.columns.firstIndex { $0.lowercased() == n } }
    private var baseColumns: Int { result?.rows.count ?? 0 }
    private var baseIndexes: Int { indexes?.rows.count ?? 0 }
    private var newTypeName: String { kind == .sqlite ? "TEXT" : "varchar" }

    private func column(_ r: Int) -> ColumnDef? {
        guard let result, result.rows.indices.contains(r) else { return nil }
        return ColumnDef(row: result.rows[r], header: result.columns)
    }

    // MARK: Staged SQL

    /// Existing columns changed in the grid, then new columns (rows without a name are left out).
    private var columnSQL: [String] {
        guard let session, let result else { return [] }
        let table = session.quoteTable(name)
        let (nc, tc, nullc, dc) = (col(result, "column_name"), col(result, "data_type"), col(result, "is_nullable"), col(result, "column_default"))
        func value(_ r: Int, _ c: Int?) -> String?? { c.flatMap { draft.columnEdits[r]?[$0] } }
        return draft.columnEdits.keys.filter { $0 < baseColumns }.sorted().flatMap { r -> [String] in
            guard let old = column(r) else { return [] }
            var new = old
            if let n = value(r, nc) ?? nil, !n.isEmpty { new.name = n }
            if let t = value(r, tc) ?? nil, let tc, t != result.rows[r][tc] { new.type = ColumnType.resolved(t, previous: old.type, kind: kind) }
            if let n = value(r, nullc) ?? nil { new.nullable = n != "NO" }
            if let d = value(r, dc) { new.defaultSQL = d ?? "" }
            return Session.alterColumnSQL(kind, table: table, from: old, to: new)
        } + (0..<draft.newColumns).compactMap { i -> String? in
            let r = baseColumns + i
            guard let n = value(r, nc) ?? nil, !n.isEmpty else { return nil }
            let def = ColumnDef(name: n, type: ColumnType.resolved((value(r, tc) ?? nil) ?? newTypeName, previous: "", kind: kind),
                                nullable: ((value(r, nullc) ?? nil) ?? "YES") != "NO", defaultSQL: (value(r, dc) ?? nil) ?? "")
            return Session.addColumnSQL(kind, table: table, column: def)
        }
    }

    private var indexSQL: [String] {
        guard let session else { return [] }
        let (nc, ac, uc, cc) = (col(indexes, "index_name"), col(indexes, "index_algorithm"), col(indexes, "is_unique"), col(indexes, "columns"))
        func value(_ r: Int, _ c: Int?) -> String? { c.flatMap { draft.indexEdits[r]?[$0] ?? nil } }
        return (0..<draft.newIndexes).compactMap { i -> String? in
            let r = baseIndexes + i
            let columns = (value(r, cc) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let n = value(r, nc), !n.isEmpty, !columns.isEmpty else { return nil }
            return Session.createIndexSQL(kind, table: session.quoteTable(name), name: n, columns: columns,
                                          unique: value(r, uc) == "TRUE", algorithm: value(r, ac) ?? "BTREE")
        }
    }

    private var incomplete: Bool {
        let missingColumn = (0..<draft.newColumns).contains { i in
            (col(result, "column_name").flatMap { draft.columnEdits[baseColumns + i]?[$0] ?? nil } ?? "").isEmpty
        }
        let missingIndex = (0..<draft.newIndexes).contains { i in
            let r = baseIndexes + i
            return (col(indexes, "index_name").flatMap { draft.indexEdits[r]?[$0] ?? nil } ?? "").isEmpty
                || (col(indexes, "columns").flatMap { draft.indexEdits[r]?[$0] ?? nil } ?? "").isEmpty
        }
        return missingColumn || missingIndex
    }

    // MARK: View

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Name") { Text(name).textSelection(.enabled).fontWeight(.medium) }
            Picker("View", selection: $showIndexes) {
                Text("Structure").tag(false)
                Text("Index").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().frame(maxWidth: .infinity)
            .onChange(of: showIndexes) { _, on in if on, indexes == nil { Task { await loadIndexes() } } }
            Group {
                if showIndexes { indexGridView } else { structureGridView }
            }
            .frame(minHeight: 180, maxHeight: .infinity) // fills the panel's height
            .clipShape(RoundedRectangle(cornerRadius: 6))
            if session != nil {
                HStack(spacing: 6) {
                    Button { showIndexes ? addIndex() : addColumn() } label: { Image(systemName: "plus").frame(width: 14) }
                        .help(showIndexes ? "Add an index" : "Add a column")
                        .disabled(showIndexes && kind == .redis)
                    Button { showIndexes ? removeIndex() : removeColumn() } label: { Image(systemName: "minus").frame(width: 14) }
                        .help(showIndexes ? "Delete the selected index" : "Delete the selected column")
                        .disabled((showIndexes ? indexRow : row) == nil)
                    if !showIndexes {
                    }
                    Text(showIndexes ? "New index: name it, then pick its columns"
                                     : "Double-click a cell to edit it")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !draft.isEmpty {
                    // Two lines so it fits the narrowest panel.
                    let count = draft.columnEdits.keys.filter { $0 < baseColumns }.count + draft.newColumns + draft.newIndexes
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(count) unsaved change\(count == 1 ? "" : "s")"
                             + (incomplete ? " · new rows need a name\(showIndexes ? " and columns" : "")" : ""))
                            .font(.callout).foregroundStyle(incomplete ? .orange : .secondary)
                        HStack {
                            Spacer()
                            Button("Discard") { discard() }
                            Button("Save…") { pending = ("Save changes to \(name)?", columnSQL + indexSQL) }
                                .keyboardShortcut("s", modifiers: .command)
                                .disabled((columnSQL + indexSQL).isEmpty || incomplete)
                        }
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).lineLimit(6) }
            Divider()
            HStack {
                Button("Open Data") { action(.openNewTab) }
                Spacer()
                Menu {
                    Button("Open Structure") { action(.structure) }
                    Divider()
                    Button("Delete Table…", role: .destructive) { action(.delete) }
                } label: { FieldIcon(name: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More table actions")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .disabled(running)
        .task { await reload() }
        // With the form open, selecting another existing row edits that column instead.
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            if let p = pending { Button(p.title.hasPrefix("Delete") ? "Delete" : "Save", role: .destructive) { apply(p.sql) } }
        } message: {
            if let p = pending { Text(p.sql.joined(separator: ";\n") + ";") }
        }
    }

    @ViewBuilder private var structureGridView: some View {
        if let structureGrid, let result {
            let (nc, tc, nullc, dc) = (col(result, "column_name"), col(result, "data_type"), col(result, "is_nullable"), col(result, "column_default"))
            ResultGrid(result: structureGrid, selection: $row, edits: draft.columnEdits, editable: session != nil,
                       onEdit: { r, c, v in
                           draft.columnEdits[r, default: [:]][c] = v
                           // full_type follows a picked type, so the row reads like the loaded ones.
                           if c == tc, let v, let fc = col(result, "full_type") {
                               draft.columnEdits[r, default: [:]][fc] = ColumnType.fullName(ColumnType.resolved(v, previous: column(r)?.type ?? "", kind: kind), kind: kind)
                           }
                       },
                       editableCell: { r, c in
                           c == nc || ((r >= baseColumns || kind != .sqlite) && c == dc)
                       },
                       editRequest: showIndexes ? nil : editRequest,
                       menuForCell: { r, c in
                           let changeable = r >= baseColumns || kind != .sqlite
                           if c == tc, changeable { return ColumnType.names(kind) }
                           if c == nullc, changeable { return ["YES", "NO"] }
                           return nil
                       },
                       editsOnSingleClick: { r in r >= baseColumns || draft.columnEdits[r] != nil },
                       hiddenColumns: col(result, "#").map { [$0] } ?? []) // the position adds nothing in a narrow panel
        } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    @ViewBuilder private var indexGridView: some View {
        if let indexGrid, let indexes {
            let (nc, ac, uc, cc) = (col(indexes, "index_name"), col(indexes, "index_algorithm"), col(indexes, "is_unique"), col(indexes, "columns"))
            ResultGrid(result: indexGrid, selection: $indexRow, edits: draft.indexEdits, editable: session != nil,
                       onEdit: { r, c, v in
                           if c == cc, let v {  // toggle the picked column in the list, keeping pick order
                               var list = (draft.indexEdits[r]?[c] ?? nil).map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } ?? []
                               if let i = list.firstIndex(of: v) { list.remove(at: i) } else { list.append(v) }
                               draft.indexEdits[r, default: [:]][c] = list.joined(separator: ", ")
                           } else { draft.indexEdits[r, default: [:]][c] = v }
                       },
                       editableCell: { r, c in r >= baseIndexes && c == nc },
                       editRequest: showIndexes ? editRequest : nil,
                       menuForCell: { r, c in
                           guard r >= baseIndexes else { return nil }
                           if c == ac, kind != .sqlite { return Session.indexAlgorithms(kind) }
                           if c == uc { return ["FALSE", "TRUE"] }
                           if c == cc, let result, let n = col(result, "column_name") { return result.rows.compactMap { $0[n] } }
                           return nil
                       },
                       isMultiMenu: { _, c in c == cc },
                       editsOnSingleClick: { r in r >= baseIndexes })
        } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private var confirmTitle: String {
        guard let p = pending else { return "" }
        return p.title + (session?.conn.isProd == true ? " (production: \(session!.conn.name))" : "")
    }

    // MARK: Rows

    /// Loaded rows plus one placeholder per new row (`template` keyed by lowercased column name).
    private static func padded(_ base: QueryResult, extra: Int, template: [String: String?]) -> QueryResult {
        var r = base
        r.rows += Array(repeating: base.columns.map { template[$0.lowercased()] ?? "" }, count: extra)
        r.id = UUID()
        return r
    }

    private func rebuildGrids() {
        if let result {
            structureGrid = Self.padded(result, extra: draft.newColumns, template: [
                "#": "+", "column_name": "", "data_type": newTypeName,
                "full_type": ColumnType.fullName(ColumnType.resolved(newTypeName, previous: "", kind: kind), kind: kind), "is_nullable": "YES",
                "column_default": String?.none, "primary_key": ""] as [String: String?])
        }
        if let indexes {
            indexGrid = Self.padded(indexes, extra: draft.newIndexes, template: [
                "index_name": "", "index_algorithm": "BTREE", "is_unique": "FALSE", "is_primary": "FALSE",
                "columns": "", "definition": ""])
        }
    }

    private func addColumn() {
        draft.newColumns += 1
        rebuildGrids()
        let r = baseColumns + draft.newColumns - 1
        row = r
        if let nc = col(result, "column_name") { editRequest = GridEditRequest(row: r, column: nc) }
    }

    private func addIndex() {
        draft.newIndexes += 1
        rebuildGrids()
        let r = baseIndexes + draft.newIndexes - 1
        indexRow = r
        if let nc = col(indexes, "index_name") { editRequest = GridEditRequest(row: r, column: nc) }
    }

    /// Drops a staged row and shifts the edits of the rows after it.
    private static func removing(_ r: Int, from edits: [Int: [Int: String?]]) -> [Int: [Int: String?]] {
        Dictionary(uniqueKeysWithValues: edits.compactMap { k, v in k == r ? nil : (k > r ? k - 1 : k, v) })
    }

    private func removeColumn() {
        guard let r = row, let s = session else { return }
        if r >= baseColumns {
            draft.columnEdits = Self.removing(r, from: draft.columnEdits); draft.newColumns -= 1; row = nil; rebuildGrids()
        } else if let c = column(r) {
            pending = ("Delete column \(c.name) from \(name)?", [Session.dropColumnSQL(kind, table: s.quoteTable(name), column: c.name)])
        }
    }

    private func removeIndex() {
        guard let r = indexRow, let s = session, let indexes else { return }
        if r >= baseIndexes {
            draft.indexEdits = Self.removing(r, from: draft.indexEdits); draft.newIndexes -= 1; indexRow = nil; rebuildGrids()
        } else if let nc = col(indexes, "index_name"), let idx = indexes.rows[r][nc] {
            let primary = col(indexes, "is_primary").map { indexes.rows[r][$0] == "TRUE" } ?? false
            pending = ("Delete index \(idx) of \(name)?",
                       Session.dropIndexSQL(kind, table: s.quoteTable(name), schema: s.schemaOf(name), name: idx, primary: primary))
        }
    }

    private func discard() {
        draft = TableDraft(table: draft.table)
        row = nil; indexRow = nil
        rebuildGrids()
    }

    private func reload() async {
        result = await load(name) ?? QueryResult(message: "Couldn't load the structure")
        if showIndexes || indexes != nil { await loadIndexes() } else { rebuildGrids() }
    }

    private func loadIndexes() async {
        if let session {
            do { indexes = try await session.onQueue { [name] in try $0.indexes(name) } }
            catch { self.error = error.localizedDescription; indexes = QueryResult() }
        } else { indexes = QueryResult() }
        rebuildGrids()
    }

    private func apply(_ statements: [String]) {
        guard let session else { return }
        pending = nil; running = true; error = nil
        Task {
            do {
                for s in statements { _ = try await session.onQueue { try $0.query(s) } }
                draft = TableDraft(table: draft.table); row = nil; indexRow = nil
                indexes = nil
                await reload()
                if case .diagram(let focus) = session.kind { session.showDiagram(focus) } // boxes show the new columns
            } catch { self.error = error.localizedDescription }
            running = false
        }
    }
}
