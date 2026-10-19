import AppKit
import SwiftUI

/// Tables and their foreign keys. Drawn by one AppKit view (`DiagramCanvas`) that paints only the
/// visible part, so a large schema costs little memory, and zooming is the scroll view's own
/// magnification, which AppKit redraws sharp at every size.
struct DiagramView: View {
    let model: DiagramModel?
    var error: String?
    var onAction: (TableAction, String) -> Void = { _, _ in }
    var session: Session?
    /// Shows a table's details (in the right panel).
    var onInspect: (String) -> Void = { _ in }
    @State private var controller = DiagramController()

    static let width: CGFloat = 250, header: CGFloat = 34, row: CGFloat = 22, maxRows = 40
    static let zoomRange: ClosedRange<CGFloat> = 0.2...2.5

    nonisolated static func height(_ t: DiagramTable) -> CGFloat {
        Self.header + CGFloat(min(t.columns.count, Self.maxRows) + (t.columns.count > Self.maxRows ? 1 : 0)) * Self.row + 12
    }

    var body: some View {
        if let model {
            DiagramSurface(model: model, controller: controller, onAction: onAction, onInspect: onInspect)
                .background(Color(nsColor: .underPageBackgroundColor))
                .overlay(alignment: .bottomLeading) { RelationLegend().padding(12) }
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 2) {
                        Button { controller.zoom(to: controller.zoom / 1.25) } label: { Image(systemName: "minus") }
                            .keyboardShortcut("-", modifiers: .command).help("Zoom out (⌘−, or ⌃ + scroll)")
                        Button { controller.zoom(to: 1) } label: { Text("\(Int((controller.zoom * 100).rounded()))%").monospacedDigit().frame(minWidth: 44) }
                            .keyboardShortcut("0", modifiers: .command).help("Actual size (⌘0)")
                        Button { controller.zoom(to: controller.zoom * 1.25) } label: { Image(systemName: "plus") }
                            .keyboardShortcut("=", modifiers: .command).help("Zoom in (⌘+, or ⌃ + scroll)")
                        Button("Fit") { controller.canvas?.fit() }
                            .help("Fit the whole diagram in the window")
                    }
                    .buttonStyle(.accessoryBarAction)
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(12)
                }
        } else if let error {
            Text(error).foregroundStyle(.red).textSelection(.enabled).padding()
        } else {
            ProgressView("Loading diagram…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Two short bars across the line near the table edge: exactly one.
    static func oneMark(_ p: CGMutablePath, at e: CGPoint, outward d: CGFloat) {
        for x in [8, 13] as [CGFloat] {
            p.move(to: CGPoint(x: e.x + d * x, y: e.y - 6)); p.addLine(to: CGPoint(x: e.x + d * x, y: e.y + 6))
        }
    }

    /// Crow's foot: three prongs spreading onto the table edge: many.
    static func manyMark(_ p: CGMutablePath, at e: CGPoint, outward d: CGFloat) {
        let hub = CGPoint(x: e.x + d * 14, y: e.y)
        for dy in [-7, 0, 7] as [CGFloat] { p.move(to: hub); p.addLine(to: CGPoint(x: e.x, y: e.y + dy)) }
    }

    /// The foreign key column is the referencing table's whole primary key, so each row matches one.
    static func isOneToOne(_ fk: ForeignKey, _ m: DiagramModel) -> Bool {
        guard let t = m.tables.first(where: { $0.name == fk.fromTable }) else { return false }
        let pk = t.columns.filter(\.isPrimaryKey)
        return pk.count == 1 && pk[0].name == fk.fromColumn
    }

    static func linkKey(_ fk: ForeignKey) -> String { "\(fk.fromTable).\(fk.fromColumn)>\(fk.toTable).\(fk.toColumn)" }
}

/// Lets the SwiftUI zoom buttons reach the canvas and show its zoom.
@Observable final class DiagramController {
    var zoom: CGFloat = 1
    @ObservationIgnored weak var canvas: DiagramCanvas?
    func zoom(to z: CGFloat) { canvas?.setZoom(z) }
}

struct DiagramSurface: NSViewRepresentable {
    let model: DiagramModel
    let controller: DiagramController
    let onAction: (TableAction, String) -> Void
    let onInspect: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true; sv.hasHorizontalScroller = true; sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.contentView = CenteringClipView()
        sv.allowsMagnification = true
        sv.minMagnification = DiagramView.zoomRange.lowerBound
        sv.maxMagnification = DiagramView.zoomRange.upperBound
        let canvas = DiagramCanvas()
        sv.documentView = canvas
        controller.canvas = canvas
        canvas.onZoom = { [weak controller] z in if let controller, abs(controller.zoom - z) > 0.001 { controller.zoom = z } }
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let canvas = sv.documentView as? DiagramCanvas else { return }
        canvas.onAction = onAction
        canvas.onInspect = onInspect
        canvas.show(model)
    }
}

/// Key to the line ends in the diagram, drawn against a table edge so it's clear which end is which.
struct RelationLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            item("one (1)") { DiagramView.oneMark($0, at: CGPoint(x: 30, y: 9), outward: -1) }
            item("many (N)") { DiagramView.manyMark($0, at: CGPoint(x: 30, y: 9), outward: -1) }
            Text("Click a table to see its relations").foregroundStyle(.tertiary)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .help("Each line joins a foreign key (the many end) to the row it references (the one end). Many-to-many relations go through a linking table, shown as two of these.")
    }

    private func item(_ label: String, _ mark: @escaping (CGMutablePath) -> Void) -> some View {
        HStack(spacing: 5) {
            Canvas { ctx, _ in
                let line = CGMutablePath(); line.move(to: CGPoint(x: 0, y: 9)); line.addLine(to: CGPoint(x: 30, y: 9))
                mark(line)
                ctx.stroke(Path(line), with: .color(.secondary), lineWidth: 1.4)
                // The table edge the mark touches.
                ctx.fill(Path(roundedRect: CGRect(x: 30, y: 1, width: 3, height: 16), cornerRadius: 1), with: .color(.secondary.opacity(0.6)))
            }
            .frame(width: 34, height: 18)
            Text(label)
        }
    }
}
