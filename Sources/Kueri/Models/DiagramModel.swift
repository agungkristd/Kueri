import AppKit
import SwiftUI

struct DiagramTable: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let columns: [ColumnInfo]
}

struct DiagramModel {
    let focus: String  // empty for the whole-database diagram
    let tables: [DiagramTable]
    let links: [ForeignKey]
    var positions: [String: CGPoint] = [:]  // precomputed layout (whole database)
    var highlight: String?                  // table outlined and scrolled to (whole database)
}
