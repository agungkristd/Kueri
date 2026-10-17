import Foundation

/// Redis over RESP2. The editor takes one command per line, e.g. `HGETALL user:1`.
final class RedisDB: Database {
    indirect enum Reply { case simple(String), error(String), int(Int), bulk(String?), array([Reply]?) }

    private let sock: Socket
    // Limitation: sidebar lists at most this many keys via SCAN, add a prefix filter that drives SCAN MATCH for huge keyspaces
    private let maxKeys = 2_000

    static func isLoopback(_ host: String) -> Bool {
        ["", "localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) || host.hasPrefix("127.")
    }

    /// No TLS yet, so AUTH would cross the network in clear text: it is only sent to this Mac unless
    /// `allowCleartextPassword` is set for the connection.
    init(host: String, port: String, user: String, password: String, database: String, allowCleartextPassword: Bool = false) throws {
        if !password.isEmpty, !allowCleartextPassword, !Self.isLoopback(host) {
            throw DBError("""
                Kueri can't encrypt Redis connections yet, so the password would be sent unencrypted to \(host). \
                If this server is on a network you trust, enable "Allow cleartext password" for this connection.
                """)
        }
        sock = try Socket(host: host, port: port.isEmpty ? "6379" : port)
        if !password.isEmpty { try check(command(user.isEmpty ? ["AUTH", password] : ["AUTH", user, password])) }
        if !database.isEmpty, database != "0" { try check(command(["SELECT", database])) }
        try check(command(["PING"]))
    }

    private func check(_ r: Reply) throws { if case .error(let e) = r { throw DBError(e) } }

    func command(_ args: [String]) throws -> Reply {
        var out = Array("*\(args.count)\r\n".utf8)
        for a in args {
            let b = Array(a.utf8)
            out += Array("$\(b.count)\r\n".utf8) + b + [13, 10]
        }
        try sock.write(out)
        return try readReply()
    }

    /// Limits for lengths announced by the server: a hostile or broken server must not be able to
    /// crash the app (Int overflow on `n + 2`) or exhaust memory/stack. 512 MB is Redis' own bulk limit.
    static let maxBulk = 512 * 1024 * 1024, maxElements = 10_000_000, maxDepth = 64

    /// Parses a RESP length ("$<n>" / "*<n>"); nil = null reply (-1).
    static func length(_ rest: String, max: Int) throws -> Int? {
        guard let n = Int(rest) else { throw DBError("Malformed reply length: \(rest.prefix(32))") }
        if n == -1 { return nil }
        guard (0...max).contains(n) else { throw DBError("Reply length \(n) is out of range") }
        return n
    }

    private func readReply() throws -> Reply {
        var budget = Self.maxElements
        return try readReply(depth: 0, budget: &budget)
    }

    /// `budget` counts elements across the whole reply (all nesting levels), and arrays grow only as
    /// elements actually arrive, so an announced length can't make us allocate ahead of the data.
    private func readReply(depth: Int, budget: inout Int) throws -> Reply {
        guard depth <= Self.maxDepth else { throw DBError("Reply is nested too deeply") }
        let line = try sock.readLine()
        guard let t = line.first else { throw DBError("Empty reply") }
        let rest = String(decoding: line.dropFirst(), as: UTF8.self)
        switch t {
        case UInt8(ascii: "+"): return .simple(rest)
        case UInt8(ascii: "-"): return .error(rest)
        case UInt8(ascii: ":"): return .int(Int(rest) ?? 0)
        case UInt8(ascii: "$"):
            guard let n = try Self.length(rest, max: Self.maxBulk) else { return .bulk(nil) }
            let data = try sock.read(count: n + 2)
            return .bulk(String(decoding: data.dropLast(2), as: UTF8.self))
        case UInt8(ascii: "*"):
            guard let n = try Self.length(rest, max: Self.maxElements) else { return .array(nil) }
            guard n <= budget else { throw DBError("Reply has more than \(Self.maxElements) elements") }
            budget -= n
            var items: [Reply] = []
            for _ in 0..<n { items.append(try readReply(depth: depth + 1, budget: &budget)) }
            return .array(items)
        default: throw DBError("Unknown RESP type: \(rest)")
        }
    }

    func tables() throws -> [String] {
        var keys: [String] = [], cursor = "0"
        repeat {
            guard case .array(let r?) = try command(["SCAN", cursor, "COUNT", "500"]), r.count == 2,
                  case .bulk(let c?) = r[0], case .array(let ks?) = r[1] else { break }
            cursor = c
            keys += ks.compactMap { if case .bulk(let k?) = $0 { k } else { nil } }
        } while cursor != "0" && keys.count < maxKeys
        return keys.prefix(maxKeys).sorted()
    }

    func databases() throws -> [String] {
        // CONFIG may be blocked by ACL/managed Redis; 16 is the server default.
        var n = 16
        // Only a sane value is used: a negative count would crash building 0..<n.
        if case .array(let r?) = try command(["CONFIG", "GET", "databases"]), r.count == 2,
           let v = Self.text(r[1]).flatMap(Int.init), (1...10_000).contains(v) { n = v }
        return (0..<n).map(String.init)
    }

    func browseQuery(_ key: String, offset: Int) throws -> String { // Redis: no paging, offset ignored
        let k = try Self.quote(key)
        guard case .simple(let type) = try command(["TYPE", key]) else { return "GET \(k)" }
        switch type {
        case "list": return "LRANGE \(k) 0 299"
        case "set": return "SSCAN \(k) 0 COUNT 300"
        case "zset": return "ZRANGE \(k) 0 299 WITHSCORES"
        case "hash": return "HGETALL \(k)"
        case "stream": return "XRANGE \(k) - + COUNT 300"
        default: return "GET \(k)"
        }
    }

    func query(_ text: String) throws -> QueryResult {
        var res = QueryResult()
        for line in text.split(whereSeparator: \.isNewline) {
            let args = Self.tokenize(String(line))
            guard let cmd = args.first?.uppercased(), !cmd.hasPrefix("#") else { continue }
            let reply = try command(args)
            if case .error(let e) = reply { throw DBError(e) }
            let paired = cmd == "HGETALL" || cmd == "CONFIG" || args.contains { $0.uppercased() == "WITHSCORES" }
            res = Self.table(reply, paired: paired)
        }
        return res
    }

    static func table(_ r: Reply, paired: Bool) -> QueryResult {
        guard case .array(let items?) = r else { return QueryResult(columns: ["value"], rows: [[text(r)]]) }
        // SCAN-style [cursor, [items]] → show the items
        if items.count == 2, case .bulk = items[0], case .array(let inner?) = items[1] {
            var t = table(.array(inner), paired: paired)
            t.message = "cursor \(text(items[0]) ?? "0") · \(inner.count) item(s)"
            return t
        }
        if paired {
            let rows = stride(from: 0, to: items.count - 1, by: 2).map { [text(items[$0]), text(items[$0 + 1])] }
            return QueryResult(columns: ["field", "value"], rows: rows)
        }
        return QueryResult(columns: ["#", "value"], rows: items.enumerated().map { [String($0.offset), text($0.element)] })
    }

    static func text(_ r: Reply) -> String? {
        switch r {
        case .simple(let s), .error(let s): s
        case .int(let i): String(i)
        case .bulk(let s): s
        case .array(let a): a.map { "[" + $0.map { text($0) ?? "nil" }.joined(separator: ", ") + "]" }
        }
    }

    /// Splits a command line on spaces, honouring "double" / 'single' quotes and \" escapes.
    static func tokenize(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?, esc = false, has = false
        for c in s {
            if esc { cur.append(c == "n" ? "\n" : c == "r" ? "\r" : c == "t" ? "\t" : c); esc = false; continue }
            if c == "\\", quote == "\"" { esc = true; continue }
            if let q = quote { if c == q { quote = nil } else { cur.append(c) }; continue }
            if c == "\"" || c == "'" { quote = c; has = true; continue }
            if c.isWhitespace { if has || !cur.isEmpty { out.append(cur) }; cur = ""; has = false; continue }
            cur.append(c)
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Quotes a key for the one-command-per-line editor. Line breaks are escaped so a key can never
    /// spill into a second command (a key named "x\nFLUSHDB" must stay one GET argument).
    static func quote(_ s: String) throws -> String {
        // Unicode line separators etc. would also split lines but have no escape here: refuse them.
        if s.contains(where: { $0.isNewline && $0 != "\n" && $0 != "\r" && $0 != "\r\n" })
            || s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !["\n", "\r", "\t"].contains($0) }) {
            throw DBError("This key contains control characters; type the command for it in the editor instead.")
        }
        guard s.isEmpty || s.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "\\" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }
}
