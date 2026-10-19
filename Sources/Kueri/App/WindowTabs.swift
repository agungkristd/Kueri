import AppKit
import SwiftUI

/// Puts each new window into the tab group of an existing one, regardless of the system
/// "prefer tabs" setting.
struct TabJoiner: NSViewRepresentable {
    var workspace: Bool
    final class V: NSView {
        var workspace = false { didSet { if workspace != oldValue { DispatchQueue.main.async { self.chrome() } } } }
        private var closing: Any?
        deinit { closing.map(NotificationCenter.default.removeObserver) }
        override func viewDidMoveToWindow() {
            guard let w = window else { return }
            // Closing the other tabs leaves a lone connection screen: hide its tab bar again.
            closing = closing ?? NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
                guard n.object as? NSWindow !== self?.window else { return }
                DispatchQueue.main.async { self?.chrome() }
            }
            // Keeps SwiftUI's own tabbingIdentifier: a new window only opens straight into the tab group
            // when it matches the existing windows.
            w.tabbingMode = .preferred
            let host = NSApp.windows.first(where: { $0 !== w && $0.isVisible && $0.tabbingIdentifier == w.tabbingIdentifier })
            let joining = host != nil && w.tabbedWindows?.count ?? 1 <= 1
            if joining { w.alphaValue = 0 } // shown only once it's a tab, not as a window first
            DispatchQueue.main.async {
                if joining, let host {
                    host.addTabbedWindow(w, ordered: .above)
                    w.alphaValue = 1
                    w.makeKeyAndOrderFront(nil)
                }
                self.chrome()
            }
        }
        /// A connection keeps the tab bar visible so tabs are discoverable; a lone connection screen
        /// shows just the plain title bar instead of a title bar plus a one-tab bar.
        func chrome() {
            guard let w = window else { return }
            // In a workspace the toolbar has its own (renamable) title and the tab shows it too.
            w.titleVisibility = workspace ? .hidden : .visible
            let show = workspace || (w.tabbedWindows?.count ?? 1) > 1
            if let g = w.tabGroup, g.isTabBarVisible != show { w.toggleTabBar(nil) }
        }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.workspace = workspace; return v }
    func updateNSView(_ v: V, context: Context) { v.workspace = workspace }
}

/// The tab shows the chosen connection while the toolbar keeps the app name.
struct TabTitle: NSViewRepresentable {
    var title: String
    final class V: NSView {
        var title = "" { didSet { window?.tab.title = title } }
        override func viewDidMoveToWindow() { window?.tab.title = title }
        override func viewWillMove(toWindow w: NSWindow?) { if w == nil { window?.tab.title = nil } } // back to the window title
    }
    func makeNSView(context: Context) -> V { let v = V(); v.title = title; return v }
    func updateNSView(_ v: V, context: Context) { v.title = title }
}
