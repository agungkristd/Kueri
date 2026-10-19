import SwiftUI

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
