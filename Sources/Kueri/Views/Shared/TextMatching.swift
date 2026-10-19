import SwiftUI

/// Search by words: every word of the query (split on spaces, `_`, `-`, `.`) appears in the text,
/// in any order and case. "shop local" finds `shop_local`; an empty query matches everything.
func nameMatches(_ query: String, _ text: String) -> Bool {
    let words = query.lowercased().split(whereSeparator: { " _-.".contains($0) })
    let t = text.lowercased()
    return words.allSatisfy { t.contains($0) }
}

func markMatches(_ s: AttributedString, _ query: String) -> AttributedString {
    guard !query.isEmpty else { return s }
    var out = s
    var from = out.startIndex
    while from < out.endIndex, let r = out[from...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
        out[r].backgroundColor = .yellow.opacity(0.45)
        out[r].foregroundColor = .primary
        from = r.upperBound
    }
    return out
}
