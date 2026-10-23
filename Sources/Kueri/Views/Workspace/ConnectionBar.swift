import SwiftUI

/// Where the workspace is: status, server, connection › database › table. A lost connection turns
/// the status dot red; the Reconnect button is the banner in the content area (ConnectionLostBar),
/// a small one in here went unnoticed.
struct ConnectionBar: View {
    let session: Session
    /// White text on it meets WCAG AA (≈5:1); marks a production connection.
    static let production = Color(red: 0.70, green: 0.15, blue: 0.12)

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
        let path = [session.conn.name, session.conn.kind == .sqlite ? "" : session.conn.database, object ?? ""].filter { !$0.isEmpty }
        let lost = session.connectionLost
        HStack(spacing: 6) {
            Circle().fill(session.reconnecting ? .orange : lost ? .red : .green).frame(width: 7, height: 7)
                .help(session.reconnecting ? "Reconnecting…" : lost ? "Connection lost" : "Connected")
            Image(systemName: session.conn.kind.icon).foregroundStyle(.secondary)
            if !session.serverVersion.isEmpty {
                Text(session.serverVersion).foregroundStyle(.secondary)
                Divider().frame(height: 12)
            }
            ForEach(Array(path.enumerated()), id: \.offset) { i, p in
                if i > 0 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                Text(p).fontWeight(i == path.count - 1 ? .semibold : .regular)
            }
            if session.conn.isProd {
                Text("PROD").font(.caption2.weight(.bold)).foregroundStyle(.white).fixedSize()
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Self.production))
                    .help("Production: Kueri asks before risky queries, saves and imports")
            }
        }
        .font(.callout)
        .lineLimit(1).truncationMode(.middle)
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(lost ? Color.red.opacity(0.6) : .clear))
        .help(([session.serverVersion] + path).filter { !$0.isEmpty }.joined(separator: " › ") + (session.conn.isProd ? " (production)" : ""))
    }
}
