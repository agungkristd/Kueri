import SwiftUI
import os

// (~/Library/Preferences/app.kueri.plist, readable only by the user). Not Keychain, by choice.
// Limitation: password stored in plain text; Keychain storage would encrypt it at rest

struct Conn: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case sqlite = "SQLite", postgres = "PostgreSQL", mysql = "MySQL / MariaDB", redis = "Redis"
        var shortName: String { self == .mysql ? "MySQL" : rawValue }
        var icon: String {
            switch self {
            case .postgres, .mysql: "cylinder.split.1x2"
            case .sqlite: "doc"
            case .redis: "memorychip"
            }
        }
        var defaults: (port: String, user: String, database: String) {
            switch self {
            case .postgres: ("5432", "postgres", "postgres")
            case .mysql: ("3306", "root", "")
            case .redis: ("6379", "", "0")
            case .sqlite: ("", "", "")
            }
        }
    }
    var id = UUID()
    var name = "New connection"
    var kind = Kind.postgres
    var host = "localhost", port = "5432", user = "postgres", database = "postgres"
    var path = ""
    var password: String? // optional so connections saved before this field still decode
    var allowPublicKeyRetrieval: Bool? // MySQL caching_sha2 without TLS; nil = off
    var allowCleartextPassword: Bool?  // Postgres "password" auth / Redis AUTH to non-local hosts; nil = off
    var isProduction: Bool?            // asks before risky queries, saves and imports
    var tls: TLSMode?                  // nil = the default for the kind (Postgres prefer, others off)
    var useSSH: Bool?                  // tunnel through ssh; host/port are then as seen from the SSH server
    var sshHost: String?, sshPort: String?, sshUser: String?, sshKey: String?
    var tlsMode: TLSMode { tls ?? (kind == .postgres ? .prefer : .off) }
    var isProd: Bool { isProduction == true }
    /// " on production <name>" for confirmation titles, empty otherwise.
    var onProduction: String { isProd ? " on production \(name)" : "" }
}

@Observable final class Store {
    var conns: [Conn] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(conns), forKey: "conns") }
    }
    init() {
        LegacyMigration.run() // before reading, so connections saved under the old name show up
        conns = (UserDefaults.standard.data(forKey: "conns").flatMap { try? JSONDecoder().decode([Conn].self, from: $0) }) ?? []
    }
}

/// One-time import from the app's previous name (LiteTable, bundle id local.litetable): connections,
/// panel settings and query history. Copies only; never deletes the old data.
enum LegacyMigration {
    static func run(defaults d: UserDefaults = .standard, old: UserDefaults? = UserDefaults(suiteName: "local.litetable"),
                    support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        if d.data(forKey: "conns") == nil, let old, old.data(forKey: "conns") != nil {
            for k in ["conns", "showDetails", "showEditor"] { if let v = old.object(forKey: k) { d.set(v, forKey: k) } }
        }
        let fm = FileManager.default
        let oldHistory = support.appendingPathComponent("LiteTable/history.json")
        let newHistory = support.appendingPathComponent("Kueri/history.json")
        if !fm.fileExists(atPath: newHistory.path), fm.fileExists(atPath: oldHistory.path) {
            try? fm.createDirectory(at: newHistory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: oldHistory, to: newHistory)
        }
    }
}
