import SwiftUI

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
            guard let text = try? output(tool, ["--version"]) else { continue }
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
        return try await Task.detached { try output(tool, ["--list", url.path]) }.value
    }

    /// A tool's standard output (errors discarded), once it has exited.
    nonisolated static func output(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text
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
