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
