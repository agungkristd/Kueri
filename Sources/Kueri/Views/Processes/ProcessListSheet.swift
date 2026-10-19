import SwiftUI

struct ProcessListSheet: View {
    let session: Session
    let done: () -> Void
    @State private var rows: [ServerProcess] = []
    @State private var picked: ServerProcess.ID?
    @State private var search = ""
    @State private var hideIdle = false
    @State private var auto = true
    @State private var error: String?
    @State private var loading = false
    @State private var confirm: (ServerProcess, queryOnly: Bool)?

    private var canCancelQuery: Bool { session.conn.kind != .redis }
    private var shown: [ServerProcess] {
        rows.filter { p in
            (!hideIdle || !(p.state.hasPrefix("idle") || p.state.hasPrefix("Sleep")) || p.isOwn)
                && (search.isEmpty || [p.id, p.user, p.database, p.client, p.query].contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }
    private var selected: ServerProcess? { rows.first { $0.id == picked } }
    /// Rows for the grid; rebuilt only when what it shows changes.
    @State private var grid = QueryResult()
    private func rebuildGrid() {
        let r = shown.map { p -> [String?] in
            [p.id, p.user, p.database, p.isOwn ? "\(p.client) (Kueri, this tab)" : p.client, p.state, p.duration, p.query]
        }
        guard !(grid.rows == r) else { return }
        grid = QueryResult(columns: ["ID", "User", "Database", "Client", "State", "Time", "Query"], rows: r)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Server Processes").font(.headline)
                Text("\(rows.count) connection\(rows.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                Spacer()
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
                Toggle("Hide idle", isOn: $hideIdle)
                Toggle("Auto refresh", isOn: $auto).help("Refresh every 2 seconds")
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh").keyboardShortcut("r", modifiers: .command).disabled(loading)
            }
            // The app's AppKit grid: a SwiftUI Table made opening and closing this sheet sluggish.
            // Right-click copies a value or the whole row.
            ResultGrid(result: grid, selection: Binding(
                get: { shown.firstIndex { $0.id == picked } },
                set: { picked = $0.flatMap { shown.indices.contains($0) ? shown[$0].id : nil } }),
                keepPosition: true)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            if let error { Text(error).foregroundStyle(.red).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            HStack {
                if session.busy { Text("Waiting for this tab's running query to finish…").foregroundStyle(.secondary).font(.callout) }
                Spacer()
                if canCancelQuery {
                    Button("Cancel Query") { if let s = selected { confirm = (s, true) } }
                        .disabled(selected == nil || selected?.isOwn == true)
                        .help("Stop the running statement, keep the connection")
                }
                Button("Kill Connection", role: .destructive) { if let s = selected { confirm = (s, false) } }
                    .tint(.red)
                    .disabled(selected == nil || selected?.isOwn == true)
                    .help(selected?.isOwn == true ? "This is Kueri's own connection; use Disconnect instead" : "Close this client's connection")
                Button("Done", action: done).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 460)
        .onChange(of: rows) { rebuildGrid() }
        .onChange(of: search) { rebuildGrid() }
        .onChange(of: hideIdle) { rebuildGrid() }
        .task(id: auto) {
            refresh()
            while auto, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled, confirm == nil { refresh() }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            if let (p, queryOnly) = confirm {
                Button(queryOnly ? "Cancel Query" : "Kill Connection", role: .destructive) { kill(p, queryOnly: queryOnly) }
            }
        } message: {
            if let (p, _) = confirm {
                Text("\(p.user)@\(p.client)\(p.database.isEmpty ? "" : " · \(p.database)")\(p.query.isEmpty ? "" : "\n\n" + String(p.query.prefix(300)))")
            }
        }
    }

    private var confirmTitle: String {
        guard let (p, queryOnly) = confirm else { return "" }
        let on = session.conn.onProduction
        return queryOnly ? "Cancel the query of process \(p.id)\(on)?" : "Kill connection \(p.id)\(on)?"
    }

    private func refresh() {
        guard !loading else { return }
        loading = true
        Task {
            do { rows = try await session.onQueue { try $0.processes() ?? [] }; error = nil }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    private func kill(_ p: ServerProcess, queryOnly: Bool) {
        confirm = nil
        Task {
            do { try await session.onQueue { try $0.killProcess(p.id, queryOnly: queryOnly) }; error = nil }
            catch { self.error = error.localizedDescription }
            refresh()
        }
    }

}
