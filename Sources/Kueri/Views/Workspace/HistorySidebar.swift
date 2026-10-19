import SwiftUI

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
            SidebarSearchField(prompt: "Search history…", text: $search)
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
