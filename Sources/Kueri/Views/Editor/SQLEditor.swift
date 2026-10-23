import SwiftUI

/// NSTextView-based SQL editor with inline (ghost) completion: Tab accepts, Esc dismisses,
/// ⌥Esc shows the full list.
struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    let completer: SQLCompleter
    var cacheVersion = 0 // changes when columns finish loading, so the suggestion can appear right away
    @AppStorage(Prefs.editorFontKey) private var fontSize = 13 // re-renders when changed in Settings

    final class TextView: NSTextView {
        var ghost: String?            // remaining characters of the suggestion, drawn after the caret
        var pending: (range: NSRange, replacement: String)?
        var suggest: (String, String, String) -> String? = { _, _, _ in nil } // (word, sql, textBefore) → full word
        var list: (String, String, String) -> [String] = { _, _, _ in [] }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let ghost, let lm = layoutManager, let tc = textContainer else { return }
            let caret = selectedRange().location
            var rect: NSRect
            if caret > 0 {
                let g = lm.glyphRange(forCharacterRange: NSRange(location: caret - 1, length: 1), actualCharacterRange: nil)
                rect = lm.boundingRect(forGlyphRange: g, in: tc)
                rect.origin.x = rect.maxX
            } else {
                rect = lm.extraLineFragmentRect
            }
            let s = string as NSString
            let font = font ?? Prefs.mono(Prefs.editorFontSize)
            let origin = NSPoint(x: rect.minX + textContainerOrigin.x, y: rect.minY + textContainerOrigin.y)
            // Text after the caret on this line would hide an inline suggestion: show it in a chip under the caret.
            if caret < s.length, s.character(at: caret) != 10, let word = pending?.replacement {
                let text = NSMutableAttributedString(string: word, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
                text.append(NSAttributedString(string: "  ⇥", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
                let size = text.size()
                var at = NSPoint(x: origin.x - (word.utf16.count - ghost.utf16.count > 0 ? (word as NSString).size(withAttributes: [.font: font]).width - (ghost as NSString).size(withAttributes: [.font: font]).width : 0),
                                 y: origin.y + rect.height + 3)
                if at.y + size.height + 2 > visibleRect.maxY { at.y = origin.y - size.height - 5 } // last visible line: above it
                let chip = NSBezierPath(roundedRect: NSRect(origin: at, size: size).insetBy(dx: -5, dy: -2), xRadius: 4, yRadius: 4)
                NSColor.controlBackgroundColor.setFill(); chip.fill()
                NSColor.separatorColor.setStroke(); chip.stroke()
                text.draw(at: at)
                return
            }
            (ghost as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
        }

        /// The identifier-ish word ending at the caret (letters, digits, `_`, `.`).
        func wordBeforeCaret() -> NSRange? {
            let caret = selectedRange()
            guard caret.length == 0 else { return nil }
            let s = string as NSString
            if caret.location < s.length, let next = Unicode.Scalar(s.character(at: caret.location)),
               CharacterSet.alphanumerics.contains(next) || next == "_" { return nil } // mid-word: no ghost
            var start = caret.location
            while start > 0, let c = Unicode.Scalar(s.character(at: start - 1)),
                  CharacterSet.alphanumerics.contains(c) || c == "_" || c == "." { start -= 1 }
            guard start < caret.location else { return nil }
            // Typing inside a 'string' or a comment is data, not a name: no suggestion.
            if SQLCompleter.insideLiteral(s.substring(to: start)) { return nil }
            return NSRange(location: start, length: caret.location - start)
        }

        /// Beautifies the whole query as one undoable edit.
        @objc func formatSQL(_ sender: Any?) {
            let formatted = SQLFormatter.format(string)
            let all = NSRange(location: 0, length: (string as NSString).length)
            guard formatted != string, shouldChangeText(in: all, replacementString: formatted) else { return }
            textStorage?.replaceCharacters(in: all, with: formatted)
            didChangeText()
            setSelectedRange(NSRange(location: (formatted as NSString).length, length: 0))
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = super.menu(for: event) ?? NSMenu()
            let item = NSMenuItem(title: "Format SQL", action: #selector(formatSQL(_:)), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            return menu
        }

        func refreshGhost() {
            let old = ghost
            ghost = nil; pending = nil
            if let r = wordBeforeCaret() {
                let s = string as NSString
                let word = s.substring(with: r), before = s.substring(to: r.location)
                if let full = suggest(word, string, before) {
                    let last = word.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? word
                    let replaceRange = NSRange(location: r.location + r.length - last.utf16.count, length: last.utf16.count)
                    pending = (replaceRange, full)
                    ghost = String(full.dropFirst(last.count))
                }
            }
            if old != ghost { needsDisplay = true }
        }

        func acceptGhost() -> Bool {
            guard let p = pending else { return false }
            if shouldChangeText(in: p.range, replacementString: p.replacement) { // undoable
                replaceCharacters(in: p.range, with: p.replacement)
                didChangeText()
            }
            ghost = nil; pending = nil; needsDisplay = true
            return true
        }

        override func doCommand(by selector: Selector) {
            if selector == #selector(insertTab(_:)), acceptGhost() { return }
            if selector == #selector(cancelOperation(_:)), ghost != nil { ghost = nil; pending = nil; needsDisplay = true; return }
            super.doCommand(by: selector)
        }

        override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
            super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
            if ghost != nil { ghost = nil; pending = nil; needsDisplay = true } // caret moved: drop the suggestion
        }

        // ⌥Esc / F5: the system completion list, fed by the same candidates.
        override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
            let s = string as NSString
            let word = s.substring(with: charRange)
            var start = charRange.location // extend left over "qualifier." so columns of that table are listed
            while start > 0, let c = Unicode.Scalar(s.character(at: start - 1)),
                  CharacterSet.alphanumerics.contains(c) || c == "_" || c == "." { start -= 1 }
            let qualified = s.substring(with: NSRange(location: start, length: charRange.location + charRange.length - start))
            let found = list(qualified, string, s.substring(to: start))
                .filter { word.isEmpty || $0.range(of: word, options: [.caseInsensitive, .anchored]) != nil }
            return found.isEmpty ? nil : Array(NSOrderedSet(array: found).array as! [String])
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditor
        var seenCacheVersion = 0
        init(_ p: SQLEditor) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? TextView else { return }
            parent.text = tv.string
            tv.refreshGhost()
            SQLHighlighter.apply(to: tv)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = TextView.scrollableTextView()
        let old = sv.documentView as! NSTextView
        let tv = TextView(frame: old.frame, textContainer: old.textContainer)
        tv.autoresizingMask = old.autoresizingMask
        tv.isVerticallyResizable = true
        tv.minSize = old.minSize; tv.maxSize = old.maxSize
        sv.documentView = tv
        tv.font = Prefs.mono(Prefs.editorFontSize)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.drawsBackground = true
        tv.backgroundColor = .windowBackgroundColor // the content column's colour; the side panels are the dark ones
        tv.delegate = context.coordinator
        tv.string = text
        SQLHighlighter.apply(to: tv)
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = sv.documentView as? TextView else { return }
        let font = Prefs.mono(Prefs.editorFontSize)
        if tv.font != font { tv.font = font; SQLHighlighter.apply(to: tv) } // changed in Settings
        let c = completer
        tv.suggest = { w, sql, before in c.best(for: w, in: sql, before: before) }
        tv.list = { w, sql, before in c.candidates(for: w, in: sql, before: before) }
        if tv.string != text { tv.string = text; tv.ghost = nil; tv.pending = nil; SQLHighlighter.apply(to: tv) } // set from outside (sidebar click)
        else if context.coordinator.seenCacheVersion != cacheVersion, tv.window?.firstResponder === tv { tv.refreshGhost() }
        context.coordinator.seenCacheVersion = cacheVersion
    }
}
