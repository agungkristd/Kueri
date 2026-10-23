import SwiftUI

/// Syntax colours for the editor, applied as layout-manager temporary attributes: the text, its
/// undo history and what gets run are untouched. Same palette as the history list.
/// Saturated enough to tell the kinds apart at a glance (the Xcode hues, which Mac developers
/// already read fluently); identifiers keep the normal text colour, so most of a query stays calm.
enum SQLHighlighter {
    private static func tone(light: UInt32, dark: UInt32) -> NSColor {
        func c(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? c(dark) : c(light) }
    }
    static let keyword = tone(light: 0x9B2393, dark: 0xFF7AB2)    // magenta
    static let string = tone(light: 0xC41A16, dark: 0xFF8170)     // red
    static let number = tone(light: 0x1C00CF, dark: 0xD9C97C)     // blue / yellow
    static let type = tone(light: 0x0B4F79, dark: 0x5DD8FF)       // teal / cyan
    static let comment = tone(light: 0x5D6C79, dark: 0x7F8C98)
    static let identifier = NSColor.textColor                     // quoted names read as plain text
    // Limitation: re-colours the whole text on each change; fine for editor-sized SQL, skipped above 200 KB
    static let maxLength = 200_000

    private static let keywords = Set(SQLCompleter.sqlKeywords + SQLCompleter.redisCommands)
    private static let types: Set<String> = Set(ColumnType.postgres + ColumnType.mysql + ColumnType.sqlite
        + ["serial", "bigserial", "smallserial", "integer", "boolean", "timestamptz", "decimal", "datetime", "character", "varying", "double", "precision"])
        .reduce(into: []) { $0.insert($1.lowercased()) }

    /// Coloured ranges of `s` (UTF-16 offsets).
    static func ranges(_ s: NSString) -> [(NSRange, NSColor)] {
        var out: [(NSRange, NSColor)] = []
        let n = s.length
        var i = 0
        func ch(_ k: Int) -> unichar { k < n ? s.character(at: k) : 0 }
        func isWord(_ c: unichar) -> Bool { c == 95 || (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c > 127 }
        while i < n {
            let c = ch(i)
            if c == 45, ch(i + 1) == 45 || c == 35 { // -- comment (and # for MySQL)
                var j = i; while j < n, ch(j) != 10 { j += 1 }
                out.append((NSRange(location: i, length: j - i), comment)); i = j
            } else if c == 47, ch(i + 1) == 42 { // /* comment */
                var j = i + 2; while j < n, !(ch(j) == 42 && ch(j + 1) == 47) { j += 1 }
                j = min(j + 2, n)
                out.append((NSRange(location: i, length: j - i), comment)); i = j
            } else if c == 39 || c == 34 || c == 96 { // 'string', "identifier", `identifier`
                var j = i + 1
                while j < n { if ch(j) == c { if ch(j + 1) == c { j += 2; continue }; break }; j += 1 }
                j = min(j + 1, n)
                if c == 39 { out.append((NSRange(location: i, length: j - i), string)) } // quoted names stay plain
                i = j
            } else if c >= 48 && c <= 57, i == 0 || !isWord(ch(i - 1)) {
                var j = i; while j < n, (ch(j) >= 48 && ch(j) <= 57) || ch(j) == 46 { j += 1 }
                out.append((NSRange(location: i, length: j - i), number)); i = j
            } else if isWord(c) {
                var j = i; while j < n, isWord(ch(j)) { j += 1 }
                let w = s.substring(with: NSRange(location: i, length: j - i))
                if keywords.contains(w.uppercased()) { out.append((NSRange(location: i, length: j - i), keyword)) }
                else if types.contains(w.lowercased()) { out.append((NSRange(location: i, length: j - i), type)) }
                i = j
            } else { i += 1 }
        }
        return out
    }

    @MainActor static func apply(to tv: NSTextView) {
        guard let lm = tv.layoutManager else { return }
        let s = tv.string as NSString
        let all = NSRange(location: 0, length: s.length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        guard s.length <= maxLength else { return }
        for (r, color) in ranges(s) { lm.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: r) }
    }
}

/// Keywords, strings, numbers and comments coloured for read-only SQL (history list).
func highlightSQL(_ sql: String) -> AttributedString {
    var out = AttributedString()
    let keywords = Set(SQLCompleter.sqlKeywords + SQLCompleter.redisCommands)
    let chars = Array(sql)
    var i = 0
    func add(_ s: String, _ c: Color?) { var a = AttributedString(s); if let c { a.foregroundColor = c }; out += a }
    while i < chars.count {
        let c = chars[i]
        if c == "'" || c == "\"" || c == "`" {
            var j = i + 1
            while j < chars.count, chars[j] != c { j += 1 }
            j = min(j + 1, chars.count)
            add(String(chars[i..<j]), c == "'" ? Color(nsColor: SQLHighlighter.string) : nil); i = j
        } else if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
            var j = i; while j < chars.count, chars[j] != "\n" { j += 1 }
            add(String(chars[i..<j]), Color(nsColor: SQLHighlighter.comment)); i = j
        } else if c.isLetter || c == "_" {
            var j = i; while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
            let w = String(chars[i..<j])
            add(w, keywords.contains(w.uppercased()) ? Color(nsColor: SQLHighlighter.keyword) : nil); i = j
        } else if c.isNumber {
            var j = i; while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
            add(String(chars[i..<j]), Color(nsColor: SQLHighlighter.number)); i = j
        } else {
            add(String(c), nil); i += 1
        }
    }
    return out
}
