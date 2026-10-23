import SwiftUI

/// Re-indents JSON text without re-parsing into dictionaries, so key order is kept.
/// Returns nil when the value isn't a JSON object/array.
func prettyJSON(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let f = t.first, f == "{" || f == "[",
          (try? JSONSerialization.jsonObject(with: Data(t.utf8), options: [.fragmentsAllowed])) != nil else { return nil }
    var out = "", depth = 0, inString = false, escaped = false
    func newline() { out += "\n" + String(repeating: "  ", count: depth) }
    for c in t {
        if inString {
            out.append(c)
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            continue
        }
        switch c {
        case "\"": inString = true; out.append(c)
        case "{", "[": out.append(c); depth += 1; newline()
        case "}", "]":
            depth -= 1
            while out.last?.isWhitespace == true { out.removeLast() }
            if out.last != "{" && out.last != "[" { newline() } // keep empty containers as {} / []
            out.append(c)
        case ",": out.append(c); newline()
        case ":": out += ": "
        case " ", "\n", "\t", "\r": continue
        default: out.append(c)
        }
    }
    return out
}

/// The same JSON on one line: whitespace outside strings removed, key order kept.
func minifyJSON(_ s: String) -> String? {
    guard prettyJSON(s) != nil else { return nil }
    var out = "", inString = false, escaped = false
    for c in s {
        if inString {
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
        } else if c == "\"" { inString = true } else if c.isWhitespace { continue }
        out.append(c)
    }
    return out
}

enum JSONToken { case key, string, number, literal, punctuation }

/// Token ranges (UTF-16, for NSString / text views) of keys, strings, numbers, literals and
/// punctuation. Very large values return nothing, to keep the panel light.
func jsonTokens(_ s: String) -> [(NSRange, JSONToken)] {
    let u = Array(s.utf16)
    guard u.count <= 200_000 else { return [] }
    func ch(_ c: Character) -> UInt16 { c.utf16.first! }
    let quote = ch("\""), backslash = ch("\\"), colon = ch(":"), space = ch(" ")
    var out: [(NSRange, JSONToken)] = [], i = 0
    while i < u.count {
        let c = u[i]
        if c == quote {
            var j = i + 1, esc = false
            while j < u.count { if esc { esc = false } else if u[j] == backslash { esc = true } else if u[j] == quote { break }; j += 1 }
            let end = min(j + 1, u.count)
            var k = end; while k < u.count, u[k] == space { k += 1 }
            out.append((NSRange(location: i, length: end - i), k < u.count && u[k] == colon ? .key : .string))
            i = end
        } else if c == ch("-") || (ch("0")...ch("9")).contains(c) {
            var j = i; while j < u.count, "-+.eE0123456789".utf16.contains(u[j]) { j += 1 }
            out.append((NSRange(location: i, length: j - i), .number)); i = j
        } else if let lit = ["true", "false", "null"].first(where: { Array($0.utf16) == Array(u[i..<min(i + $0.count, u.count)]) }) {
            out.append((NSRange(location: i, length: lit.count), .literal)); i += lit.count
        } else if "{}[],:".utf16.contains(c) {
            out.append((NSRange(location: i, length: 1), .punctuation)); i += 1
        } else { i += 1 }
    }
    return out
}
