import AppKit
import SwiftUI

/// User preferences (UserDefaults), read where they're used so a change applies on the next use.
enum Prefs {
    static let pageSizeKey = "pageSize", maxRowsKey = "maxRows", timeoutKey = "queryTimeout"
    static let gridFontKey = "gridFontSize", editorFontKey = "editorFontSize", fontFamilyKey = "monoFontFamily"
    static let reopenTabsKey = "reopenTabs", newTabKey = "newTabOpens", saveHistoryKey = "saveHistory"

    private static func int(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
        let v = UserDefaults.standard.object(forKey: key) as? Int ?? fallback
        return min(max(v, range.lowerBound), range.upperBound)
    }
    private static func bool(_ key: String, _ fallback: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? fallback }

    static var pageSize: Int { int(pageSizeKey, 300, 50...5000) }
    static var maxRows: Int { int(maxRowsKey, 10_000, 1000...200_000) }
    /// Seconds a statement may run on the server; 0 = no limit. Applies to new connections.
    static var queryTimeout: Int { int(timeoutKey, 0, 0...86_400) }
    static var gridFontSize: CGFloat { CGFloat(int(gridFontKey, 12, 9...20)) }
    static var editorFontSize: CGFloat { CGFloat(int(editorFontKey, 13, 9...24)) }
    static var reopenTabs: Bool { bool(reopenTabsKey, true) }
    /// ⌘T: "connection" opens a new window tab, "query" a new query tab in the current connection.
    static var newTabOpensQuery: Bool { UserDefaults.standard.string(forKey: newTabKey) == "query" }
    static var saveHistory: Bool { bool(saveHistoryKey, true) }
    /// Font of the grid and the SQL editor; empty = the system's SF Mono.
    static var fontFamily: String { UserDefaults.standard.string(forKey: fontFamilyKey) ?? "" }
    static func mono(_ size: CGFloat) -> NSFont {
        let f = fontFamily
        return f.isEmpty ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : NSFontManager.shared.font(withFamily: f, traits: [], weight: 5, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
    /// Installed fixed-width families, for the Settings picker (Core Text, off the main thread).
    nonisolated static func monoFamilies() async -> [String] {
        await Task.detached {
            let mono = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: [kCTFontSymbolicTrait: CTFontSymbolicTraits.traitMonoSpace.rawValue]] as CFDictionary)
            let found = CTFontCollectionCreateMatchingFontDescriptors(CTFontCollectionCreateWithFontDescriptors([mono] as CFArray, nil)) as? [CTFontDescriptor] ?? []
            return Set(found.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }.filter { !$0.hasPrefix(".") }).sorted()
        }.value
    }
}
