import Foundation
import CryptoKit
import Security

/// MySQL / MariaDB client protocol (text protocol), no libmysqlclient needed.
/// Auth: mysql_native_password and caching_sha2_password (RSA key exchange when no TLS).
final class MySQLDB: Database {
    private let sock: Socket
    private var seq: UInt8 = 0
    private var names = TableNames()
    private var currentDB: String?

    private static let caps: UInt32 = 0x1 | 0x2 | 0x200 | 0x2000 | 0x8000 | 0x10000 | 0x20000 | 0x80000
    // LONG_PASSWORD | FOUND_ROWS (matched, not changed, rows) | PROTOCOL_41 | TRANSACTIONS | SECURE_CONNECTION | MULTI_STATEMENTS | MULTI_RESULTS | PLUGIN_AUTH
    private static let connectWithDB: UInt32 = 0x8
    private static let moreResults: UInt16 = 0x8

    /// `allowPublicKeyRetrieval`: for caching_sha2 full auth without TLS, fetch the server's RSA key.
    /// Off by default: on an untrusted network that key could be swapped to capture the password.
    private static let clientSSL: UInt32 = 0x800

    init(host: String, port: String, user: String, password: String, database: String, allowPublicKeyRetrieval: Bool = false,
         tls: TLSMode = .off, via: (host: String, port: String)? = nil) throws {
        sock = try Socket(host: via?.host ?? host, port: via?.port ?? (port.isEmpty ? "3306" : port))

        // Initial handshake (protocol v10)
        var h = Reader(try readPacket())
        if h.peek == 0xFF { throw Self.error(h.bytes) }
        guard h.u8() == 10 else { throw DBError("Unsupported MySQL protocol") }
        _ = h.cstr()                  // server version
        h.skip(4)                     // thread id
        var scramble = h.take(8)
        h.skip(1)
        let capsLow = UInt32(h.u16())
        h.skip(1 + 2)                 // charset, status
        let serverCaps = capsLow | UInt32(h.u16()) << 16
        let authLen = Int(h.u8())
        h.skip(10)
        scramble += h.take(max(13, authLen - 8)).prefix(12)
        try Self.checkScramble(scramble)
        var plugin = h.cstr()

        // TLS: an SSLRequest (the response header alone), then the handshake, then the real response.
        let useTLS = tls != .off && (serverCaps & Self.clientSSL != 0)
        if (tls == .required || tls == .verify) && !useTLS {
            throw DBError("TLS is required for this connection, but the MySQL server doesn't offer it.")
        }
        var caps = Self.caps | (database.isEmpty ? 0 : Self.connectWithDB)
        if useTLS {
            caps |= Self.clientSSL
            try writePacket(le(caps) + le(UInt32(16 << 20)) + [45] + [UInt8](repeating: 0, count: 23))
            try sock.startTLS(host: host, verify: tls == .verify)
        }

        // Handshake response 41
        var p = le(caps) + le(UInt32(16 << 20)) + [45] + [UInt8](repeating: 0, count: 23) // 45 = utf8mb4
        p += Array(user.utf8) + [0]
        let auth = Self.scramble(plugin, password, scramble)
        p += [UInt8(auth.count)] + auth
        if !database.isEmpty { p += Array(database.utf8) + [0] }
        p += Array(plugin.utf8) + [0]
        try writePacket(p)

        // Auth exchange
        while true {
            let r = try readPacket()
            switch r.first {
            case 0x00: return
            case 0xFF: throw Self.error(r)
            case 0xFE: // auth switch
                var s = Reader(r); s.skip(1)
                plugin = s.cstr()
                scramble = Array(s.rest.prefix(20))
                try Self.checkScramble(scramble)
                try writePacket(Self.scramble(plugin, password, scramble))
            case 0x01 where r.count >= 2 && r[1] == 3: continue // caching_sha2 fast auth ok, OK packet follows
            // Full auth over verified TLS: the password itself. Unverified TLS could be a man in the middle,
            // so it takes the same opt-in as the RSA key below.
            case 0x01 where r.count >= 2 && r[1] == 4 && sock.isEncrypted && (sock.isVerified || allowPublicKeyRetrieval):
                try writePacket(Array(password.utf8) + [0])
            case 0x01 where r.count >= 2 && r[1] == 4:          // full auth: fetch server RSA key
                guard allowPublicKeyRetrieval else {
                    throw DBError("""
                        The server asked for full authentication. Without TLS set to Verify, the password (or the server's \
                        RSA key) could be intercepted by someone on the network. Use TLS "Verify" for this connection, or, \
                        if this server is on a network you trust (localhost, your LAN), enable "Allow public key retrieval".
                        """)
                }
                try writePacket([2])
                let pem = try readPacket().dropFirst()
                try writePacket(try Self.rsaEncrypt(password: password, scramble: scramble, pem: Data(pem)))
            default: throw DBError("Unexpected auth packet")
            }
        }
    }

    // MARK: Database

    func tables() throws -> [String] {
        let r = try query("""
            SELECT table_schema, table_name, DATABASE()
            FROM information_schema.tables
            WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys')
            ORDER BY table_schema <> IFNULL(DATABASE(), ''), table_schema, table_name
            """)
        currentDB = r.rows.first?[2] ?? nil
        return names.record(r.rows.map { (schema: $0[0] ?? "", name: $0[1] ?? "") }, defaultSchema: currentDB)
    }

    /// Exact (schema, name) as SQL: quoted identifier and string literals for information_schema lookups.
    private func qualified(_ t: String) -> String {
        let p = names.parts(t, defaultSchema: currentDB)
        return (p.schema.map { Self.ident($0) + "." } ?? "") + Self.ident(p.name)
    }
    private func schemaAndName(_ t: String) -> (schema: String, name: String) {
        let p = names.parts(t, defaultSchema: currentDB)
        return (p.schema.map(Self.literal) ?? "DATABASE()", Self.literal(p.name))
    }

    func databases() throws -> [String] { try firstColumn("SHOW DATABASES") }
    func serverVersion() throws -> String {
        let v = try firstColumn("SELECT VERSION()").first ?? ""  // "8.4.11" or "11.8.9-MariaDB-ubu2404"
        return v.localizedCaseInsensitiveContains("mariadb")
            ? "MariaDB " + (v.split(separator: "-").first.map(String.init) ?? v) : "MySQL " + v
    }

    func browseQuery(_ t: String, offset: Int) -> String { "SELECT * FROM \(qualified(t)) LIMIT \(pageSize) OFFSET \(offset)" }

    static func ident(_ s: some StringProtocol) -> String { "`" + s.replacingOccurrences(of: "`", with: "``") + "`" }
    /// Hex literal: immune to quoting rules and NO_BACKSLASH_ESCAPES.
    static func literal(_ v: String?) -> String {
        guard let v else { return "NULL" }
        return "CONVERT(X'" + v.utf8.map { String(format: "%02X", $0) }.joined() + "' USING utf8mb4)"
    }

    func primaryKey(_ t: String) throws -> [String] {
        let (schema, name) = schemaAndName(t)
        return try firstColumn("""
            SELECT column_name FROM information_schema.key_column_usage
            WHERE constraint_name = 'PRIMARY' AND table_schema = \(schema) AND table_name = \(name)
            ORDER BY ordinal_position
            """)
    }

    func quoteTable(_ t: String) -> String { qualified(t) }

    func structure(_ t: String) throws -> QueryResult {
        let (schema, name) = schemaAndName(t)
        return try query("""
            SELECT ordinal_position AS `#`, column_name, data_type, column_type AS full_type, is_nullable,
                   column_default, extra, column_comment AS comment
            FROM information_schema.columns
            WHERE table_schema = \(schema) AND table_name = \(name)
            ORDER BY ordinal_position
            """)
    }

    func indexes(_ t: String) throws -> QueryResult {
        let (schema, name) = schemaAndName(t)
        return try query("""
            SELECT index_name AS index_name, index_type AS index_algorithm,
                   IF(non_unique = 0, 'TRUE', 'FALSE') AS is_unique, IF(index_name = 'PRIMARY', 'TRUE', 'FALSE') AS is_primary,
                   GROUP_CONCAT(IFNULL(column_name, '(expression)') ORDER BY seq_in_index SEPARATOR ', ') AS columns
            FROM information_schema.statistics
            WHERE table_schema = \(schema) AND table_name = \(name)
            GROUP BY index_name, index_type, non_unique ORDER BY index_name = 'PRIMARY' DESC, index_name
            """)
    }

    func foreignKeys() throws -> [ForeignKey] {
        try query("""
            SELECT table_schema, table_name, column_name, referenced_table_schema, referenced_table_name, referenced_column_name
            FROM information_schema.key_column_usage
            WHERE referenced_table_name IS NOT NULL AND table_schema = DATABASE()
            """).rows.map {
                ForeignKey(fromTable: TableNames.display(schema: $0[0] ?? "", name: $0[1] ?? "", defaultSchema: currentDB), fromColumn: $0[2] ?? "",
                           toTable: TableNames.display(schema: $0[3] ?? "", name: $0[4] ?? "", defaultSchema: currentDB), toColumn: $0[5] ?? "")
            }
    }

    func columns(_ t: String) throws -> [ColumnInfo] {
        let (schema, name) = schemaAndName(t)
        return columnInfos(try query("""
            SELECT column_name, data_type, IF(column_key = 'PRI', '1', '0')
            FROM information_schema.columns
            WHERE table_schema = \(schema) AND table_name = \(name)
            ORDER BY ordinal_position
            """).rows)
    }

    func update(_ t: String, set: [(String, String?)], key: [(String, String?)]) throws -> Int {
        try query("UPDATE \(qualified(t)) SET " + set.map { "\(Self.ident($0.0)) = \(Self.literal($0.1))" }.joined(separator: ", ")
            + " WHERE " + key.map { "\(Self.ident($0.0)) <=> \(Self.literal($0.1))" }.joined(separator: " AND ")).affected
    }

    func query(_ sql: String) throws -> QueryResult {
        seq = 0
        try writePacket([0x03] + Array(sql.utf8)) // COM_QUERY
        var last = QueryResult()
        while true {
            let p = try readPacket()
            var status: UInt16 = 0
            switch p.first {
            case 0x00:
                var r = Reader(p); r.skip(1)
                let affected = r.lenenc()
                _ = r.lenenc()
                status = r.u16()
                if last.columns.isEmpty { last.message = "\(affected) row(s) affected"; last.affected = Int(affected) }
            case 0xFF:
                throw Self.error(p)
            case 0xFB:
                throw DBError("LOAD DATA LOCAL INFILE is not supported")
            default:
                var r = Reader(p)
                let n = r.lenenc()
                guard n <= 4096 else { throw DBError("Server reported \(n) columns; MySQL allows at most 4096") }
                var cur = QueryResult()
                for _ in 0..<n {
                    var c = Reader(try readPacket())
                    for _ in 0..<4 { c.skip(c.lenenc()) } // catalog, schema, table, org_table
                    cur.columns.append(String(decoding: c.take(c.lenenc()), as: UTF8.self))
                    c.skip(c.lenenc())      // org_name
                    _ = c.lenenc()               // fixed-length fields marker (0x0c)
                    let charset = c.u16()
                    c.skip(4)                    // column length
                    cur.types.append(Self.typeName(c.u8(), binary: charset == 63))
                }
                _ = try readPacket() // EOF after column defs
                while true {
                    let row = try readPacket()
                    if row.first == 0xFE && row.count < 9 { var e = Reader(row); e.skip(3); status = e.u16(); break }
                    if row.first == 0xFF { throw Self.error(row) }
                    // Drain past the cap to keep the protocol in sync.
                    guard cur.rows.count < maxRows else { cur.message = "Showing first \(maxRows) rows"; continue }
                    var v = Reader(row)
                    cur.rows.append((0..<n).map { _ in
                        if v.peek == 0xFB { v.skip(1); return nil }
                        return String(decoding: v.take(v.lenenc()), as: UTF8.self)
                    })
                }
                last = cur
            }
            if status & Self.moreResults == 0 { return last }
        }
    }

    private static func typeName(_ t: UInt8, binary: Bool) -> String {
        switch t {
        case 0, 246: "decimal"
        case 1: "tinyint"
        case 2: "smallint"
        case 3: "int"
        case 4: "float"
        case 5: "double"
        case 7: "timestamp"
        case 8: "bigint"
        case 9: "mediumint"
        case 10: "date"
        case 11: "time"
        case 12: "datetime"
        case 13: "year"
        case 16: "bit"
        case 245: "json"
        case 247: "enum"
        case 248: "set"
        case 249...252: binary ? "blob" : "text"
        case 15, 253: binary ? "varbinary" : "varchar"
        case 254: binary ? "binary" : "char"
        case 255: "geometry"
        default: ""
        }
    }

    /// Column of a streamed result: how its values must be written back in a dump.
    struct DumpColumn { let name: String; let numeric: Bool; let binary: Bool }

    /// Runs one SELECT and hands every row's raw bytes to `onRow` as it arrives: no row cap, no
    /// buffering, no text decoding (binary columns stay intact). Used by the dumper.
    func streamRows(_ sql: String, onRow: ([DumpColumn], [[UInt8]?]) throws -> Void) throws {
        seq = 0
        try writePacket([0x03] + Array(sql.utf8))
        let first = try readPacket()
        if first.first == 0xFF { throw Self.error(first) }
        var r = Reader(first)
        let n = r.lenenc()
        guard n <= 4096 else { throw DBError("Server reported \(n) columns") }
        var cols: [DumpColumn] = []
        for _ in 0..<n {
            var c = Reader(try readPacket())
            for _ in 0..<4 { c.skip(c.lenenc()) }
            let name = String(decoding: c.take(c.lenenc()), as: UTF8.self)
            c.skip(c.lenenc()); _ = c.lenenc()
            let charset = c.u16(); c.skip(4)
            let type = c.u8()
            let numeric = [0, 1, 2, 3, 4, 5, 8, 9, 13, 246].contains(type)
            // charset 63 = binary; numbers report it too, so only string/blob types count as binary
            let binary = type == 16 || type == 255 || (charset == 63 && [15, 249, 250, 251, 252, 253, 254].contains(type))
            cols.append(DumpColumn(name: name, numeric: numeric, binary: binary))
        }
        _ = try readPacket() // EOF after column definitions
        while true {
            let row = try readPacket()
            if row.first == 0xFE && row.count < 9 { return }
            if row.first == 0xFF { throw Self.error(row) }
            var v = Reader(row)
            try onRow(cols, (0..<n).map { _ in
                if v.peek == 0xFB { v.skip(1); return nil }
                return v.take(v.lenenc())
            })
        }
    }

    // MARK: Packets

    private func readPacket() throws -> [UInt8] {
        var out: [UInt8] = []
        while true {
            let h = try sock.read(count: 4)
            let len = Int(h[0]) | Int(h[1]) << 8 | Int(h[2]) << 16
            seq = h[3] &+ 1
            out += try sock.read(count: len)
            // max_allowed_packet tops out at 1 GB; anything bigger is a broken or hostile server
            guard out.count <= 1 << 30 else { throw DBError("MySQL packet larger than 1 GB") }
            if len < 0xFFFFFF { return out }
        }
    }

    private func writePacket(_ payload: [UInt8]) throws {
        var off = 0
        repeat {
            let n = min(payload.count - off, 0xFFFFFF)
            try sock.write([UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16), seq] + payload[off..<off + n])
            seq &+= 1
            off += n
            if n < 0xFFFFFF { break }
        } while true
    }

    private static func error(_ p: [UInt8]) -> DBError {
        var r = Reader(p); r.skip(1)
        let code = r.u16()
        if r.peek == UInt8(ascii: "#") { r.skip(6) }
        return DBError("ERROR \(code): \(String(decoding: r.rest, as: UTF8.self))")
    }

    // MARK: Auth

    /// The server's challenge must be the 20 bytes both auth plugins expect; anything else is a
    /// broken or hostile server (an empty one would divide by zero in rsaEncrypt).
    static func checkScramble(_ s: [UInt8]) throws {
        guard s.count == 20 else { throw DBError("Invalid authentication challenge from server (\(s.count) bytes)") }
    }

    static func scramble(_ plugin: String, _ pw: String, _ salt: [UInt8]) -> [UInt8] {
        guard !pw.isEmpty else { return [] }
        let p = Data(pw.utf8)
        switch plugin {
        case "caching_sha2_password":
            let h1 = Array(SHA256.hash(data: p)), h2 = Array(SHA256.hash(data: Data(h1)))
            let h3 = Array(SHA256.hash(data: Data(h2 + salt)))
            return zip(h1, h3).map { $0 ^ $1 }
        default: // mysql_native_password
            let h1 = Array(Insecure.SHA1.hash(data: p)), h2 = Array(Insecure.SHA1.hash(data: Data(h1)))
            let h3 = Array(Insecure.SHA1.hash(data: Data(salt + h2)))
            return zip(h1, h3).map { $0 ^ $1 }
        }
    }

    private static func rsaEncrypt(password: String, scramble: [UInt8], pem: Data) throws -> [UInt8] {
        var items: CFArray?
        var format = SecExternalFormat.formatPEMSequence, type = SecExternalItemType.itemTypePublicKey
        guard SecItemImport(pem as CFData, nil, &format, &type, [], nil, nil, &items) == errSecSuccess,
              let key = (items as? [SecKey])?.first else { throw DBError("Cannot read server RSA public key") }
        let plain = (Array(password.utf8) + [0]).enumerated().map { $0.element ^ scramble[$0.offset % scramble.count] }
        var err: Unmanaged<CFError>?
        guard let enc = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data(plain) as CFData, &err) else {
            throw DBError("RSA encryption failed")
        }
        return Array(enc as Data)
    }
}

private func le(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }

/// Cursor over a packet payload. Reads past the end yield zeros instead of crashing.
struct Reader {
    let bytes: [UInt8]
    var i = 0
    init(_ b: [UInt8]) { bytes = b }
    var peek: UInt8 { i < bytes.count ? bytes[i] : 0 }
    var rest: ArraySlice<UInt8> { bytes[min(i, bytes.count)...] }
    // Positions saturate at the end of the packet: lengths come from the server and may be huge.
    mutating func skip(_ n: Int) { i = n >= bytes.count - min(i, bytes.count) ? bytes.count + 1 : i + max(n, 0) }
    mutating func u8() -> UInt8 { defer { skip(1) }; return peek }
    mutating func u16() -> UInt16 { UInt16(u8()) | UInt16(u8()) << 8 }
    mutating func take(_ n: Int) -> [UInt8] {
        let s = min(i, bytes.count), e = s + min(max(n, 0), bytes.count - s)
        skip(n)
        return Array(bytes[s..<e])
    }
    mutating func cstr() -> String {
        let s = min(i, bytes.count)
        let e = bytes[s...].firstIndex(of: 0) ?? bytes.count
        i = e + 1
        return String(decoding: bytes[s..<e], as: UTF8.self)
    }
    /// Length-encoded integer. Values are clamped to Int.max so a hostile packet can't crash `Int(...)`;
    /// reads past the end still yield zeros/empty slices.
    mutating func lenenc() -> Int { Int(clamping: lenencRaw()) }
    mutating func lenencRaw() -> UInt64 {
        let f = u8()
        let n: Int
        switch f {
        case 0xFC: n = 2
        case 0xFD: n = 3
        case 0xFE: n = 8
        default: return UInt64(f)
        }
        return take(n).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }
    }
}
