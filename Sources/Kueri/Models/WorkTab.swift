import SwiftUI

enum TabKind: Equatable { case data, structure(String), diagram(String) }

/// A parked tab. The active tab's state lives directly on `Session` so the grid, Details panel and
/// editing code keep working unchanged; switching tabs swaps these values in and out.
struct WorkTab: Identifiable {
    let id: UUID
    var kind = TabKind.data
    var sql = ""
    var result = QueryResult()
    var selectedRow: Int?
    var edits: [Int: [Int: String?]] = [:]
    var table: String?
    var primaryKey: [String] = []
    var browsed: (query: String, table: String, offset: Int)?
    var offset = 0
    var error: String?
    var diagram: DiagramModel?

    var title: String {
        switch kind {
        case .data: table ?? "Query"
        case .structure(let t): "\(t) · structure"
        case .diagram(let t): t.isEmpty ? "Diagram" : "\(t) · diagram"
        }
    }
}

enum TableAction: CaseIterable {
    case openNewTab, structure, diagram, copyName, clone, truncate, delete
    var title: String {
        switch self {
        case .openNewTab: "Open in New Tab"
        case .structure: "Open Structure"
        case .diagram: "Show Diagram"
        case .copyName: "Copy Name"
        case .clone: "Clone…"
        case .truncate: "Truncate…"
        case .delete: "Delete…"
        }
    }
}
