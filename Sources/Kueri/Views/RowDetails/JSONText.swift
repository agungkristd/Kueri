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

/// Colors formatted JSON (keys, strings, numbers, literals). Characters are never added or
/// removed, only attributed. Very large values are returned plain to keep the panel light.
func highlightJSON(_ s: String) -> AttributedString {
    var out = AttributedString(s)
    guard s.utf8.count <= 200_000 else { return out }
    let chars = Array(s)
    var idx = out.startIndex
    var i = 0
    func color(_ n: Int, _ c: Color) {
        let end = out.index(idx, offsetByCharacters: n)
        out[idx..<end].foregroundColor = c
        idx = end; i += n
    }
    while i < chars.count {
        let c = chars[i]
        if c == "\"" {
            var j = i + 1, esc = false
            while j < chars.count { if esc { esc = false } else if chars[j] == "\\" { esc = true } else if chars[j] == "\"" { break }; j += 1 }
            let len = min(j + 1, chars.count) - i
            var k = i + len
            while k < chars.count, chars[k] == " " { k += 1 }
            color(len, k < chars.count && chars[k] == ":" ? .teal : .green) // key vs string value
        } else if c == "-" || c.isNumber {
            var j = i; while j < chars.count, "-+.eE0123456789".contains(chars[j]) { j += 1 }
            color(j - i, .orange)
        } else if let lit = ["true", "false", "null"].first(where: { String(chars[i..<min(i + $0.count, chars.count)]) == $0 }) {
            color(lit.count, .pink)
        } else if "{}[],:".contains(c) {
            color(1, .secondary)
        } else {
            idx = out.index(afterCharacter: idx); i += 1
        }
    }
    return out
}
