import Foundation

/// Splits SQL into statements on `;`, ignoring semicolons inside quotes, identifiers and comments.
/// `DELIMITER xx` lines (MySQL dump style) change the separator. Comments stay inside statements,
/// so MySQL's executable `/*! ... */` comments still run. `#` starts a comment only in MySQL
/// (in Postgres it's an operator, e.g. `jsonb #> '{a}'`).
func splitSQL(_ sql: String, hashComments: Bool = false) -> [String] {
    var out: [String] = [], cur = "", delimiter = ";"
    let chars = Array(sql)
    var i = 0
    func flush() {
        let s = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { out.append(s) }
        cur = ""
    }
    while i < chars.count {
        let c = chars[i]
        // DELIMITER directive at the start of a line
        if c == "D" || c == "d", cur.trimmingCharacters(in: .whitespaces).isEmpty || cur.hasSuffix("\n") {
            let rest = String(chars[i...].prefix(10)).uppercased()
            if rest.hasPrefix("DELIMITER ") {
                var j = i + 10
                var d = ""
                while j < chars.count, chars[j] != "\n" { d.append(chars[j]); j += 1 }
                flush()
                delimiter = d.trimmingCharacters(in: .whitespaces).isEmpty ? ";" : d.trimmingCharacters(in: .whitespaces)
                i = j
                continue
            }
        }
        if c == "'" || c == "\"" || c == "`" { // quoted: copy through the closing quote (doubled quotes escape)
            cur.append(c); i += 1
            while i < chars.count {
                cur.append(chars[i])
                if chars[i] == "\\", c != "`", i + 1 < chars.count { i += 1; cur.append(chars[i]) }
                else if chars[i] == c {
                    if i + 1 < chars.count, chars[i + 1] == c { i += 1; cur.append(chars[i]) } else { break }
                }
                i += 1
            }
            i += 1
            continue
        }
        if (c == "-" && i + 1 < chars.count && chars[i + 1] == "-") || (hashComments && c == "#") { // line comment
            while i < chars.count, chars[i] != "\n" { cur.append(chars[i]); i += 1 }
            continue
        }
        if c == "/", i + 1 < chars.count, chars[i + 1] == "*" { // block comment
            while i < chars.count, !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/") { cur.append(chars[i]); i += 1 }
            if i < chars.count { cur.append("*/"); i += 2 }
            continue
        }
        if c == "$", let tag = dollarTag(chars, i) { // Postgres $$ / $tag$ bodies
            let closing = Array(tag)
            cur.append(contentsOf: tag); i += closing.count
            while i < chars.count, !(Array(chars[i..<min(i + closing.count, chars.count)]) == closing) { cur.append(chars[i]); i += 1 }
            if i < chars.count { cur.append(contentsOf: tag); i += closing.count }
            continue
        }
        if chars[i...].starts(with: delimiter) {
            flush()
            i += delimiter.count
            continue
        }
        cur.append(c)
        i += 1
    }
    flush()
    return out
}

private func dollarTag(_ chars: [Character], _ i: Int) -> String? {
    var j = i + 1
    while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
    guard j < chars.count, chars[j] == "$" else { return nil }
    return String(chars[i...j])
}

/// Words of a statement with strings and comments removed, upper-cased.
private func keywords(_ statement: String) -> [String] {
    var plain = "", chars = Array(statement), i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "'" || c == "\"" || c == "`" {
            i += 1
            while i < chars.count, chars[i] != c { i += 1 }
            i += 1; plain.append(" "); continue
        }
        if c == "-", i + 1 < chars.count, chars[i + 1] == "-" { while i < chars.count, chars[i] != "\n" { i += 1 }; continue }
        if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
            while i < chars.count, !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/") { i += 1 }
            i += 2; continue
        }
        plain.append(c); i += 1
    }
    return plain.uppercased().split(whereSeparator: { !$0.isLetter && $0 != "_" }).map(String.init)
}

/// Why a query is risky on a production database (empty = fine to run without asking).
func riskyReasons(_ text: String, kind: Conn.Kind) -> [String] {
    if kind == .redis {
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let words = line.split(whereSeparator: \.isWhitespace).map { $0.uppercased() }
            guard let cmd = words.first else { return nil }
            switch cmd {
            case "FLUSHDB", "FLUSHALL", "SHUTDOWN": return "\(cmd) deletes or stops everything"
            case "DEL", "UNLINK": return "\(cmd) deletes keys"
            case "CONFIG" where words.dropFirst().first == "SET": return "CONFIG SET changes the server configuration"
            default: return nil
            }
        }
    }
    var reasons: [String] = []
    for statement in splitSQL(text, hashComments: kind == .mysql) {
        let w = keywords(statement)
        guard let first = w.first else { continue }
        switch first {
        case "DELETE" where !w.contains("WHERE"): reasons.append("DELETE without WHERE removes every row")
        case "UPDATE" where !w.contains("WHERE"): reasons.append("UPDATE without WHERE changes every row")
        case "DROP": reasons.append("DROP \(w.dropFirst().first ?? "") removes it permanently")
        case "TRUNCATE": reasons.append("TRUNCATE removes every row")
        case "ALTER" where w.contains("DROP"): reasons.append("ALTER … DROP removes part of the schema")
        default: break
        }
    }
    return reasons
}

/// A question the workspace must ask before running something (production safety).
struct PendingConfirm: Identifiable {
    let id = UUID()
    let title: String
    let details: [String]
    let button: String
    let action: () -> Void
}

/// A hand-written `SELECT * FROM one_table [WHERE …] [ORDER BY …] [LIMIT …] [OFFSET …]`. Its rows stay
/// editable, and header sorting and paging rewrite it in place, so WHERE and ORDER BY are kept.
enum SimpleSelect {
    private static let part = #"(?:"[^"]+"|`[^`]+`|[A-Za-z_]\w*)"#
    private static func clean(_ sql: String) -> String {
        sql.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
    }
    private static func match(_ pattern: String, _ s: String) -> NSTextCheckingResult? {
        try! NSRegularExpression(pattern: pattern, options: .caseInsensitive).firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    /// The table it reads (quotes removed), or nil when the query is anything more than that.
    static func table(_ sql: String) -> String? {
        let s = clean(sql)
        guard !s.contains(";"),
              let m = match(#"^select\s+\*\s+from\s+("# + part + #"(?:\."# + part + #")?)(?:\s+(?:where|order\s+by|limit|offset)\b[\s\S]*)?$"#, s),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        let lower = s.lowercased()
        guard !["join", "group by", "union", "having", "returning", "for update", "into"].contains(where: { lower.range(of: "\\b\($0)\\b", options: .regularExpression) != nil })
        else { return nil }
        return s[r].replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "`", with: "")
    }

    /// Sorted by `column` (already quoted), replacing any ORDER BY; LIMIT and OFFSET stay last.
    static func sorted(_ sql: String, by column: String, ascending: Bool) -> String {
        var s = clean(sql).replacingOccurrences(of: #"\s+order\s+by\s+[\s\S]*?(?=\s+limit\b|\s+offset\b|$)"#, with: "",
                                                options: [.regularExpression, .caseInsensitive])
        let order = " ORDER BY \(column) \(ascending ? "ASC" : "DESC")"
        if let r = s.range(of: #"\s+(limit|offset)\b"#, options: [.regularExpression, .caseInsensitive]) { s.insert(contentsOf: order, at: r.lowerBound) }
        else { s += order }
        return s
    }

    /// Its ORDER BY when that is one column: the column (quotes removed) and direction.
    static func sort(_ sql: String) -> (column: String, ascending: Bool)? {
        let s = clean(sql)
        guard let m = match(#"\border\s+by\s+("# + part + #")(?:\s+(asc|desc))?\s*(?:$|\blimit\b|\boffset\b)"#, s),
              let c = Range(m.range(at: 1), in: s) else { return nil }
        let dir = Range(m.range(at: 2), in: s).map { s[$0].lowercased() }
        return (s[c].replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "`", with: ""), dir != "desc")
    }

    static func offset(_ sql: String) -> Int? {
        let s = clean(sql)
        return match(#"\boffset\s+(\d+)\s*$"#, s).flatMap { Range($0.range(at: 1), in: s) }.flatMap { Int(s[$0]) }
    }

    /// The same query on another page, or nil when it has no trailing OFFSET to change.
    static func paged(_ sql: String, offset: Int) -> String? {
        let s = clean(sql)
        guard let m = match(#"\boffset\s+\d+\s*$"#, s), let r = Range(m.range, in: s) else { return nil }
        return s.replacingCharacters(in: r, with: "OFFSET \(offset)")
    }
}
