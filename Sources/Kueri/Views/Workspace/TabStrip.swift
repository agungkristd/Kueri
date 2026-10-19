import SwiftUI

/// Table tab bar in plain AppKit (NSButton target/action). The SwiftUI version's tap gestures and
/// buttons didn't switch tabs on click in the real window, so this avoids SwiftUI's gesture layer.
/// One tab: icon, title and close button inside a single rounded shape (filled when active,
/// a lighter fill while the pointer is over an inactive one).
final class TabPill: NSView {
    private let active: Bool
    private var hovering = false { didSet { updateFill() } }

    init(title: NSButton, close: NSButton, active: Bool) {
        self.active = active
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        let row = NSStackView(views: [title, close])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        updateFill()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func viewDidChangeEffectiveAppearance() { updateFill() }
    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (active ? NSColor.quaternaryLabelColor : hovering ? NSColor.quaternaryLabelColor.withAlphaComponent(0.5) : .clear).cgColor
        }
    }
}

struct TabStrip: NSViewRepresentable {
    @Bindable var session: Session

    final class Coordinator: NSObject {
        var session: Session?
        var ids: [UUID] = []
        @MainActor @objc func select(_ b: NSButton) { if ids.indices.contains(b.tag) { session?.selectTab(ids[b.tag]) } }
        @MainActor @objc func close(_ b: NSButton) { if ids.indices.contains(b.tag) { session?.closeTab(ids[b.tag]) } }
        @MainActor @objc func add(_ b: NSButton) { session?.newTab() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        let line = NSBox(); line.boxType = .separator; line.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(line)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor), stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor), line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 32),
        ])
        return bar
    }

    func updateNSView(_ bar: NSView, context: Context) {
        let c = context.coordinator
        c.session = session
        guard let stack = bar.subviews.compactMap({ $0 as? NSStackView }).first else { return }
        let tabs = session.tabList
        c.ids = tabs.map(\.id)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() } // few tabs: rebuilding is cheap
        for (i, t) in tabs.enumerated() {
            let active = t.id == session.activeTab
            let title = t.title + (t.edits.isEmpty ? "" : " •")
            let b = NSButton(title: title, image: NSImage(systemSymbolName: icon(t.kind), accessibilityDescription: nil) ?? NSImage(),
                             target: c, action: #selector(Coordinator.select(_:)))
            b.tag = i
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.lineBreakMode = .byTruncatingTail
            b.toolTip = t.title
            b.contentTintColor = active ? .labelColor : .secondaryLabelColor
            b.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small) + 1, weight: active ? .semibold : .regular)
            b.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let x = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")!
                                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))!,
                             target: c, action: #selector(Coordinator.close(_:)))
            x.tag = i
            x.isBordered = false
            x.toolTip = "Close tab"
            x.contentTintColor = .secondaryLabelColor
            stack.addArrangedSubview(TabPill(title: b, close: x, active: active))
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        stack.addArrangedSubview(spacer)
        let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New query tab")!,
                            target: c, action: #selector(Coordinator.add(_:)))
        plus.bezelStyle = .recessed
        plus.showsBorderOnlyWhileMouseInside = true
        plus.toolTip = "New query tab"
        stack.addArrangedSubview(plus)
    }

    private func icon(_ k: TabKind) -> String {
        switch k {
        case .data: "tablecells"
        case .structure: "list.bullet.rectangle"
        case .diagram: "point.3.connected.trianglepath.dotted"
        }
    }
}
