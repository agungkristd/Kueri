import SwiftUI

// MARK: Connection bar ("PostgreSQL 16.8 : local : shop : public.users")

struct ConnectionBar: View {
    let session: Session
    /// White text on these meets WCAG AA (≈5:1); red marks a production connection.
    static let normal = Color(red: 0.18, green: 0.45, blue: 0.27), production = Color(red: 0.70, green: 0.15, blue: 0.12)

    private var object: String? {
        let t: String? = switch session.kind {
        case .data: session.table
        case .structure(let n), .diagram(let n): n
        }
        guard let t else { return nil }
        // Postgres tables in the default schema are listed bare; the bar always says which schema.
        if session.conn.kind == .postgres, session.schemaOf(t) == "public", !t.hasPrefix("public.") { return "public." + t }
        return t
    }

    var body: some View {
        let parts = [session.serverVersion, session.conn.name, session.conn.kind == .sqlite ? "" : session.conn.database, object ?? ""]
            .filter { !$0.isEmpty }
        // Monospaced so identifiers read exactly as typed; small, not a "terminal" look.
        Text(parts.joined(separator: " : "))
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.white)
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(session.conn.isProduction == true ? Self.production : Self.normal))
            .help(parts.joined(separator: " : ") + (session.conn.isProduction == true ? " (production)" : ""))
    }
}

/// Search by words: every word of the query (split on spaces, `_`, `-`, `.`) appears in the text,
/// in any order and case. "shop local" finds `shop_local`; an empty query matches everything.
func nameMatches(_ query: String, _ text: String) -> Bool {
    let words = query.lowercased().split(whereSeparator: { " _-.".contains($0) })
    let t = text.lowercased()
    return words.allSatisfy { t.contains($0) }
}

// MARK: Database dropdown (⌘K)

struct DatabaseDropdown: View {
    @Bindable var session: Session
    let newDatabase: () -> Void
    let close: () -> Void
    @State private var search = ""
    @State private var highlighted: String?
    @State private var monitor: Any?
    @State private var frame = CGRect.zero
    @FocusState private var focused: Bool

    private var filtered: [String] {
        session.databases.filter { nameMatches(search, $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search for database…", text: $search)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if let db = highlighted ?? filtered.first { open(db) } }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onExitCommand(perform: close)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered, id: \.self) { db in row(db).id(db) }
                        if filtered.isEmpty {
                            Text("No databases match “\(search)”").foregroundStyle(.secondary).padding(.vertical, 10)
                        }
                    }
                    .padding(4)
                }
                .onChange(of: highlighted) { _, h in if let h { proxy.scrollTo(h) } }
                .onAppear { proxy.scrollTo(session.conn.database, anchor: .center) }
            }
            .frame(maxHeight: 340)
            Divider()
            Button { close(); newDatabase() } label: {
                Label("New Database…", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 7)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .background(GeometryReader { g in Color.clear.onAppear { frame = g.frame(in: .global) }.onChange(of: g.frame(in: .global)) { frame = $1 } })
        .onAppear {
            focused = true
            highlighted = session.conn.database
            // Like a menu: a click anywhere outside closes it (the click still goes through).
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { e in
                if let w = e.window, let content = w.contentView {
                    let p = CGPoint(x: e.locationInWindow.x, y: content.bounds.height - e.locationInWindow.y)
                    if !frame.insetBy(dx: 0, dy: -34).contains(p) { DispatchQueue.main.async { close() } }
                }
                return e
            }
        }
        .onDisappear { monitor.map(NSEvent.removeMonitor); monitor = nil }
    }

    private func row(_ db: String) -> some View {
        Button { open(db) } label: {
            HStack(spacing: 8) {
                Image(systemName: "cylinder.split.1x2").foregroundStyle(.tint)
                Text(db).lineLimit(1).truncationMode(.middle)
                Spacer()
                if db == session.conn.database { Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(db == highlighted ? Color.accentColor.opacity(0.35) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlighted = db } }
    }

    private func move(_ step: Int) {
        let list = filtered
        guard !list.isEmpty else { return }
        let i = highlighted.flatMap(list.firstIndex(of:)) ?? -step
        highlighted = list[min(max(i + step, 0), list.count - 1)]
    }

    private func open(_ db: String) { close(); if db != session.conn.database { session.switchDatabase(db) } }
}

// MARK: History in the sidebar (per connection + database)

struct HistorySidebar: View {
    let history: QueryHistory
    let conn: Conn
    let use: (String) -> Void
    @State private var search = ""
    @State private var picked: HistoryEntry.ID?

    private var mine: [HistoryEntry] {
        history.entries.filter { e in
            e.database == conn.database && (e.connectionID.map { $0 == conn.id } ?? (e.connection == conn.name))
                && nameMatches(search, e.sql)
        }
    }
    private var days: [(Date, [HistoryEntry])] {
        Dictionary(grouping: mine) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search history…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10).padding(.vertical, 8)
            if mine.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No history" : "No matches", systemImage: "clock.arrow.circlepath",
                                       description: Text(search.isEmpty ? "Queries you run on \(conn.database.isEmpty ? conn.name : conn.database) appear here." : ""))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $picked) {
                    ForEach(days, id: \.0) { day, entries in
                        Section(day.formatted(date: .long, time: .omitted)) {
                            ForEach(entries) { e in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(e.date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                                        if e.error != nil { Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red).help(e.error ?? "") }
                                    }
                                    Text(highlightSQL(e.sql)).font(.system(.callout, design: .monospaced)).lineLimit(4)
                                }
                                .padding(.vertical, 2)
                                .tag(e.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: picked) { _, id in if let e = mine.first(where: { $0.id == id }) { use(e.sql) } }
            }
        }
    }
}

/// Keywords, strings, numbers and comments coloured for read-only SQL (history list).
func highlightSQL(_ sql: String) -> AttributedString {
    var out = AttributedString()
    let keywords = Set(SQLCompleter.sqlKeywords + SQLCompleter.redisCommands)
    let chars = Array(sql)
    var i = 0
    func add(_ s: String, _ c: Color?) { var a = AttributedString(s); if let c { a.foregroundColor = c }; out += a }
    while i < chars.count {
        let c = chars[i]
        if c == "'" || c == "\"" || c == "`" {
            var j = i + 1
            while j < chars.count, chars[j] != c { j += 1 }
            j = min(j + 1, chars.count)
            add(String(chars[i..<j]), c == "'" ? Color(nsColor: .systemRed) : Color(nsColor: .systemPink)); i = j
        } else if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
            var j = i; while j < chars.count, chars[j] != "\n" { j += 1 }
            add(String(chars[i..<j]), .secondary); i = j
        } else if c.isLetter || c == "_" {
            var j = i; while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
            let w = String(chars[i..<j])
            add(w, keywords.contains(w.uppercased()) ? Color(nsColor: .systemBlue) : nil); i = j
        } else if c.isNumber {
            var j = i; while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
            add(String(chars[i..<j]), Color(nsColor: .systemPurple)); i = j
        } else {
            add(String(c), nil); i += 1
        }
    }
    return out
}
