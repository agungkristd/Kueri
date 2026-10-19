import SwiftUI

struct TableActionSheet: View {
    let action: TableAction
    let table: String
    let session: Session
    let done: () -> Void
    @State private var newName = ""
    @State private var withData = true
    @State private var typed = ""
    @State private var running = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch action {
            case .clone:
                Text("Clone \(table)").font(.headline)
                TextField("New table name", text: $newName).textFieldStyle(.roundedBorder).selectAllOnFocus()
                Toggle("Copy data too", isOn: $withData)
                if session.conn.kind == .sqlite {
                    Text("SQLite copies columns and data, but not constraints or indexes.").font(.caption).foregroundStyle(.secondary)
                }
                sqlPreview(session.cloneSQL(table, to: newName, withData: withData))
            default:
                Text(action == .truncate ? "Truncate \(table)?" : "Delete \(table)?").font(.headline)
                Text(action == .truncate
                     ? "Every row is deleted. The table itself stays. This cannot be undone."
                     : "The table and all its data are dropped. This cannot be undone.")
                    .foregroundStyle(.secondary)
                Text("Connection: \(session.conn.name) · \(session.conn.database)").font(.caption).foregroundStyle(.secondary)
                // Typing the name guards against the wrong table / wrong database (e.g. production).
                TextField("Type \(table) to confirm", text: $typed).textFieldStyle(.roundedBorder)
                sqlPreview(action == .truncate ? session.truncateSQL(table) : session.dropSQL(table))
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(action == .clone ? "Clone" : (action == .truncate ? "Truncate" : "Delete"), role: action == .clone ? nil : .destructive) { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || !canRun)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear { newName = "\(table)_copy" }
    }

    private var canRun: Bool {
        action == .clone ? !newName.trimmingCharacters(in: .whitespaces).isEmpty && newName != table : typed == table
    }

    private func sqlPreview(_ sql: String) -> some View {
        Text(sql).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }

    private func run() {
        let sql: String = switch action {
        case .clone: session.cloneSQL(table, to: newName.trimmingCharacters(in: .whitespaces), withData: withData)
        case .truncate: session.truncateSQL(table)
        default: session.dropSQL(table)
        }
        running = true; error = nil
        Task {
            defer { running = false }
            do {
                try await session.execute(sql)
                if action == .truncate, session.table == table { session.browse(table) } // show it empty
                done()
            } catch { self.error = error.localizedDescription }
        }
    }
}
