import SwiftUI

/// One client connection on the server, normalised across drivers.
struct ServerProcess: Identifiable, Hashable {
    let id: String
    var user = "", database = "", client = "", state = "", duration = "", query = ""
    var isOwn = false
}

extension PostgresDB {
    func processes() throws -> [ServerProcess]? {
        let own = try firstColumn("SELECT pg_backend_pid()::text").first
        return try query("""
            SELECT pid::text, coalesce(usename, ''), coalesce(datname, ''),
                   coalesce(host(client_addr) || ':' || client_port, 'local'),
                   coalesce(state, '') || coalesce(' (' || wait_event_type || ': ' || wait_event || ')', ''),
                   coalesce(to_char(now() - coalesce(query_start, backend_start), 'HH24:MI:SS'), ''),
                   coalesce(query, '')
            FROM pg_stat_activity WHERE backend_type = 'client backend' ORDER BY pid
            """).rows.map { r in
            ServerProcess(id: r[0] ?? "", user: r[1] ?? "", database: r[2] ?? "", client: r[3] ?? "", state: r[4] ?? "",
                          duration: r[5] ?? "", query: r[6] ?? "", isOwn: r[0] == own)
        }
    }
    func killProcess(_ id: String, queryOnly: Bool) throws {
        guard let pid = Int(id) else { throw DBError("Invalid process id \(id)") }
        let ok = try firstColumn("SELECT \(queryOnly ? "pg_cancel_backend" : "pg_terminate_backend")(\(pid))::text").first
        if ok != "true" { throw DBError("Process \(pid) wasn't stopped (it may have ended, or you lack permission).") }
    }
}

extension MySQLDB {
    func processes() throws -> [ServerProcess]? {
        let own = try firstColumn("SELECT CONNECTION_ID()").first
        return try query("""
            SELECT ID, USER, HOST, IFNULL(DB, ''), CONCAT(COMMAND, IF(STATE IS NULL OR STATE = '', '', CONCAT(' (', STATE, ')'))),
                   SEC_TO_TIME(TIME), IFNULL(INFO, '')
            FROM information_schema.PROCESSLIST ORDER BY ID
            """).rows.map { r in
            ServerProcess(id: r[0] ?? "", user: r[1] ?? "", database: r[3] ?? "", client: r[2] ?? "", state: r[4] ?? "",
                          duration: r[5] ?? "", query: r[6] ?? "", isOwn: r[0] == own)
        }
    }
    func killProcess(_ id: String, queryOnly: Bool) throws {
        guard let n = Int(id) else { throw DBError("Invalid process id \(id)") }
        _ = try query(queryOnly ? "KILL QUERY \(n)" : "KILL \(n)")
    }
}

extension RedisDB {
    func processes() throws -> [ServerProcess]? {
        guard case .int(let own) = try command(["CLIENT", "ID"]), case .bulk(let list?) = try command(["CLIENT", "LIST"]) else { return [] }
        // "id=3 addr=127.0.0.1:50000 … name= age=12 idle=0 … db=0 … cmd=client|list user=default …"
        return list.split(whereSeparator: \.isNewline).map { line in
            var f: [Substring: Substring] = [:]
            for part in line.split(separator: " ") {
                if let eq = part.firstIndex(of: "=") { f[part[..<eq]] = part[part.index(after: eq)...] }
            }
            let id = String(f["id"] ?? "")
            return ServerProcess(id: id, user: String(f["user"] ?? ""), database: "db" + (f["db"] ?? ""),
                                 client: String(f["addr"] ?? "") + ((f["name"] ?? "").isEmpty ? "" : " (\(f["name"]!))"),
                                 state: "idle \(f["idle"] ?? "0")s", duration: "\(f["age"] ?? "0")s",
                                 query: String(f["cmd"] ?? ""), isOwn: id == String(own))
        }
    }
    func killProcess(_ id: String, queryOnly: Bool) throws {
        guard let n = Int(id) else { throw DBError("Invalid client id \(id)") }
        if case .error(let e) = try command(["CLIENT", "KILL", "ID", String(n)]) { throw DBError(e) }
    }
}

// MARK: Sheet

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
            Table(shown, selection: $picked) {
                TableColumn("ID") { p in Text(p.id).fontWeight(p.isOwn ? .semibold : .regular) }.width(min: 50, ideal: 60, max: 90)
                TableColumn("User", value: \.user).width(min: 60, ideal: 90)
                TableColumn("Database", value: \.database).width(min: 60, ideal: 110)
                TableColumn("Client") { p in Text(p.isOwn ? "\(p.client) (Kueri, this tab)" : p.client) }.width(min: 80, ideal: 150)
                TableColumn("State", value: \.state).width(min: 60, ideal: 110)
                TableColumn("Time", value: \.duration).width(min: 50, ideal: 70, max: 90)
                TableColumn("Query") { p in Text(p.query).font(.system(.body, design: .monospaced)).lineLimit(1).help(p.query) }
            }
            .contextMenu(forSelectionType: ServerProcess.ID.self) { ids in
                if let p = rows.first(where: { $0.id == ids.first }) {
                    Button("Copy Query") { copy(p.query) }.disabled(p.query.isEmpty)
                    if canCancelQuery { Button("Cancel Query…") { confirm = (p, true) }.disabled(p.isOwn) }
                    Button("Kill Connection…") { confirm = (p, false) }.disabled(p.isOwn)
                }
            }
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
        let on = session.conn.isProduction == true ? " on production \(session.conn.name)" : ""
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

    private func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
}
