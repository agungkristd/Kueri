import Foundation

/// SQL beautifier in the common style of SQL formatters: each clause keyword on its own line with
/// its content indented below it, one list item per line, AND / OR leading their lines, JOINs inside
/// FROM, subqueries formatted inside their parentheses, keywords in capitals. Strings, quoted names,
/// dollar-quoted bodies and comments are copied as they are, so the statement means the same.
enum SQLFormatter {
    private enum Kind { case word, string, quoted, comment, lineComment, number, open, close, comma, semicolon, dot, op }
    private struct Token { var text: String; let kind: Kind }

    private static let keywords = Set(SQLCompleter.sqlKeywords)
    /// Clause keywords: own line, content indented below.
    private static let clauses: Set<String> = ["SELECT", "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET",
                                               "VALUES", "SET", "RETURNING", "WITH", "INSERT", "UPDATE", "DELETE"]
    /// Set operators between queries: own line, nothing indented under them.
    private static let setOperators: Set<String> = ["UNION", "INTERSECT", "EXCEPT"]
    private static let joinStarts: Set<String> = ["JOIN", "LEFT", "RIGHT", "INNER", "FULL", "CROSS", "NATURAL"]
    /// Words that call like functions: no space before their "(".
    private static let functions: Set<String> = ["COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLIF", "CAST", "NOW", "EXISTS"]

    static func format(_ sql: String) -> String {
        var lines: [String] = []
        let tokens = tokenize(sql)
        // Statements one by one, a blank line between them.
        var start = 0
        for (i, t) in tokens.enumerated() where t.kind == .semicolon {
            emit(tokens[start..<i], base: 0, into: &lines)
            if !lines.isEmpty { lines[lines.count - 1] += ";" }
            lines.append("")
            start = i + 1
        }
        if start < tokens.count { emit(tokens[start...], base: 0, into: &lines) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }.joined(separator: "\n")
    }

    /// Formats one statement (or a parenthesised subquery) at indent level `base`.
    private static func emit(_ tokens: ArraySlice<Token>, base: Int, into lines: inout [String]) {
        let toks = Array(tokens)
        var line = "", clause = "", betweenPending = false
        var depth = 0
        var columnParens: Set<Int> = []    // CREATE TABLE column lists: one column per line
        var prev: Token?, lastWord = ""
        let body = base + 1                // content under a clause keyword

        func pad(_ level: Int) -> String { String(repeating: "  ", count: max(0, level)) }
        func flush() { if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }; line = "" }
        func start(_ level: Int) { flush(); line = pad(level) }
        func put(_ text: String, space: Bool) {
            if line.isEmpty { line = pad(base) }
            if space, !line.hasSuffix(" "), !line.allSatisfy({ $0 == " " }) { line += " " }
            line += text
        }

        var i = 0
        while i < toks.count {
            var t = toks[i]
            if t.kind == .word, keywords.contains(t.text.uppercased()) { t.text = t.text.uppercased() }
            let upper = t.kind == .word ? t.text.uppercased() : ""
            let next = i + 1 < toks.count ? toks[i + 1] : nil
            let tight = prev?.kind == .dot || prev?.kind == .open || prev?.text == "::"

            if depth == 0, t.kind == .word, clauses.contains(upper) {
                // GROUP BY / ORDER BY / INSERT INTO / DELETE FROM stay together on the keyword line.
                var keyword = upper
                if ["GROUP", "ORDER"].contains(upper), next?.text.uppercased() == "BY" { keyword += " BY"; i += 1 }
                if upper == "INSERT", next?.text.uppercased() == "INTO" { keyword += " INTO"; i += 1 }
                if upper == "DELETE", next?.text.uppercased() == "FROM" { keyword += " FROM"; i += 1 }
                start(base); line += keyword
                clause = upper
                start(body)
            } else if depth == 0, t.kind == .word, setOperators.contains(upper) {
                var keyword = upper
                if next?.text.uppercased() == "ALL" { keyword += " ALL"; i += 1 }
                start(base); line += keyword
                clause = ""
                flush()
            } else if depth == 0, t.kind == .word, joinStarts.contains(upper),
                      !(upper == "JOIN" && ["LEFT", "RIGHT", "INNER", "FULL", "CROSS", "NATURAL", "OUTER"].contains(lastWord)) {
                start(body); line += upper
                clause = "JOIN"
            } else if depth == 0, t.kind == .word, upper == "AND" || upper == "OR",
                      ["WHERE", "HAVING", "JOIN", "ON"].contains(clause) {
                if upper == "AND" && betweenPending { betweenPending = false; put(upper, space: true) }
                else { start(body + (clause == "ON" ? 1 : 0)); line += upper }
            } else {
                switch t.kind {
                case .word:
                    if upper == "BETWEEN" { betweenPending = true }
                    if upper == "ON", clause == "JOIN" { clause = "ON" }
                    put(t.text, space: !tight)
                case .open:
                    // A subquery: formatted on its own lines inside the parentheses.
                    if ["SELECT", "WITH"].contains(next?.text.uppercased() ?? ""), let close = matching(toks, from: i) {
                        put("(", space: !tight)
                        let level = line.prefix { $0 == " " }.count / 2
                        flush()
                        emit(toks[(i + 1)..<close], base: level + 1, into: &lines)
                        line = pad(level) + ")"
                        prev = toks[close]
                        i = close + 1
                        continue
                    }
                    let columns = createTableColumns(toks, before: i)
                    let intoList = (i >= 2 && toks[i - 2].text.uppercased() == "INTO") || clause == "INSERT"
                    let call = !columns && !intoList && (prev.map { $0.kind == .word && (!keywords.contains($0.text.uppercased()) || functions.contains($0.text.uppercased())) } ?? false)
                    put("(", space: !call && !tight)
                    depth += 1
                    if columns { columnParens.insert(depth); start(base + depth) }
                case .close:
                    if columnParens.contains(depth) { columnParens.remove(depth); start(base + depth - 1) }
                    depth = max(0, depth - 1)
                    if line.isEmpty { line = pad(base) }
                    line += ")"
                case .comma:
                    line += ","
                    if columnParens.contains(depth) { start(base + depth) }
                    else if depth == 0, !clause.isEmpty, clause != "LIMIT", clause != "OFFSET" { start(body) }
                case .lineComment:
                    put(t.text, space: true)
                    start(clause.isEmpty ? base : body)
                case .dot:
                    line += "."
                case .op:
                    if t.text == "::" { line += "::" } else { put(t.text, space: !tight) }
                default:
                    put(t.text, space: !tight)
                }
            }
            if t.kind == .word { lastWord = upper }
            prev = t
            i += 1
        }
        flush()
    }

    /// Index of the ")" matching the "(" at `open`.
    private static func matching(_ toks: [Token], from open: Int) -> Int? {
        var depth = 0
        for j in open..<toks.count {
            if toks[j].kind == .open { depth += 1 }
            if toks[j].kind == .close { depth -= 1; if depth == 0 { return j } }
        }
        return nil
    }

    /// `CREATE TABLE <name> (`: the name may be schema-qualified or quoted.
    private static func createTableColumns(_ toks: [Token], before i: Int) -> Bool {
        var j = i - 1
        while j >= 0, [.word, .quoted, .dot].contains(toks[j].kind), toks[j].text.uppercased() != "TABLE" { j -= 1 }
        return j >= 1 && toks[j].text.uppercased() == "TABLE" && toks[j - 1].text.uppercased() == "CREATE"
    }

    private static func tokenize(_ sql: String) -> [Token] {
        let c = Array(sql)
        var out: [Token] = [], i = 0
        func isWordChar(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" || ch == "$" }
        while i < c.count {
            let ch = c[i]
            if ch.isWhitespace { i += 1; continue }
            if ch == "-", i + 1 < c.count, c[i + 1] == "-" || ch == "#" {
                var j = i; while j < c.count, c[j] != "\n" { j += 1 }
                out.append(Token(text: String(c[i..<j]), kind: .lineComment)); i = j
            } else if ch == "/", i + 1 < c.count, c[i + 1] == "*" {
                var j = i + 2; while j + 1 < c.count, !(c[j] == "*" && c[j + 1] == "/") { j += 1 }
                j = min(j + 2, c.count)
                out.append(Token(text: String(c[i..<j]), kind: .comment)); i = j
            } else if ch == "'" || ch == "\"" || ch == "`" {
                var j = i + 1
                while j < c.count { if c[j] == ch { if j + 1 < c.count, c[j + 1] == ch { j += 2; continue }; break }; j += 1 }
                j = min(j + 1, c.count)
                out.append(Token(text: String(c[i..<j]), kind: ch == "'" ? .string : .quoted)); i = j
            } else if ch == "$", let end = dollarBody(c, i) { // $$ … $$ / $tag$ … $tag$ bodies stay untouched
                out.append(Token(text: String(c[i..<end]), kind: .string)); i = end
            } else if ch.isNumber {
                var j = i; while j < c.count, c[j].isNumber || c[j] == "." { j += 1 }
                out.append(Token(text: String(c[i..<j]), kind: .number)); i = j
            } else if isWordChar(ch) {
                var j = i; while j < c.count, isWordChar(c[j]) { j += 1 }
                out.append(Token(text: String(c[i..<j]), kind: .word)); i = j
            } else if ch == "(" { out.append(Token(text: "(", kind: .open)); i += 1 }
            else if ch == ")" { out.append(Token(text: ")", kind: .close)); i += 1 }
            else if ch == "," { out.append(Token(text: ",", kind: .comma)); i += 1 }
            else if ch == ";" { out.append(Token(text: ";", kind: .semicolon)); i += 1 }
            else if ch == "." { out.append(Token(text: ".", kind: .dot)); i += 1 }
            else {
                var j = i
                while j < c.count, "<>=!|&+-*/%:^~@#?".contains(c[j]) {
                    if j > i, c[j] == "-", j + 1 < c.count, c[j + 1] == "-" { break } // "--" starts a comment
                    j += 1
                }
                if j == i { j += 1 }
                out.append(Token(text: String(c[i..<j]), kind: .op)); i = j
            }
        }
        return out
    }

    /// End index of a dollar-quoted body starting at `i`, or nil if it isn't one.
    private static func dollarBody(_ c: [Character], _ i: Int) -> Int? {
        var j = i + 1
        while j < c.count, c[j].isLetter || c[j] == "_" { j += 1 }
        guard j < c.count, c[j] == "$" else { return nil }
        let tag = String(c[i...j])
        let rest = String(c[(j + 1)...])
        guard let r = rest.range(of: tag) else { return c.count }
        return j + 1 + rest.distance(from: rest.startIndex, to: r.upperBound)
    }
}
