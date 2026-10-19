import SwiftUI

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
