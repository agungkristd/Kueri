import SwiftUI

// MARK: Completion source

/// Suggests SQL keywords (or Redis commands), table names, and columns of the tables the query mentions.
@MainActor struct SQLCompleter {
    let session: Session

    nonisolated static let sqlKeywords = """
    SELECT FROM WHERE AND OR NOT NULL IS IN LIKE ILIKE BETWEEN EXISTS DISTINCT AS ON USING JOIN LEFT RIGHT INNER OUTER FULL CROSS \
    GROUP BY ORDER HAVING LIMIT OFFSET ASC DESC UNION ALL INSERT INTO VALUES UPDATE SET DELETE RETURNING WITH \
    CREATE ALTER DROP TRUNCATE TABLE INDEX VIEW COLUMN ADD PRIMARY KEY FOREIGN REFERENCES DEFAULT UNIQUE CHECK CONSTRAINT \
    CASE WHEN THEN ELSE END CAST COALESCE NULLIF COUNT SUM AVG MIN MAX NOW CURRENT_DATE CURRENT_TIMESTAMP TRUE FALSE \
    BEGIN COMMIT ROLLBACK EXPLAIN ANALYZE SHOW DESCRIBE INTERVAL LATERAL OVER PARTITION WINDOW
    """.split(separator: " ").map(String.init)
    nonisolated static let redisCommands = """
    GET SET DEL EXISTS EXPIRE TTL KEYS SCAN TYPE RENAME INCR DECR APPEND MGET MSET \
    HGET HSET HGETALL HDEL HKEYS HVALS HSCAN LPUSH RPUSH LPOP RPOP LRANGE LLEN SADD SREM SMEMBERS SSCAN SCARD \
    ZADD ZREM ZRANGE ZSCORE ZCARD XADD XRANGE XLEN INFO PING SELECT FLUSHDB DBSIZE CONFIG
    """.split(separator: " ").map(String.init)

    /// Tables referenced by the query, plus alias → table (`FROM users u`, `JOIN orders AS o`).
    nonisolated static func referencedTables(_ sql: String) -> (tables: [String], aliases: [String: String]) {
        let re = try! NSRegularExpression(pattern: #"\b(?:from|join|update|into|table)\s+([A-Za-z_][\w.]*)(?:\s+(?:as\s+)?([A-Za-z_]\w*))?"#,
                                          options: [.caseInsensitive])
        var tables: [String] = [], aliases: [String: String] = [:]
        let ns = sql as NSString
        for m in re.matches(in: sql, range: NSRange(location: 0, length: ns.length)) {
            let t = ns.substring(with: m.range(at: 1))
            if !tables.contains(t) { tables.append(t) }
            if m.range(at: 2).location != NSNotFound {
                let a = ns.substring(with: m.range(at: 2))
                if !sqlKeywords.contains(a.uppercased()) { aliases[a.lowercased()] = t }
            }
        }
        return (tables, aliases)
    }

    /// Candidates for the word being typed. `word` may be qualified (`u.na`, `users.na`).
    func candidates(for word: String, in sql: String, before: String) -> [String] {
        let redis = session.conn.kind == .redis
        let (refs, aliases) = Self.referencedTables(sql)
        let parts = word.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 2 { // qualified: columns of that table/alias
            let qualifier = parts.dropLast().joined(separator: ".")
            let table = aliases[qualifier.lowercased()] ?? session.tables.first { $0.caseInsensitiveCompare(qualifier) == .orderedSame } ?? qualifier
            return (session.completionColumns(table) ?? []).map(\.name)
        }
        if redis { return Self.redisCommands + session.tables }
        let columns = refs.flatMap { session.completionColumns($0)?.map(\.name) ?? [] }
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

// MARK: Editor view

/// NSTextView-based SQL editor with inline (ghost) completion: Tab accepts, Esc dismisses,
/// ⌥Esc shows the full list.
struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    let completer: SQLCompleter
    var cacheVersion = 0 // changes when columns finish loading, so the suggestion can appear right away

    final class TextView: NSTextView {
        var ghost: String?            // remaining characters of the suggestion, drawn after the caret
        var pending: (range: NSRange, replacement: String)?
        var suggest: (String, String, String) -> String? = { _, _, _ in nil } // (word, sql, textBefore) → full word
        var list: (String, String, String) -> [String] = { _, _, _ in [] }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let ghost, let lm = layoutManager, let tc = textContainer else { return }
            let caret = selectedRange().location
            var rect: NSRect
            if caret > 0 {
                let g = lm.glyphRange(forCharacterRange: NSRange(location: caret - 1, length: 1), actualCharacterRange: nil)
                rect = lm.boundingRect(forGlyphRange: g, in: tc)
                rect.origin.x = rect.maxX
            } else {
                rect = lm.extraLineFragmentRect
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: font ?? .monospacedSystemFont(ofSize: 13, weight: .regular),
                                                        .foregroundColor: NSColor.tertiaryLabelColor]
            (ghost as NSString).draw(at: NSPoint(x: rect.minX + textContainerOrigin.x, y: rect.minY + textContainerOrigin.y), withAttributes: attrs)
        }

        /// The identifier-ish word ending at the caret (letters, digits, `_`, `.`).
        func wordBeforeCaret() -> NSRange? {
            let caret = selectedRange()
            guard caret.length == 0 else { return nil }
            let s = string as NSString
            if caret.location < s.length, let next = Unicode.Scalar(s.character(at: caret.location)),
               CharacterSet.alphanumerics.contains(next) || next == "_" { return nil } // mid-word: no ghost
            var start = caret.location
            while start > 0, let c = Unicode.Scalar(s.character(at: start - 1)),
                  CharacterSet.alphanumerics.contains(c) || c == "_" || c == "." { start -= 1 }
            return start < caret.location ? NSRange(location: start, length: caret.location - start) : nil
        }

        func refreshGhost() {
            let old = ghost
            ghost = nil; pending = nil
            if let r = wordBeforeCaret() {
                let s = string as NSString
                let word = s.substring(with: r), before = s.substring(to: r.location)
                if let full = suggest(word, string, before) {
                    let last = word.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? word
                    let replaceRange = NSRange(location: r.location + r.length - last.utf16.count, length: last.utf16.count)
                    pending = (replaceRange, full)
                    ghost = String(full.dropFirst(last.count))
                }
            }
            if old != ghost { needsDisplay = true }
        }

        func acceptGhost() -> Bool {
            guard let p = pending else { return false }
            if shouldChangeText(in: p.range, replacementString: p.replacement) { // undoable
                replaceCharacters(in: p.range, with: p.replacement)
                didChangeText()
            }
            ghost = nil; pending = nil; needsDisplay = true
            return true
        }

        override func doCommand(by selector: Selector) {
            if selector == #selector(insertTab(_:)), acceptGhost() { return }
            if selector == #selector(cancelOperation(_:)), ghost != nil { ghost = nil; pending = nil; needsDisplay = true; return }
            super.doCommand(by: selector)
        }

        override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
            super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
            if ghost != nil { ghost = nil; pending = nil; needsDisplay = true } // caret moved: drop the suggestion
        }

        // ⌥Esc / F5: the system completion list, fed by the same candidates.
        override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
            let s = string as NSString
            let word = s.substring(with: charRange)
            var start = charRange.location // extend left over "qualifier." so columns of that table are listed
            while start > 0, let c = Unicode.Scalar(s.character(at: start - 1)),
                  CharacterSet.alphanumerics.contains(c) || c == "_" || c == "." { start -= 1 }
            let qualified = s.substring(with: NSRange(location: start, length: charRange.location + charRange.length - start))
            let found = list(qualified, string, s.substring(to: start))
                .filter { word.isEmpty || $0.range(of: word, options: [.caseInsensitive, .anchored]) != nil }
            return found.isEmpty ? nil : Array(NSOrderedSet(array: found).array as! [String])
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditor
        var seenCacheVersion = 0
        init(_ p: SQLEditor) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? TextView else { return }
            parent.text = tv.string
            tv.refreshGhost()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = TextView.scrollableTextView()
        let old = sv.documentView as! NSTextView
        let tv = TextView(frame: old.frame, textContainer: old.textContainer)
        tv.autoresizingMask = old.autoresizingMask
        tv.isVerticallyResizable = true
        tv.minSize = old.minSize; tv.maxSize = old.maxSize
        sv.documentView = tv
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.delegate = context.coordinator
        tv.string = text
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = sv.documentView as? TextView else { return }
        let c = completer
        tv.suggest = { w, sql, before in c.best(for: w, in: sql, before: before) }
        tv.list = { w, sql, before in c.candidates(for: w, in: sql, before: before) }
        if tv.string != text { tv.string = text; tv.ghost = nil; tv.pending = nil } // set from outside (sidebar click)
        else if context.coordinator.seenCacheVersion != cacheVersion, tv.window?.firstResponder === tv { tv.refreshGhost() }
        context.coordinator.seenCacheVersion = cacheVersion
    }
}

extension Session {
    /// Cached columns for completion; fetched in the background on first use (nil until loaded).
    func completionColumns(_ table: String) -> [ColumnInfo]? {
        if let c = columnCache[table] { return c }
        guard tables.contains(table), !columnCacheLoading.contains(table) else { return nil }
        columnCacheLoading.insert(table)
        columns(table) { [weak self] cols in
            self?.columnCache[table] = cols
            self?.columnCacheLoading.remove(table)
        }
        return nil
    }
}
