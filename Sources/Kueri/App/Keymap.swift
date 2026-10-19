import AppKit
import SwiftUI

enum KeyAction: String, CaseIterable, Identifiable {
    case run, stop, save, filterRows, formatSQL, toggleEditor, history, processes, toggleSidebar, toggleDetails, switchDatabase, newTab, renameConnection
    var id: String { rawValue }
    var title: String {
        switch self {
        case .run: "Run query"
        case .stop: "Stop query"
        case .save: "Save changes"
        case .filterRows: "Filter result rows"
        case .formatSQL: "Format SQL"
        case .toggleEditor: "Show / hide SQL editor"
        case .history: "Query history"
        case .processes: "Server processes"
        case .toggleSidebar: "Show / hide sidebar"
        case .toggleDetails: "Show / hide row details"
        case .switchDatabase: "Switch database"
        case .newTab: "New tab"
        case .renameConnection: "Rename connection"
        }
    }
    var group: String {
        switch self {
        case .run, .stop, .save, .filterRows, .formatSQL, .toggleEditor: "Query"
        case .history, .processes, .toggleSidebar, .toggleDetails: "View"
        case .switchDatabase, .newTab, .renameConnection: "Connection"
        }
    }
    var defaultShortcut: Shortcut {
        switch self {
        case .run: Shortcut(key: "\r", modifiers: [.command])
        case .stop: Shortcut(key: ".", modifiers: [.command])
        case .save: Shortcut(key: "s", modifiers: [.command])
        case .filterRows: Shortcut(key: "f", modifiers: [.command])
        case .formatSQL: Shortcut(key: "f", modifiers: [.command, .shift])
        case .toggleEditor: Shortcut(key: "e", modifiers: [.command, .shift])
        case .history: Shortcut(key: "y", modifiers: [.command])
        case .processes: Shortcut(key: "p", modifiers: [.command, .shift])
        case .toggleSidebar: Shortcut(key: "b", modifiers: [.command])
        case .toggleDetails: Shortcut(key: "b", modifiers: [.command, .shift])
        case .switchDatabase: Shortcut(key: "k", modifiers: [.command])
        case .newTab: Shortcut(key: "t", modifiers: [.command])
        case .renameConnection: Shortcut(key: "r", modifiers: [.command, .shift])
        }
    }
}

/// A key plus modifiers, stored as text (lowercased key, "\r" for Return).
struct Shortcut: Codable, Equatable {
    var key: String
    var flags: UInt

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        flags = modifiers.intersection([.command, .shift, .option, .control]).rawValue
    }
    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: flags) }

    var keyboardShortcut: KeyboardShortcut {
        var m: EventModifiers = []
        if modifiers.contains(.command) { m.insert(.command) }
        if modifiers.contains(.shift) { m.insert(.shift) }
        if modifiers.contains(.option) { m.insert(.option) }
        if modifiers.contains(.control) { m.insert(.control) }
        let k: KeyEquivalent = switch key {
        case "\r": .return
        case "\t": .tab
        case "\u{1b}": .escape
        case "\u{7f}": .delete
        default: KeyEquivalent(Character(key))
        }
        return KeyboardShortcut(k, modifiers: m)
    }

    /// "⇧⌘E", in the order macOS menus use.
    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let names = ["\r": "↩", "\t": "⇥", "\u{1b}": "⎋", "\u{7f}": "⌫", " ": "Space", ".": "."]
        return s + (names[key] ?? key.uppercased())
    }

    /// From a key press while recording; nil when it can't be a shortcut (no ⌘ / ⌃ / ⌥).
    init?(event e: NSEvent) {
        let m = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !m.intersection([.command, .control, .option]).isEmpty,
              let chars = e.charactersIgnoringModifiers?.lowercased(), let c = chars.first else { return nil }
        let key = e.keyCode == 36 || e.keyCode == 76 ? "\r" : String(c)
        self.init(key: key, modifiers: m)
    }
}

@MainActor @Observable final class Keymap {
    static let shared = Keymap()
    private static let key = "keymap"
    private(set) var overrides: [String: Shortcut]

    init() {
        overrides = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Shortcut].self, from: $0) } ?? [:]
    }

    func shortcut(_ a: KeyAction) -> Shortcut { overrides[a.rawValue] ?? a.defaultShortcut }
    func keyboardShortcut(_ a: KeyAction) -> KeyboardShortcut { shortcut(a).keyboardShortcut }
    func display(_ a: KeyAction) -> String { shortcut(a).display }

    /// The action already using this shortcut, if any (other than `a`).
    func conflict(_ s: Shortcut, for a: KeyAction) -> KeyAction? {
        KeyAction.allCases.first { $0 != a && shortcut($0) == s }
    }

    func set(_ s: Shortcut, for a: KeyAction) { overrides[a.rawValue] = s == a.defaultShortcut ? nil : s; persist() }
    func reset(_ a: KeyAction) { overrides[a.rawValue] = nil; persist() }
    func resetAll() { overrides = [:]; persist() }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(overrides), forKey: Self.key)
    }
}

extension View {
    /// Keyboard shortcut from the user's keymap.
    func shortcut(_ a: KeyAction) -> some View { keyboardShortcut(Keymap.shared.keyboardShortcut(a)) }
}
