import SwiftUI

// MARK: Database export / import (.sql)
//
// Postgres: pg_dump / psql / pg_restore from Homebrew's libpq (pg_dump 18 reads servers from 9.2 up).
// SQLite: the system's sqlite3. MySQL: a built-in dumper and statement runner (no mysqldump on
// this platform). Each runs on its own connection or process, so the workspace stays usable.

/// File format of an export. `.backup` is the database's native backup: a pg_dump custom archive
/// for Postgres (compressed, restorable table by table), a copy of the database file for SQLite.
enum DumpFormat: String, CaseIterable, Identifiable {
    case sql = "SQL script (.sql)", custom = "Custom archive (.dump)", backup = "Backup (.bak)", tar = "Tar archive (.tar)",
         directory = "Directory archive (folder)"
    var id: String { rawValue }
    var ext: String {
        switch self { case .sql: "sql"; case .custom: "dump"; case .backup: "bak"; case .tar: "tar"; case .directory: "" }
    }
    /// pg_dump's custom, tar and directory formats exist only for Postgres.
    static func available(for kind: Conn.Kind) -> [DumpFormat] { kind == .postgres ? allCases : [.sql, .backup] }
}

enum DumpContent: String, CaseIterable, Identifiable {
    case all = "Structure and data", schema = "Structure only", data = "Data only"
    var id: String { rawValue }
}

/// Cancels a running export/import: stops the external process, or the MySQL loop at the next row.
final class TransferCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var process: Process?
    var cancelled: Bool { lock.withLock { _cancelled } }
    func attach(_ p: Process) { lock.withLock { process = p } }
    func cancel() { lock.withLock { _cancelled = true; if process?.isRunning == true { process?.terminate() } } }
}

enum Tools {
    /// PostgreSQL client tools, most capable first: Postgres.app and full Homebrew PostgreSQL builds
    /// support lz4/zstd-compressed archives; Homebrew's libpq and the copy bundled in a release only gzip.
    static func pgCandidates(_ name: String) -> [String] {
        var dirs = ["/Applications/Postgres.app/Contents/Versions/latest/bin"]
        for prefix in ["/opt/homebrew/opt", "/usr/local/opt"] {
            dirs += (14...18).reversed().map { "\(prefix)/postgresql@\($0)/bin" } + ["\(prefix)/postgresql/bin"]
        }
        dirs += ["/opt/homebrew/opt/libpq/bin", "/usr/local/opt/libpq/bin"]
        dirs.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").path) // packaged release (package.sh)
        return dirs.map { "\($0)/\(name)" }.filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func pg(_ name: String) throws -> String {
        guard let first = pgCandidates(name).first else { throw DBError("\(name) not found. Install it with: brew install libpq") }
        return first
    }

    /// A pg_restore that can actually read this archive. Builds without zstd/lz4 only *warn* and then
    /// restore the schema without any data, so that case is refused instead of silently losing rows.
    static func pgRestore(for archive: URL) throws -> String {
        var compression = "unknown"
        for tool in pgCandidates("pg_restore") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = ["--list", archive.path]
            let err = Pipe(), out = Pipe()
            p.standardError = err; p.standardOutput = out
            try p.run()
            let listing = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let warning = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            if let line = listing.split(separator: "\n").first(where: { $0.contains("Compression:") }) {
                compression = line.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? compression
            }
            if p.terminationStatus == 0, !warning.contains("does not support compression") { return tool }
        }
        throw DBError("""
            This backup is compressed with \(compression), which the installed pg_restore can't read, so no data \
            would be restored. Install a full PostgreSQL client with \(compression) support, for example \
            Postgres.app (postgresapp.com), then import again.
            """)
    }

    /// Runs a tool to completion; stdout to `output` when given. Throws with the tail of stderr on
    /// failure; on success returns stderr (psql/pg_restore report statement errors there even when
    /// they exit 0 because "stop on first error" is off).
    @discardableResult
    static func run(_ path: String, _ args: [String], env: [String: String]? = nil, input: URL? = nil, output: URL? = nil,
                    cancel: TransferCancel) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            if let env { p.environment = env }
            let err = Pipe()
            p.standardError = err
            p.standardInput = try input.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
            if let output {
                FileManager.default.createFile(atPath: output.path, contents: nil)
                p.standardOutput = try FileHandle(forWritingTo: output)
            } else {
                p.standardOutput = FileHandle.nullDevice
            }
            cancel.attach(p)
            try p.run()
            let errData = err.fileHandleForReading.readDataToEndOfFile() // drains stderr while it runs
            p.waitUntilExit()
            if cancel.cancelled { throw DBError("Cancelled") }
            guard p.terminationStatus == 0 else {
                let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw DBError(msg.isEmpty ? "\((path as NSString).lastPathComponent) failed (status \(p.terminationStatus))"
                                          : String(msg.suffix(1500)))
            }
            return String(decoding: errData, as: UTF8.self)
        }.value
    }

    /// A psql that supports \restrict (18+, and 17.6 / 16.10 / 15.14 / 14.19 / 13.22 backports): in that
    /// mode it refuses every meta-command (\! shell, \copy to files, \connect, …) coming from the file.
    static func restrictablePsql() throws -> String {
        let minimum = [13: 22, 14: 19, 15: 14, 16: 10, 17: 6]
        for tool in pgCandidates("psql") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = ["--version"]
            let out = Pipe()
            p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            // "psql (PostgreSQL) 18.1" / "psql (PostgreSQL) 16.10 (Homebrew)"
            guard let v = text.split(separator: " ").first(where: { $0.first?.isNumber == true }) else { continue }
            let n = v.split(separator: ".").compactMap { Int($0.prefix { $0.isNumber }) }
            guard let major = n.first else { continue }
            if major >= 18 || n.count > 1 && n[1] >= (minimum[major] ?? Int.max) { return tool }
        }
        throw DBError("Importing SQL files needs psql 18 (or a current 13–17 release). Update it with: brew upgrade libpq")
    }

    /// pg_dump custom ("PGDMP" magic), tar ("ustar" at offset 257) or directory (toc.dat) archive, whatever it's called.
    static func isPGArchive(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("toc.dat").path) { return true } // directory format
        let head = (try? FileHandle(forReadingFrom: url).read(upToCount: 262)) ?? Data()
        return head.starts(with: Data("PGDMP".utf8)) || (head.count >= 262 && head[257..<262] == Data("ustar".utf8))
    }

    /// Table of contents of a pg_dump archive (pg_restore --list).
    static func archiveListing(_ url: URL) async throws -> String {
        let tool = try pgRestore(for: url)
        return try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = ["--list", url.path]
            let out = Pipe()
            p.standardOutput = out; p.standardError = FileHandle.nullDevice
            try p.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return text
        }.value
    }

    /// Whether the start of a SQL file mentions `word` (extensions are created near the top of a dump).
    static func fileMentions(_ url: URL, _ word: String) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url), let d = try? h.read(upToCount: 8 << 20) else { return false }
        return String(decoding: d, as: UTF8.self).contains(word)
    }

    /// Statement errors in a psql/pg_restore log, grouped; throws so a partial import never reads as success.
    static func checkStatementErrors(_ log: String, what: String, timescaleVersion: String? = nil) throws {
        // Server errors are "ERROR:"; psql's own (e.g. a refused meta-command) are "error:".
        let errors = log.split(separator: "\n").filter { $0.contains("ERROR:") || $0.contains(": error:") }.map { line -> String in
            let msg = (line.range(of: "ERROR:") ?? line.range(of: "error:")).map { String(line[$0.lowerBound...]) } ?? String(line)
            return msg.replacingOccurrences(of: #"at or near "[^"]*""#, with: "at or near …", options: .regularExpression)
        }
        guard !errors.isEmpty else { return }
        let grouped = Dictionary(errors.map { ($0, 1) }, uniquingKeysWith: +).sorted { $0.value > $1.value }
        var text = "\(what) finished with \(errors.count) failed statement(s):\n"
            + grouped.prefix(6).map { "  \($0.value) × \($0.key)" }.joined(separator: "\n")
        if let v = timescaleVersion {
            text += "\n\nTimescaleDB restores need the same TimescaleDB version as the source server; this server has \(v). "
                + "Catalog errors like the ones above usually mean the versions differ."
        } else if errors.contains(where: { $0.contains("_timescaledb") }) {
            text += "\n\nThis dump uses the TimescaleDB extension. Restore it into a server that has TimescaleDB installed."
        }
        throw DBError(text)
    }
}

extension Session {
    var canTransfer: Bool { conn.kind != .redis }

    // MARK: Postgres environment (connection settings without putting the password on a command line)

    /// libpq environment for pg_dump/psql, plus a 0600 passfile the caller deletes afterwards.
    private func libpqEnv() throws -> (env: [String: String], passfile: URL?) {
        var e = ProcessInfo.processInfo.environment
        e["PGHOST"] = conn.host.isEmpty ? "localhost" : conn.host
        e["PGPORT"] = conn.port.isEmpty ? "5432" : conn.port
        if conn.useSSH == true, let tunnel { e["PGHOSTADDR"] = "127.0.0.1"; e["PGPORT"] = String(tunnel.localPort) }
        e["PGUSER"] = conn.user
        e["PGDATABASE"] = conn.database
        e["PGAPPNAME"] = "Kueri"
        e["PGCONNECT_TIMEOUT"] = "10"
        e["PGSSLMODE"] = ["off": "disable", "prefer": "prefer", "required": "require", "verify": "verify-full"][conn.tlsMode.rawValue]
        if conn.tlsMode == .verify { e["PGSSLROOTCERT"] = "system" }
        if conn.allowCleartextPassword != true { e["PGREQUIREAUTH"] = "!password" }
        var passfile: URL?
        if let pw = conn.password, !pw.isEmpty {
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("kueri-\(UUID()).pgpass")
            let escaped = pw.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:")
            FileManager.default.createFile(atPath: f.path, contents: Data("*:*:*:*:\(escaped)\n".utf8), attributes: [.posixPermissions: 0o600])
            e["PGPASSFILE"] = f.path
            passfile = f
        }
        return (e, passfile)
    }

    // MARK: Export

    func exportDatabase(to url: URL, content: DumpContent, format: DumpFormat = .sql, cancel: TransferCancel) async throws {
        switch conn.kind {
        case .postgres:
            let (env, passfile) = try libpqEnv()
            defer { passfile.map { try? FileManager.default.removeItem(at: $0) } }
            var args = ["--no-owner", "--no-privileges", "-f", url.path]
            switch format {
            case .custom, .backup: args.append("--format=custom")
            case .tar: args.append("--format=tar")
            case .directory:
                args.append("--format=directory")
                try? FileManager.default.removeItem(at: url) // the save panel already asked to replace it; pg_dump wants a new folder
            case .sql: break
            }
            if content == .schema { args.append("--schema-only") }
            if content == .data { args.append("--data-only") }
            try await Tools.run(try Tools.pg("pg_dump"), args, env: env, cancel: cancel)
        case .sqlite where format == .backup:
            // Consistent copy of the whole database file (online backup API), whatever "content" says.
            try? FileManager.default.removeItem(at: url)
            try await Tools.run("/usr/bin/sqlite3", [conn.path, ".backup '\(url.path.replacingOccurrences(of: "'", with: "''"))'"], cancel: cancel)
        case .sqlite:
            let command = content == .schema ? ".schema" : (content == .data ? ".dump --data-only" : ".dump")
            try await Tools.run("/usr/bin/sqlite3", [conn.path, command], output: url, cancel: cancel)
        case .mysql:
            let db = try await freshMySQL()
            try await Task.detached { try MySQLDump.write(db, to: url, content: content, cancel: cancel) }.value
        case .redis:
            throw DBError("Redis databases can't be exported as SQL")
        }
    }

    // MARK: Import

    /// Runs a dump file against the current database. Returns a short summary.
    func importFile(_ url: URL, stopOnError: Bool, cancel: TransferCancel) async throws -> String {
        defer { refreshTables() }
        switch conn.kind {
        case .postgres:
            let (env, passfile) = try libpqEnv()
            defer { passfile.map { try? FileManager.default.removeItem(at: $0) } }
            let version = try await onQueue { db in Int(try db.query("SHOW server_version_num").rows.first?.first??.trimmingCharacters(in: .whitespaces) ?? "") ?? 0 }
            let isArchive = Tools.isPGArchive(url)

            // TimescaleDB dumps need the extension on the target and its pre/post restore steps; check
            // before touching anything, so a missing extension never leaves a half-imported database.
            let usesTimescale = isArchive ? try await Tools.archiveListing(url).contains("timescaledb")
                                          : Tools.fileMentions(url, "timescaledb")
            if usesTimescale {
                let available = try await onQueue { db in !(try db.query("SELECT 1 FROM pg_available_extensions WHERE name = 'timescaledb'").rows.isEmpty) }
                guard available else {
                    throw DBError("""
                        This dump uses the TimescaleDB extension, which isn't installed on \(conn.name). Nothing was imported. \
                        Restore it into a server with TimescaleDB (for example the timescale/timescaledb Docker image).
                        """)
                }
                _ = try await onQueue { db in try db.query("CREATE EXTENSION IF NOT EXISTS timescaledb; SELECT timescaledb_pre_restore()") }
            }
            let tsVersion: String? = usesTimescale
                ? try? await onQueue { db in (try db.query("SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'").rows.first?.first ?? nil) ?? "?" }
                : nil
            do {
                let summary = try await importPostgres(url, isArchive: isArchive, version: version, env: env, stopOnError: stopOnError,
                                                       timescaleVersion: tsVersion, cancel: cancel)
                if usesTimescale { _ = try await onQueue { db in try db.query("SELECT timescaledb_post_restore()") } }
                return summary + (usesTimescale ? " (TimescaleDB restore mode used)" : "")
            } catch {
                if usesTimescale { _ = try? await onQueue { db in try db.query("SELECT timescaledb_post_restore()") } }
                throw error
            }
        case .sqlite:
            let head = (try? FileHandle(forReadingFrom: url).read(upToCount: 16)) ?? Data()
            if head == Data("SQLite format 3\0".utf8) { // a database file / .bak: restore it over this database
                try await Tools.run("/usr/bin/sqlite3", [conn.path, ".restore '\(url.path.replacingOccurrences(of: "'", with: "''"))'"], cancel: cancel)
                return "Restored \(url.lastPathComponent)"
            }
            // -safe: dot-commands like .shell/.system/.load in the file are refused.
            try await Tools.run("/usr/bin/sqlite3", ["-safe"] + (stopOnError ? ["-bail"] : []) + [conn.path], input: url, cancel: cancel)
            return "Imported \(url.lastPathComponent)"
        case .mysql:
            let db = try await freshMySQL()
            let n = try await Task.detached { try MySQLDump.run(db, file: url, stopOnError: stopOnError, cancel: cancel) }.value
            return "Ran \(n) statement(s) from \(url.lastPathComponent)"
        case .redis:
            throw DBError("Redis can't import SQL files")
        }
    }

    private func importPostgres(_ url: URL, isArchive: Bool, version: Int, env: [String: String], stopOnError: Bool,
                                timescaleVersion: String? = nil, cancel: TransferCancel) async throws -> String {
        var source = url
        var converted: URL?
        defer { converted.map { try? FileManager.default.removeItem(at: $0) } }
        if isArchive { // custom or tar archive from pg_dump -Fc / -Ft
            if version == 0 || version >= 170000 {
                var args = ["--no-owner", "--no-privileges", "-d", conn.database, url.path]
                if stopOnError { args.insert("--exit-on-error", at: 0) }
                let log = try await Tools.run(try Tools.pgRestore(for: url), args, env: env, cancel: cancel)
                try Tools.checkStatementErrors(log, what: "Restore of \(url.lastPathComponent)", timescaleVersion: timescaleVersion)
                return "Restored archive \(url.lastPathComponent)"
            }
            // pg_restore 18 sends settings older servers reject: turn the archive into a script
            // (no server needed for that), then filter and run it like a plain dump.
            let script = FileManager.default.temporaryDirectory.appendingPathComponent("kueri-restore-\(UUID()).sql")
            converted = script
            try await Tools.run(try Tools.pgRestore(for: url), ["--no-owner", "--no-privileges", "-f", script.path, url.path], cancel: cancel)
            source = script
        }
        // Plain SQL: drop settings the target server doesn't know (dumps from newer pg_dump).
        let psql = try Tools.restrictablePsql()
        let (filtered, removed) = try PGDumpFilter.filtered(source, serverVersion: version)
        defer { try? FileManager.default.removeItem(at: filtered) }
        var args = ["-X", "-q", "-f", filtered.path]
        if stopOnError { args = ["-v", "ON_ERROR_STOP=1"] + args }
        let log = try await Tools.run(psql, args, env: env, cancel: cancel)
        try Tools.checkStatementErrors(log, what: "Import of \(url.lastPathComponent)", timescaleVersion: timescaleVersion)
        return "Imported \(url.lastPathComponent)" + (removed > 0 ? " (skipped \(removed) setting(s) this server version doesn't support)" : "")
    }

    /// A second MySQL connection (same settings and SSH tunnel), so long transfers don't block the tab.
    private func freshMySQL() async throws -> MySQLDB {
        let c = conn, t = tunnel
        return try await Task.detached {
            let via = c.useSSH == true ? t.map { (host: "127.0.0.1", port: String($0.localPort)) } : nil
            return try MySQLDB(host: c.host, port: c.port, user: c.user, password: c.password ?? "", database: c.database,
                               allowPublicKeyRetrieval: c.allowPublicKeyRetrieval ?? false, tls: c.tlsMode, via: via)
        }.value
    }

    func refreshTables() {
        Task { if let t = try? await onQueue({ try $0.tables() }) { tables = t } }
    }
}

// MARK: Postgres cross-version filter

enum PGDumpFilter {
    /// `SET` parameters newer pg_dump writes that older servers reject, with the first version that knows them.
    static let settings: [(name: String, since: Int)] = [
        ("transaction_timeout", 170000), ("default_table_access_method", 120000),
        ("idle_in_transaction_session_timeout", 90600), ("row_security", 90500),
    ]

    /// Temp copy of the dump for psql: unsupported top-level SET lines dropped (`removed` counts them),
    /// the dump's own \restrict/\unrestrict lines dropped, and the whole file wrapped in \restrict with a
    /// random key, so psql runs it as plain SQL and refuses any meta-command inside. Streams the file.
    static func filtered(_ url: URL, serverVersion: Int, key: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")) throws -> (URL, removed: Int) {
        let drop = settings.filter { serverVersion > 0 && serverVersion < $0.since }.map { Array("SET \($0.name) = ".utf8) }
        let ownRestrict = [Array("\\restrict ".utf8), Array("\\unrestrict ".utf8)]
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("kueri-import-\(UUID()).sql")
        FileManager.default.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let w = try FileHandle(forWritingTo: out)
        defer { try? w.close() }
        let r = try FileHandle(forReadingFrom: url)
        defer { try? r.close() }
        w.write(Data("\\restrict \(key)\n".utf8))
        var removed = 0, pending: [UInt8] = []
        func emit(_ line: ArraySlice<UInt8>) {
            if drop.contains(where: { line.starts(with: $0) }) { removed += 1; return }
            if ownRestrict.contains(where: { line.starts(with: $0) }) { return }
            w.write(Data(line)); w.write(Data([10]))
        }
        while let chunk = try r.read(upToCount: 1 << 20), !chunk.isEmpty {
            pending += chunk
            var start = 0
            while let nl = pending[start...].firstIndex(of: 10) { emit(pending[start..<nl]); start = nl + 1 }
            pending.removeFirst(start)
        }
        if !pending.isEmpty { emit(pending[...]) }
        w.write(Data("\\unrestrict \(key)\n".utf8))
        return (out, removed)
    }
}

// MARK: MySQL dumper / runner

enum MySQLDump {
    static func write(_ db: MySQLDB, to url: URL, content: DumpContent, cancel: TransferCancel) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        func put(_ s: String) { out.write(Data(s.utf8)) }

        let version = (try db.query("SELECT VERSION()").rows.first?.first ?? nil) ?? ""
        let dbName = (try db.query("SELECT DATABASE()").rows.first?.first ?? nil) ?? ""
        put("-- Kueri dump of `\(dbName)` from MySQL \(version)\n")
        put("SET NAMES utf8mb4;\nSET FOREIGN_KEY_CHECKS = 0;\nSET SQL_MODE = 'NO_AUTO_VALUE_ON_ZERO';\nSET UNIQUE_CHECKS = 0;\n\n")

        let objects = try db.query("SHOW FULL TABLES").rows.map { (name: $0[0] ?? "", isView: ($0[1] ?? "") == "VIEW") }
        let ident = { (s: String) in "`" + s.replacingOccurrences(of: "`", with: "``") + "`" }
        for t in objects where !t.isView {
            if cancel.cancelled { throw DBError("Cancelled") }
            if content != .data {
                let create = (try db.query("SHOW CREATE TABLE \(ident(t.name))").rows.first?[1] ?? nil) ?? ""
                put("DROP TABLE IF EXISTS \(ident(t.name));\n\(create);\n\n")
            }
            guard content != .schema else { continue }
            var batch: [String] = [], size = 0
            var header = ""
            func flush() {
                guard !batch.isEmpty else { return }
                put(header + batch.joined(separator: ",\n") + ";\n")
                batch = []; size = 0
            }
            try db.streamRows("SELECT * FROM \(ident(t.name))") { cols, row in
                if cancel.cancelled { throw DBError("Cancelled") }
                if header.isEmpty { header = "INSERT INTO \(ident(t.name)) (\(cols.map { ident($0.name) }.joined(separator: ", "))) VALUES\n" }
                let values = zip(cols, row).map { col, v in literal(v, col) }.joined(separator: ", ")
                batch.append("(\(values))"); size += values.utf8.count
                if size > 1_000_000 || batch.count >= 1000 { flush() } // ~1 MB statements stay under max_allowed_packet
            }
            flush()
            put("\n")
        }
        if content != .data {
            for v in objects where v.isView {
                var create = (try db.query("SHOW CREATE VIEW \(ident(v.name))").rows.first?[1] ?? nil) ?? ""
                // DEFINER names a user of the source server; drop it so the view imports anywhere.
                create = create.replacingOccurrences(of: #"DEFINER=`[^`]*`@`[^`]*`\s*"#, with: "", options: .regularExpression)
                put("DROP VIEW IF EXISTS \(ident(v.name));\n\(create);\n\n")
            }
        }
        put("SET FOREIGN_KEY_CHECKS = 1;\nSET UNIQUE_CHECKS = 1;\n")
    }

    /// A value as SQL: numbers bare, binary as hex, text quoted with MySQL escapes (the dump sets a
    /// SQL_MODE without NO_BACKSLASH_ESCAPES, so backslash escapes are valid on import).
    static func literal(_ v: [UInt8]?, _ c: MySQLDB.DumpColumn) -> String {
        guard let v else { return "NULL" }
        if c.binary { return v.isEmpty ? "''" : "X'" + v.map { String(format: "%02X", $0) }.joined() + "'" }
        let s = String(decoding: v, as: UTF8.self)
        if c.numeric { return s }
        var out = "'"
        for ch in s.unicodeScalars {
            switch ch {
            case "\0": out += "\\0"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\u{1A}": out += "\\Z"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out + "'"
    }

    /// Runs a .sql file statement by statement. MySQL 8 collations are mapped for older servers.
    static func run(_ db: MySQLDB, file: URL, stopOnError: Bool, cancel: TransferCancel) throws -> Int {
        // Limitation: the file is read into memory; very large dumps would need a streaming splitter
        let text = try String(contentsOf: file, encoding: .utf8)
        let version = (try? db.query("SELECT VERSION()").rows.first?.first ?? nil) ?? ""
        let oldServer = version.localizedCaseInsensitiveContains("mariadb") || (Int(version.prefix(while: \.isNumber)) ?? 8) < 8
        var ran = 0, failures: [String] = []
        for (i, statement) in splitSQL(text, hashComments: true).enumerated() {
            if cancel.cancelled { throw DBError("Cancelled after \(ran) statement(s)") }
            var sql = statement
            if oldServer { sql = sql.replacingOccurrences(of: #"utf8mb4_0900_[a-z_]+"#, with: "utf8mb4_unicode_ci", options: .regularExpression) }
            do { _ = try db.query(sql); ran += 1 }
            catch {
                let msg = "Statement \(i + 1): \(error.localizedDescription)\n\(sql.prefix(200))"
                if stopOnError { throw DBError(msg) }
                failures.append(msg)
            }
        }
        if !failures.isEmpty { throw DBError("\(failures.count) statement(s) failed, \(ran) ran.\n\n" + failures.prefix(5).joined(separator: "\n\n")) }
        return ran
    }
}

// MARK: Sheet

struct TransferSheet: View {
    enum Mode { case export, `import` }
    let mode: Mode
    let session: Session
    let done: () -> Void
    @State private var content = DumpContent.all
    @State private var format = DumpFormat.sql
    @State private var stopOnError = true
    @State private var file: URL?
    @State private var typed = ""
    @State private var running = false
    @State private var result: String?
    @State private var error: String?
    @State private var cancel = TransferCancel()
    @State private var started = Date()

    private var target: String { session.conn.kind == .sqlite ? session.conn.name : "\(session.conn.name) · \(session.conn.database)" }
    private var production: Bool { session.conn.isProduction == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .export ? "Export Database" : "Import Database").font(.headline)
            LabeledContent(mode == .export ? "From" : "Into") { Text(target).fontWeight(.medium) }
            if mode == .export {
                Picker("Format", selection: $format) { ForEach(DumpFormat.available(for: session.conn.kind)) { Text($0.rawValue).tag($0) } }
                if !(format == .backup && session.conn.kind == .sqlite) { // a SQLite backup is always the whole file
                    Picker("Content", selection: $content) { ForEach(DumpContent.allCases) { Text($0.rawValue).tag($0) } }
                }
                Text(formatNote).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text(file?.lastPathComponent ?? "No file chosen").foregroundStyle(file == nil ? .secondary : .primary).lineLimit(1)
                    Spacer()
                    Button("Choose…") { chooseFile() }.disabled(running)
                }
                Text(importNote).font(.caption).foregroundStyle(.secondary)
                Toggle("Stop at the first error", isOn: $stopOnError)
                if production {
                    // Imports can overwrite whole tables: on production, the database name must be typed.
                    TextField("Type \(session.conn.database) to confirm", text: $typed).textFieldStyle(.roundedBorder)
                }
            }
            if running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: started, by: 1)) { ctx in
                        Text("\(mode == .export ? "Exporting" : "Importing")… \(Int(ctx.date.timeIntervalSince(started)))s").foregroundStyle(.secondary)
                    }
                }
            }
            if let result { Text(result).font(.callout).textSelection(.enabled) }
            if let error { ScrollView { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160) }
            HStack {
                Spacer()
                if running {
                    Button("Cancel") { cancel.cancel() }
                } else {
                    Button(result == nil ? "Cancel" : "Close", action: done).keyboardShortcut(.cancelAction)
                    if result == nil {
                        Button(mode == .export ? "Export…" : "Import") { mode == .export ? startExport() : startImport() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(mode == .import && (file == nil || (production && typed != session.conn.database)))
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private var importNote: String {
        switch session.conn.kind {
        case .postgres: "SQL scripts and every pg_dump archive: custom (.dump, .backup, .bak), tar (.tar) or a directory archive folder. The format is read from the file, not its name."
        case .sqlite: "SQL scripts, or a SQLite database file / .bak to restore over this database."
        default: "SQL scripts (.sql, .bak)."
        }
    }

    private var formatNote: String {
        switch (session.conn.kind, format) {
        case (.postgres, .custom), (.postgres, .backup):
            "pg_dump custom archive (\(format == .custom ? ".dump" : ".bak") is only the name): compressed, restored with pg_restore, including into other PostgreSQL versions."
        case (.postgres, .tar): "pg_dump tar archive: uncompressed, restored with pg_restore."
        case (.postgres, .directory): "pg_dump directory archive: a folder with one compressed file per table, restored with pg_restore."
        case (.sqlite, .backup): "A consistent copy of the whole database file."
        case (.mysql, .backup): "Same SQL dump as .sql, with a .bak name."
        default: "Plain SQL statements, readable and editable; imports into this or another server version."
        }
    }

    private func chooseFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["sql", "bak", "dump", "backup", "tar", "db", "sqlite"].compactMap { .init(filenameExtension: $0) } + [.data]
        p.canChooseDirectories = session.conn.kind == .postgres // pg_dump directory archives
        if p.runModal() == .OK { file = p.url }
    }

    private func startExport() {
        let p = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)) + "-" +
            Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)).replacingOccurrences(of: ":", with: "")
        let base = session.conn.kind == .sqlite ? (session.conn.path as NSString).lastPathComponent : session.conn.database
        p.nameFieldStringValue = "\(base)-\(stamp)" + (format.ext.isEmpty ? "" : ".\(format.ext)")
        guard p.runModal() == .OK, let url = p.url else { return }
        go {
            try await session.exportDatabase(to: url, content: content, format: format, cancel: cancel)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return "Saved \(url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))"
        }
    }

    private func startImport() {
        guard let file else { return }
        go { try await session.importFile(file, stopOnError: stopOnError, cancel: cancel) }
    }

    private func go(_ work: @escaping () async throws -> String) {
        running = true; error = nil; result = nil; cancel = TransferCancel(); started = Date()
        Task {
            defer { running = false }
            do { result = try await work() + " in \(Int(Date().timeIntervalSince(started)))s" }
            catch { self.error = error.localizedDescription }
        }
    }
}
