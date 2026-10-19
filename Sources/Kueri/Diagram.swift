import AppKit
import SwiftUI

// MARK: Diagram tab

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

/// Draws the diagram and handles its mouse work: click a table for its details, drag a table to
/// move it, drag a line to bend it, drag empty space to scroll, right-click for table actions,
/// ⌃ + scroll to zoom at the pointer.
final class DiagramCanvas: NSView, NSViewToolTipOwner {
    var onAction: (TableAction, String) -> Void = { _, _ in }
    var onInspect: (String) -> Void = { _ in }
    var onZoom: (CGFloat) -> Void = { _ in }

    private var model: DiagramModel?
    private var pos: [String: CGPoint] = [:]
    private var bends: [String: CGSize] = [:]   // relation line → how far its middle was dragged
    private var selected: String?               // "" = cleared by a click on empty space
    private var observers: [NSObjectProtocol] = []

    private typealias T = DiagramView
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private var scrollView: NSScrollView? { enclosingScrollView }
    var zoom: CGFloat { scrollView?.magnification ?? 1 }

    // MARK: Model

    func show(_ m: DiagramModel) {
        let old = model
        model = m
        if old == nil || old?.focus != m.focus {
            pos = [:]; bends = [:]; selected = nil
            scrollView?.magnification = 1
        }
        if m.highlight != old?.highlight, let h = m.highlight { selected = h }
        resize()
        needsDisplay = true
        if let h = m.highlight, h != old?.highlight || old == nil {
            DispatchQueue.main.async { [weak self] in self?.reveal(h) }
        }
    }

    private func point(_ name: String) -> CGPoint { pos[name] ?? initial(name) }

    // Layout: tables the focus references on the right, tables referencing it on the left.
    private func initial(_ name: String) -> CGPoint {
        guard let m = model else { return .zero }
        if let p = m.positions[name] { return p }
        let parents = m.tables.map(\.name).filter { n in n != m.focus && m.links.contains { $0.fromTable == m.focus && $0.toTable == n } }
        let children = m.tables.map(\.name).filter { n in n != m.focus && !parents.contains(n) }
        let gap: CGFloat = 120, x0: CGFloat = 40
        func stackY(_ list: [String], _ n: String) -> CGFloat {
            var y: CGFloat = 40
            for other in list { if other == n { return y }; y += T.height(m.tables.first { $0.name == other }!) + 40 }
            return y
        }
        if name == m.focus { return CGPoint(x: x0 + T.width + gap, y: 40) }
        if parents.contains(name) { return CGPoint(x: x0 + 2 * (T.width + gap), y: stackY(parents, name)) }
        return CGPoint(x: x0, y: stackY(children, name))
    }

    private func rect(_ t: DiagramTable) -> CGRect {
        CGRect(origin: point(t.name), size: CGSize(width: T.width, height: T.height(t)))
    }

    private func resize() {
        guard let m = model else { return }
        var w: CGFloat = 800, h: CGFloat = 600
        for t in m.tables { let r = rect(t); w = max(w, r.maxX + 80); h = max(h, r.maxY + 80) }
        if frame.size != CGSize(width: w, height: h) { setFrameSize(CGSize(width: w, height: h)) }
        removeAllToolTips()
        for t in m.tables { addToolTip(rect(t), owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        "Click for details, right-click for more"
    }

    /// Scrolls so the table is in the middle of the view.
    private func reveal(_ name: String) {
        guard let sv = scrollView, let t = model?.tables.first(where: { $0.name == name }) else { return }
        let r = rect(t), clip = sv.contentView, size = clip.bounds.size
        var o = CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2)
        o.x = min(max(0, o.x), max(0, frame.width - size.width))
        o.y = min(max(0, o.y), max(0, frame.height - size.height))
        clip.scroll(to: o); sv.reflectScrolledClipView(clip)
    }

    /// The table whose relations stand out (clicked, or highlighted from the sidebar).
    private var focusTable: String? {
        guard let m = model else { return nil }
        let f = selected ?? m.highlight ?? m.focus
        return f.isEmpty ? nil : f
    }

    // MARK: Zoom

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let sv = scrollView, observers.isEmpty else { return }
        // Pinches change the magnification directly: keep the % and the zoom-dependent marks current.
        observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: sv, queue: .main) { [weak self] _ in
            self?.zoomChanged()
        })
        sv.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: .main) { [weak self] _ in
            guard let self, abs(self.reportedZoom - self.zoom) > 0.001 else { return }
            self.zoomChanged()
        })
    }

    private var reportedZoom: CGFloat = 1
    private func zoomChanged() {
        let crossed = (reportedZoom >= 0.6) != (zoom >= 0.6) // end marks show from 60%
        reportedZoom = zoom
        onZoom(zoom)
        if crossed { needsDisplay = true }
    }

    /// Keeps the point under `windowPoint` (the pointer) where it is; without one, the middle of what's visible.
    func setZoom(_ z: CGFloat, at windowPoint: NSPoint? = nil) {
        guard let sv = scrollView else { return }
        let new = min(max(z, T.zoomRange.lowerBound), T.zoomRange.upperBound)
        let visible = sv.contentView.documentVisibleRect
        let centre = windowPoint.map { convert($0, from: nil) } ?? CGPoint(x: visible.midX, y: visible.midY)
        sv.setMagnification(new, centeredAt: centre)
        zoomChanged()
    }

    func fit() {
        guard let sv = scrollView else { return }
        sv.magnify(toFit: bounds)
        if sv.magnification > 1 { sv.setMagnification(1, centeredAt: .zero) }
        zoomChanged()
    }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.control) {
            let d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 200 : e.scrollingDeltaY / 20
            if d != 0 { setZoom(zoom * (1 + max(-0.5, min(0.5, d))), at: e.locationInWindow) }
            return
        }
        if e.modifierFlags.contains(.shift), e.scrollingDeltaX == 0, e.scrollingDeltaY != 0,
           let cg = e.cgEvent?.copy() { // wheel mice only send vertical deltas: scroll sideways
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: cg.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
            super.scrollWheel(with: NSEvent(cgEvent: cg) ?? e)
            return
        }
        super.scrollWheel(with: e)
    }

    // MARK: Drawing

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    private func rowY(_ table: DiagramTable, _ column: String) -> CGFloat {
        let i = min(table.columns.firstIndex { $0.name == column } ?? 0, T.maxRows) // hidden rows anchor to "more"
        return point(table.name).y + T.header + CGFloat(i) * T.row + T.row / 2
    }

    /// A relation's line: a straight run off each table edge (where the end marks sit, so they line
    /// up however steeply it bends), and a curve between, through the point it was dragged to.
    private func geometry(_ fk: ForeignKey) -> (path: CGPath, start: CGPoint, end: CGPoint, startOut: CGFloat, endOut: CGFloat)? {
        guard let m = model, let from = m.tables.first(where: { $0.name == fk.fromTable }),
              let to = m.tables.first(where: { $0.name == fk.toTable }) else { return nil }
        let a = point(fk.fromTable), b = point(fk.toTable)
        let y1 = rowY(from, fk.fromColumn), y2 = rowY(to, fk.toColumn)
        let fromRight = a.x + T.width <= b.x || (abs(a.x - b.x) < T.width && fk.fromTable != fk.toTable)
        let start = CGPoint(x: fromRight ? a.x + T.width : a.x, y: y1)
        let endOnLeft = fromRight ? (a.x + T.width <= b.x) : false
        let end = CGPoint(x: endOnLeft ? b.x : b.x + T.width, y: y2)
        let startOut: CGFloat = fromRight ? 1 : -1, endOut: CGFloat = endOnLeft ? -1 : 1
        let run: CGFloat = 22, bend: CGFloat = 60
        let s1 = CGPoint(x: start.x + startOut * run, y: start.y), e1 = CGPoint(x: end.x + endOut * run, y: end.y)
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: s1)
        if let off = bends[T.linkKey(fk)] {
            // Two smooth halves through the dragged midpoint.
            let mid = CGPoint(x: (s1.x + e1.x) / 2 + off.width, y: (s1.y + e1.y) / 2 + off.height)
            let t = CGPoint(x: (e1.x - s1.x) / 4, y: (e1.y - s1.y) / 4)
            path.addCurve(to: mid, control1: CGPoint(x: s1.x + startOut * bend, y: s1.y), control2: CGPoint(x: mid.x - t.x, y: mid.y - t.y))
            path.addCurve(to: e1, control1: CGPoint(x: mid.x + t.x, y: mid.y + t.y), control2: CGPoint(x: e1.x + endOut * bend, y: e1.y))
        } else {
            path.addCurve(to: e1, control1: CGPoint(x: s1.x + startOut * bend, y: s1.y), control2: CGPoint(x: e1.x + endOut * bend, y: e1.y))
        }
        path.addLine(to: end)
        return (path, start, end, startOut, endOut)
    }

    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let rowFont = NSFont.systemFont(ofSize: 12)
    private static let moreFont = NSFont.systemFont(ofSize: 10)
    private static let labelFont = NSFont.systemFont(ofSize: 10, weight: .bold)
    private static let key: NSImage? = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Primary key")?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .regular).applying(.init(paletteColors: [.systemYellow])))
    private static let truncating: NSParagraphStyle = {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; return p
    }()
    private static let centred: NSParagraphStyle = {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; p.alignment = .center; return p
    }()

    /// With a table in focus its relations are drawn in the accent colour with their cardinality,
    /// and the rest fade back, so a large schema stays readable. Without one, every line is thin
    /// and quiet, and the end marks appear only when zoomed in enough to read them.
    override func draw(_ dirty: NSRect) {
        guard let m = model, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let focus = focusTable
        var hood: Set<String>?
        if let focus {
            var set: Set<String> = [focus]
            for fk in m.links where fk.fromTable == focus || fk.toTable == focus { set.insert(fk.fromTable); set.insert(fk.toTable) }
            hood = set
        }
        let accent = NSColor.controlAccentColor, quiet = NSColor.secondaryLabelColor
        let ordered = m.links.sorted { l, _ in !(l.fromTable == focus || l.toTable == focus) } // focused ones on top
        ctx.setLineCap(.round)
        for fk in ordered {
            guard let (path, start, end, startOut, endOut) = geometry(fk),
                  path.boundingBoxOfPath.insetBy(dx: -30, dy: -30).intersects(dirty) else { continue }
            let related = focus != nil && (fk.fromTable == focus || fk.toTable == focus)
            let color = (related ? accent : quiet).withAlphaComponent(focus == nil ? 0.55 : (related ? 1 : 0.12))
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(related ? 2 : 1.2)
            ctx.addPath(path); ctx.strokePath()
            // Crow's foot notation: two bars = one, three prongs = many (one too when the foreign key
            // is the referencing table's whole primary key).
            guard related || (focus == nil && zoom >= 0.6) else { continue }
            let oneToOne = T.isOneToOne(fk, m)
            let marks = CGMutablePath()
            T.oneMark(marks, at: end, outward: endOut)
            if oneToOne { T.oneMark(marks, at: start, outward: startOut) } else { T.manyMark(marks, at: start, outward: startOut) }
            ctx.setLineWidth(related ? 1.8 : 1.3)
            ctx.addPath(marks); ctx.strokePath()
            guard related else { continue }
            func label(_ s: String, _ p: CGPoint, _ d: CGFloat) {
                let text = s as NSString, attrs: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: accent]
                let size = text.size(withAttributes: attrs)
                text.draw(at: CGPoint(x: p.x + d * 11 - size.width / 2, y: p.y - 13 - size.height / 2), withAttributes: attrs)
            }
            label("1", end, endOut)
            label(oneToOne ? "1" : "N", start, startOut)
        }
        for t in m.tables {
            let r = rect(t)
            guard r.insetBy(dx: -2, dy: -2).intersects(dirty) else { continue }
            drawBox(t, in: r, selected: t.name == focus, dimmed: hood.map { !$0.contains(t.name) } ?? false)
        }
    }

    private func drawBox(_ t: DiagramTable, in r: CGRect, selected: Bool, dimmed: Bool) {
        let shape = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.setFill(); shape.fill()
        let inset: CGFloat = 14, inner = r.insetBy(dx: inset, dy: 0)
        let title: [NSAttributedString.Key: Any] = [.font: Self.titleFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: Self.centred]
        (t.name as NSString).draw(with: CGRect(x: inner.minX, y: r.minY + (T.header - 16) / 2, width: inner.width, height: 17),
                                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: title)
        let name: [NSAttributedString.Key: Any] = [.font: Self.rowFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: Self.truncating]
        let type: [NSAttributedString.Key: Any] = [.font: Self.rowFont, .foregroundColor: NSColor.secondaryLabelColor]
        for (i, c) in t.columns.prefix(T.maxRows).enumerated() {
            let y = r.minY + T.header + CGFloat(i) * T.row, textY = y + (T.row - 15) / 2
            let typeWidth = min((c.type as NSString).size(withAttributes: type).width, inner.width / 2)
            (c.type as NSString).draw(with: CGRect(x: inner.maxX - typeWidth, y: textY, width: typeWidth, height: 16),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: type)
            var x = inner.minX
            if c.isPrimaryKey, let key = Self.key {
                key.draw(in: CGRect(x: x, y: y + (T.row - key.size.height) / 2, width: key.size.width, height: key.size.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += key.size.width + 6
            }
            (c.name as NSString).draw(with: CGRect(x: x, y: textY, width: max(0, inner.maxX - typeWidth - 8 - x), height: 16),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: name)
        }
        if t.columns.count > T.maxRows {
            let more: [NSAttributedString.Key: Any] = [.font: Self.moreFont, .foregroundColor: NSColor.secondaryLabelColor]
            ("+ \(t.columns.count - T.maxRows) more" as NSString)
                .draw(at: CGPoint(x: inner.minX, y: r.minY + T.header + CGFloat(T.maxRows) * T.row + (T.row - 13) / 2), withAttributes: more)
        }
        let edge = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        edge.lineWidth = selected ? 2 : 1
        (selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor.withAlphaComponent(0.25)).setStroke(); edge.stroke()
        // Fades unrelated tables toward the background.
        if dimmed { NSColor.underPageBackgroundColor.withAlphaComponent(0.6).setFill(); shape.fill() }
    }

    // MARK: Mouse

    private func table(at p: CGPoint) -> DiagramTable? { model?.tables.last { rect($0).contains(p) } }

    /// The relation whose line passes within a few points of `p` (focused relations first).
    private func link(at p: CGPoint) -> ForeignKey? {
        guard let m = model else { return nil }
        let focus = focusTable
        let reach = 5 / max(zoom, 0.2)
        return m.links.sorted { l, _ in l.fromTable == focus || l.toTable == focus }.first { fk in
            guard let path = geometry(fk)?.path, path.boundingBoxOfPath.insetBy(dx: -reach, dy: -reach).contains(p) else { return false }
            return path.copy(strokingWithWidth: reach * 2, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(p)
        }
    }

    private enum Drag { case table(String, offset: CGSize), line(String, last: CGPoint), pan(last: NSPoint) }
    private var drag: Drag?
    private var moved = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        moved = false
        if let t = table(at: p) {
            let o = point(t.name)
            drag = .table(t.name, offset: CGSize(width: p.x - o.x, height: p.y - o.y))
            NSCursor.closedHand.set()
        } else if let fk = link(at: p) {
            drag = .line(T.linkKey(fk), last: p)
            NSCursor.closedHand.set()
        } else {
            drag = .pan(last: e.locationInWindow)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        moved = true
        let p = convert(e.locationInWindow, from: nil)
        switch drag {
        case .table(let name, let offset):
            pos[name] = CGPoint(x: max(0, p.x - offset.width), y: max(0, p.y - offset.height))
            resize(); needsDisplay = true
        case .line(let key, let last):
            let o = bends[key] ?? .zero
            bends[key] = CGSize(width: o.width + p.x - last.x, height: o.height + p.y - last.y)
            drag = .line(key, last: p); needsDisplay = true
        case .pan(let last):
            guard let sv = scrollView else { return }
            // Content follows the pointer: moving right shows what's further left.
            let w = e.locationInWindow, clip = sv.contentView, m = sv.magnification
            var o = clip.bounds.origin
            o.x -= (w.x - last.x) / m
            o.y += (w.y - last.y) / m // window y grows upwards, this view's downwards
            o.x = min(max(0, o.x), max(0, frame.width - clip.bounds.width))
            o.y = min(max(0, o.y), max(0, frame.height - clip.bounds.height))
            clip.scroll(to: o); sv.reflectScrolledClipView(clip)
            drag = .pan(last: w)
        case nil: break
        }
    }

    override func mouseUp(with e: NSEvent) {
        defer { drag = nil; updateCursor(convert(e.locationInWindow, from: nil)) }
        guard !moved else { return }
        switch drag {
        case .table(let name, _): selected = name; needsDisplay = true; onInspect(name)
        case .pan: selected = ""; needsDisplay = true // a click on empty space clears the focus
        default: break
        }
    }

    override func menu(for e: NSEvent) -> NSMenu? {
        guard let t = table(at: convert(e.locationInWindow, from: nil)) else { return nil }
        let name = t.name, menu = NSMenu()
        func item(_ title: String, _ f: @escaping () -> Void) {
            let i = ClosureMenuItem(title, f)
            menu.addItem(i)
        }
        item("Show Details") { [weak self] in self?.selected = name; self?.needsDisplay = true; self?.onInspect(name) }
        menu.addItem(.separator())
        item("Open Data") { [weak self] in self?.onAction(.openNewTab, name) }
        item("Open Structure") { [weak self] in self?.onAction(.structure, name) }
        menu.addItem(.separator())
        item("Delete Table…") { [weak self] in self?.onAction(.delete, name) }
        return menu
    }

    // Grab hand only over a table or a line (they can be dragged); the plain arrow everywhere else.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with e: NSEvent) { if drag == nil { updateCursor(convert(e.locationInWindow, from: nil)) } }
    override func mouseExited(with e: NSEvent) { NSCursor.arrow.set() }
    private func updateCursor(_ p: CGPoint) {
        (table(at: p) != nil || link(at: p) != nil ? NSCursor.openHand : NSCursor.arrow).set()
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
