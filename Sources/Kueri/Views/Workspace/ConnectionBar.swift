import SwiftUI

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
            .background(RoundedRectangle(cornerRadius: 6).fill(session.conn.isProd ? Self.production : Self.normal))
            .help(parts.joined(separator: " : ") + (session.conn.isProd ? " (production)" : ""))
    }
}
