import SwiftUI

/// Unsaved work in the table details (right panel). Grid edits are keyed by row → result column; rows past the
/// loaded ones are new (not yet created) columns / indexes.
struct TableDraft {
    var table = ""
    var columnEdits: [Int: [Int: String?]] = [:]
    var newColumns = 0
    var indexEdits: [Int: [Int: String?]] = [:]
    var newIndexes = 0
    var isEmpty: Bool { columnEdits.isEmpty && newColumns == 0 && indexEdits.isEmpty && newIndexes == 0 }
}

/// A column type picked from a list (no free text): a base type plus, for types that take one,
/// a length / precision written as digits.
struct ColumnType: Equatable {
    var base: String
    var arguments = ""

    /// Postgres' own short names, as its data_type column shows them.
    static let postgres = ["bool", "bytea", "char", "cidr", "date", "float4", "float8", "inet", "int2", "int4", "int8", "interval",
                           "json", "jsonb", "macaddr", "money", "numeric", "text", "time", "timestamp", "timestamptz", "timetz",
                           "uuid", "varchar", "xml", "_int4", "_int8", "_text", "_varchar"]
    static let mysql = ["tinyint", "smallint", "int", "int unsigned", "bigint", "bigint unsigned", "decimal", "float", "double",
                        "bit", "char", "varchar", "tinytext", "text", "mediumtext", "longtext", "binary", "varbinary", "blob",
                        "mediumblob", "longblob", "date", "time", "datetime", "timestamp", "year", "json"]
    static let withArguments: Set<String> = ["numeric", "decimal", "character varying", "character", "char", "varchar", "bit",
                                             "varbit", "binary", "varbinary"]

    static let sqlite = ["INTEGER", "TEXT", "REAL", "NUMERIC", "BLOB"]

    /// How the structure's full_type column spells a type: Postgres' long names ("int8" → "bigint").
    static func fullName(_ type: String, kind: Conn.Kind) -> String {
        guard kind == .postgres else { return type }
        let long = ["int2": "smallint", "int4": "integer", "int8": "bigint", "float4": "real", "float8": "double precision",
                    "bool": "boolean", "varchar": "character varying", "char": "character", "timestamp": "timestamp without time zone",
                    "timestamptz": "timestamp with time zone", "time": "time without time zone", "timetz": "time with time zone"]
        if type.hasSuffix("[]") { return fullName(String(type.dropLast(2)), kind: kind) + "[]" }
        let t = ColumnType(type)
        let base = long[t.base] ?? t.base
        return t.arguments.isEmpty ? base : "\(base)(\(t.arguments))"
    }

    static func names(_ kind: Conn.Kind) -> [String] { kind == .mysql ? mysql : kind == .sqlite ? sqlite : postgres }

    /// A type picked by name from the grid menu, as SQL: Postgres arrays use their `[]` spelling, and MySQL
    /// varchar/varbinary (which need a length) keep the previous length, or get 255.
    static func resolved(_ picked: String, previous: String, kind: Conn.Kind) -> String {
        if kind == .postgres, picked.hasPrefix("_") { return String(picked.dropFirst()) + "[]" }
        guard kind == .mysql, ["varchar", "varbinary"].contains(picked) else { return picked }
        let old = ColumnType(previous)
        return "\(picked)(\(old.takesArguments && !old.arguments.isEmpty ? old.arguments.split(separator: ",")[0] : "255"))"
    }

    var takesArguments: Bool { Self.withArguments.contains(base) }
    var argumentsValid: Bool { arguments.isEmpty || arguments.range(of: #"^\d+(,\d+)?$"#, options: .regularExpression) != nil }
    var sql: String { takesArguments && !arguments.isEmpty ? "\(base)(\(arguments))" : base }

    init(base: String, arguments: String = "") { (self.base, self.arguments) = (base, arguments) }

    init(_ type: String) {
        // "character varying(200)" → base + "200"; anything else (e.g. "timestamp(6) without time zone") stays whole.
        if let m = type.range(of: #"^([a-z ]+)\(([0-9, ]+)\)$"#, options: .regularExpression), m == type.startIndex..<type.endIndex,
           let open = type.firstIndex(of: "("), Self.withArguments.contains(String(type[..<open])) {
            base = String(type[..<open])
            arguments = type[type.index(after: open)...].dropLast().replacingOccurrences(of: " ", with: "")
        } else {
            base = type
        }
    }

    /// The dialect's list, with the column's current type kept as an option when it isn't in it.
    static func choices(_ kind: Conn.Kind, current: String) -> [String] {
        let list = names(kind)
        let base = ColumnType(current).base
        return list.contains(base) ? list : [base] + list
    }
}

/// A column as the edit form sees it, read from a `structure()` row.
struct ColumnDef: Equatable {
    var name = "", type = "", nullable = true, defaultSQL = "", extra = "", comment = ""

    init(name: String, type: String, nullable: Bool = true, defaultSQL: String = "", extra: String = "", comment: String = "") {
        (self.name, self.type, self.nullable, self.defaultSQL, self.extra, self.comment) = (name, type, nullable, defaultSQL, extra, comment)
    }

    init(row: [String?], header: [String]) {
        // MySQL 8 reports information_schema names in capitals (COLUMN_NAME).
        func v(_ k: String) -> String? { header.firstIndex { $0.lowercased() == k }.flatMap { row.indices.contains($0) ? row[$0] : nil } }
        name = v("column_name") ?? ""
        type = v("full_type") ?? v("data_type") ?? ""
        nullable = (v("is_nullable") ?? "YES") != "NO"
        let rawExtra = v("extra") ?? ""
        let generated = rawExtra.contains("DEFAULT_GENERATED") // MySQL: the default is an expression
        extra = rawExtra.replacingOccurrences(of: "DEFAULT_GENERATED", with: "").trimmingCharacters(in: .whitespaces)
        comment = v("comment") ?? ""
        if let d = v("column_default") {
            // Postgres/SQLite store an SQL expression already; MySQL stores plain literal text.
            defaultSQL = header.contains(where: { $0.lowercased() == "extra" }) && !generated ? "'" + d.replacingOccurrences(of: "'", with: "''") + "'" : d
        }
    }
}

/// ⌃ + scroll zooms; ⇧ + scroll with a plain mouse wheel (vertical only) scrolls sideways.
