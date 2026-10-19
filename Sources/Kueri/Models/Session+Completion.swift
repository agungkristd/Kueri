import SwiftUI

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
