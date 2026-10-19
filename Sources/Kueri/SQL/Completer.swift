import SwiftUI

/// Suggests SQL keywords (or Redis commands), table names, and columns of the tables the query mentions.
@MainActor struct SQLCompleter {
    let session: Session

    nonisolated static let sqlKeywords = """
    SELECT FROM WHERE AND OR NOT NULL IS IN LIKE ILIKE BETWEEN EXISTS DISTINCT AS ON USING JOIN LEFT RIGHT INNER OUTER FULL CROSS \
    GROUP BY ORDER HAVING LIMIT OFFSET ASC DESC UNION ALL INSERT INTO VALUES UPDATE SET DELETE RETURNING WITH \
    CREATE ALTER DROP TRUNCATE TABLE INDEX VIEW COLUMN ADD PRIMARY KEY FOREIGN REFERENCES DEFAULT UNIQUE CHECK CONSTRAINT \
    CASE WHEN THEN ELSE END CAST COALESCE NULLIF COUNT SUM AVG MIN MAX NOW CURRENT_DATE CURRENT_TIMESTAMP TRUE FALSE \
    BEGIN COMMIT ROLLBACK EXPLAIN ANALYZE SHOW DESCRIBE INTERVAL LATERAL OVER PARTITION WINDOW \
    REPLACE FUNCTION PROCEDURE RETURNS LANGUAGE TRIGGER SCHEMA DATABASE SEQUENCE IF CASCADE RESTRICT \
    MATERIALIZED REFRESH GRANT REVOKE TO TEMPORARY
    """.split(separator: " ").map(String.init)
    /// Whether the end of `before` is inside a 'string' or a comment (no completion there).
    nonisolated static func insideLiteral(_ before: String) -> Bool {
        var inString = false, lineComment = false, blockComment = false
        let c = Array(before.utf16)
        var i = 0
        while i < c.count {
            let ch = c[i], next = i + 1 < c.count ? c[i + 1] : 0
            if lineComment { if ch == 10 { lineComment = false } }
            else if blockComment { if ch == 42 && next == 47 { blockComment = false; i += 1 } }
            else if inString { if ch == 39 { if next == 39 { i += 1 } else { inString = false } } }
            else if ch == 39 { inString = true }
            else if ch == 45 && next == 45 { lineComment = true; i += 1 }
            else if ch == 47 && next == 42 { blockComment = true; i += 1 }
            i += 1
        }
        return inString || lineComment || blockComment
    }

    nonisolated static let redisCommands = """
    GET SET DEL EXISTS EXPIRE TTL KEYS SCAN TYPE RENAME INCR DECR APPEND MGET MSET \
    HGET HSET HGETALL HDEL HKEYS HVALS HSCAN LPUSH RPUSH LPOP RPOP LRANGE LLEN SADD SREM SMEMBERS SSCAN SCARD \
    ZADD ZREM ZRANGE ZSCORE ZCARD XADD XRANGE XLEN INFO PING SELECT FLUSHDB DBSIZE CONFIG
    """.split(separator: " ").map(String.init)

    /// Tables referenced by the query, plus alias → table (`FROM users u`, `JOIN orders AS o`).
    /// Quoted names (`"public"."users"`, `` `shop`.`orders` ``) come back without their quotes.
    nonisolated static func referencedTables(_ sql: String) -> (tables: [String], aliases: [String: String]) {
        let part = #"(?:"[^"]+"|`[^`]+`|[A-Za-z_][\w]*)"#
        let re = try! NSRegularExpression(pattern: #"\b(?:from|join|update|into|table)\s+("# + part + #"(?:\."# + part + #")*)(?:\s+(?:as\s+)?([A-Za-z_]\w*))?"#,
                                          options: [.caseInsensitive])
        var tables: [String] = [], aliases: [String: String] = [:]
        let ns = sql as NSString
        for m in re.matches(in: sql, range: NSRange(location: 0, length: ns.length)) {
            let t = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "`", with: "")
            if !tables.contains(t) { tables.append(t) }
            if m.range(at: 2).location != NSNotFound {
                let a = ns.substring(with: m.range(at: 2))
                if !sqlKeywords.contains(a.uppercased()) { aliases[a.lowercased()] = t }
            }
        }
        return (tables, aliases)
    }

    /// The sidebar's name for a table written in the query: tables in the default schema are listed
    /// without it, so `public.users` is `users`.
    private func listed(_ t: String) -> String {
        if session.tables.contains(t) { return t }
        let last = t.split(separator: ".").last.map(String.init) ?? t
        return session.tables.contains(last) ? last : t
    }

    /// Candidates for the word being typed. `word` may be qualified (`u.na`, `users.na`).
    func candidates(for word: String, in sql: String, before: String) -> [String] {
        let redis = session.conn.kind == .redis
        let (refs, aliases) = Self.referencedTables(sql)
        let parts = word.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 2 { // qualified: columns of that table/alias
            let qualifier = parts.dropLast().joined(separator: ".")
            let table = aliases[qualifier.lowercased()] ?? session.tables.first { $0.caseInsensitiveCompare(qualifier) == .orderedSame } ?? qualifier
            return (session.completionColumns(listed(table)) ?? []).map(\.name)
        }
        if redis { return Self.redisCommands + session.tables }
        let columns = refs.flatMap { session.completionColumns(listed($0))?.map(\.name) ?? [] }
        // Right after FROM / JOIN / UPDATE / INTO a table name is the likely next word.
        let lastWord = before.split(whereSeparator: { !$0.isLetter && $0 != "_" }).last?.uppercased() ?? ""
        if ["FROM", "JOIN", "UPDATE", "INTO", "TABLE"].contains(lastWord) { return session.tables + Self.sqlKeywords }
        return columns + Self.sqlKeywords + session.tables
    }

    /// Best completion for `word`: the full replacement for the word, or nil. Keywords are always
    /// upper case (typing `fr` + Tab gives `FROM`); table and column names keep their real case.
    func best(for word: String, in sql: String, before: String) -> String? {
        let prefix = word.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? word
        // Right after "table." / "alias.": suggest that table's first column.
        if prefix.isEmpty { return word.hasSuffix(".") ? candidates(for: word, in: sql, before: before).first : nil }
        let keywords = Set(Self.sqlKeywords + Self.redisCommands)
        for c in candidates(for: word, in: sql, before: before) where c.count > prefix.count {
            guard c.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil else { continue }
            if keywords.contains(c) { return c.uppercased() }
            return c
        }
        return nil
    }
}
