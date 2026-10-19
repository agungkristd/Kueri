import AppKit
import SwiftUI

/// Selects the whole text when a field gains focus, so a value can be replaced by just typing.
struct SelectAllOnFocus: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focused($focused).onChange(of: focused) { _, isFocused in
            // .default mode only: the click's mouse tracking runs in .eventTracking mode and places the
            // caret on mouse-up, so selecting earlier (e.g. DispatchQueue.main.async) gets undone.
            if isFocused {
                RunLoop.main.perform(inModes: [.default]) {
                    // The focused field's editor, directly (not via the key window's responder chain).
                    let w = NSApp.keyWindow?.firstResponder is NSText ? NSApp.keyWindow : NSApp.windows.first { $0.firstResponder is NSText }
                    (w?.firstResponder as? NSText)?.selectAll(nil)
                }
            }
        }
    }
}

extension View {
    func selectAllOnFocus() -> some View { modifier(SelectAllOnFocus()) }
}

/// SwiftUI's `.help` doesn't reach bridged NSToolbarItems (their toolTip stayed nil, measured),
/// so tooltips are set on each item as AppKit adds it, by label. Also covers Run ⇄ Stop swaps.
enum ToolbarTooltips {
    @MainActor static var byLabel: [String: String] {
        let k = Keymap.shared
        return [
            "Run": "Run query (\(k.display(.run)))",
            "Stop": "Stop query (\(k.display(.stop)))",
            "SQL Editor": "Show/hide SQL editor (\(k.display(.toggleEditor)))",
            "History": "Show query history in the sidebar (\(k.display(.history)))",
            "Disconnect": "Disconnect",
            "Processes": "Server processes: see and kill client connections (\(k.display(.processes)))",
            "New Tab": "New connection tab",
            "Sidebar": "Show/hide tables (\(k.display(.toggleSidebar)))",
            "Details": "Show/hide row details (\(k.display(.toggleDetails)))",
        ]
    }
    @MainActor static func apply(_ item: NSToolbarItem) {
        if let tip = byLabel[item.label] { item.toolTip = tip }
    }
    static func install() {
        NotificationCenter.default.addObserver(forName: NSToolbar.willAddItemNotification, object: nil, queue: .main) { n in
            guard let item = n.userInfo?["item"] as? NSToolbarItem else { return }
            apply(item)
            DispatchQueue.main.async { apply(item) } // label can be filled in just after insertion
        }
    }
}

struct HideToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.toolbar(removing: .title) } else { content }
    }
}
