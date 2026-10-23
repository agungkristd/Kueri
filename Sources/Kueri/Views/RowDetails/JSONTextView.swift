import AppKit
import SwiftUI

/// A JSON value in the Details panel: highlighted, wrapped to the panel width, edited in place
/// (Esc ends editing). An AppKit text view, because SwiftUI's Text laid out the whole value on
/// every row selection (~700 ms for 34 KB, measured); TextKit only lays out what's shown.
struct JSONTextView: NSViewRepresentable {
    let text: String
    var editable = true
    var search = ""
    var maxLines: Int?          // nil shows everything
    var onChange: (String) -> Void = { _ in }
    /// Whether the line cap hides part of the value at the current width (wrapped lines count),
    /// reported when it changes; the Details panel shows its "Show all" button from this.
    var onClipped: (Bool) -> Void = { _ in }

    static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JSONTextView?
        var search = ""
        // Measures off-screen: sizing the shown text view from sizeThatFits resized it, which made
        // SwiftUI ask for its size again, without end (full-CPU freeze).
        let storage = NSTextStorage(), layout = NSLayoutManager(), container = NSTextContainer()
        override init() {
            super.init()
            container.lineFragmentPadding = 0
            layout.addTextContainer(container); storage.addLayoutManager(layout)
        }
        var sized: (width: CGFloat, maxLines: Int?, height: CGFloat)?
        var clipped: Bool?, reportedClipped: Bool? // nil until measured with a line cap
        /// Tells the parent once per change. Also called from updateNSView: the first size request
        /// can come before `parent` is set, and a report dropped then would never be repeated.
        func reportClipped() {
            guard let report = parent?.onClipped, let value = clipped, value != reportedClipped else { return }
            reportedClipped = value
            DispatchQueue.main.async { report(value) } // not inside SwiftUI's layout pass
        }
        func measure(_ text: String) {
            guard storage.string != text else { return }
            storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: JSONTextView.font]))
            sized = nil
        }
        /// Height of `text` wrapped at `width`. Setting the container size invalidates every line,
        /// so it only changes when the width does; SwiftUI asks for the size many times per pass and
        /// each ask re-laid out the whole value (multi-second freeze on a large JSON, measured).
        func height(_ text: String, width: CGFloat, maxLines: Int?) -> CGFloat {
            measure(text)
            if let sized, sized.width == width, sized.maxLines == maxLines { return sized.height }
            if container.containerSize.width != width {
                container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            }
            let line = layout.defaultLineHeight(for: JSONTextView.font)
            let h: CGFloat
            if let maxLines {
                // Lays out only as far as the cap, so a huge value costs no more than its first lines.
                let cap = line * CGFloat(maxLines)
                layout.ensureLayout(forBoundingRect: CGRect(x: 0, y: 0, width: width, height: cap + line), in: container)
                let used = layout.usedRect(for: container).height
                h = min(max(used, line), cap)
                clipped = used > cap + 0.5
                reportClipped()
            } else {
                layout.ensureLayout(for: container)
                h = max(layout.usedRect(for: container).height, line)
            }
            sized = (width, maxLines, h)
            return h
        }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            JSONTextView.colour(tv, search: search)
            measure(tv.string)
            parent?.onChange(tv.string)
        }
        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
            tv.window?.makeFirstResponder(nil) // Esc: stop editing, keep the text
            return true
        }
    }

    /// Clips the collapsed value without a scroller of its own; the wheel scrolls the panel.
    final class ClipScrollView: NSScrollView {
        override func scrollWheel(with e: NSEvent) { nextResponder?.scrollWheel(with: e) }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = ClipScrollView()
        sv.drawsBackground = false; sv.borderType = .noBorder
        sv.hasVerticalScroller = false; sv.hasHorizontalScroller = false
        let tv = NSTextView(frame: .zero)
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        sv.documentView = tv
        tv.drawsBackground = false; tv.isRichText = false; tv.allowsUndo = true
        tv.font = Self.font
        tv.textContainerInset = .zero; tv.textContainer?.lineFragmentPadding = 0
        tv.isAutomaticQuoteSubstitutionEnabled = false; tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false; tv.isContinuousSpellCheckingEnabled = false
        tv.delegate = context.coordinator
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator, tv = sv.documentView as! NSTextView
        c.parent = self
        c.reportClipped()
        tv.isEditable = editable
        c.measure(text)
        if tv.string != text || c.search != search {
            if tv.string != text { tv.string = text }
            c.search = search
            Self.colour(tv, search: search)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView sv: NSScrollView, context: Context) -> CGSize? {
        let w = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 300
        return CGSize(width: w, height: context.coordinator.height(text, width: w, maxLines: maxLines))
    }

    /// Colours as layout-manager temporary attributes, like the SQL editor: the text and its undo
    /// history stay plain. Search matches get a yellow background.
    static func colour(_ tv: NSTextView, search: String) {
        guard let lm = tv.layoutManager else { return }
        let s = tv.string as NSString, all = NSRange(location: 0, length: s.length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        for (r, t) in jsonTokens(tv.string) {
            let c: NSColor = switch t {
            case .key: .systemTeal
            case .string: .systemGreen
            case .number: .systemOrange
            case .literal: .systemPink
            case .punctuation: .secondaryLabelColor
            }
            lm.addTemporaryAttribute(.foregroundColor, value: c, forCharacterRange: r)
        }
        guard !search.isEmpty else { return }
        var from = 0
        while from < s.length {
            let r = s.range(of: search, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: s.length - from))
            guard r.location != NSNotFound else { break }
            lm.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.45), forCharacterRange: r)
            from = r.location + max(r.length, 1)
        }
    }
}
