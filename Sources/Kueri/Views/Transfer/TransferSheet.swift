import SwiftUI

struct TransferSheet: View {
    enum Mode { case export, `import` }
    let mode: Mode
    let session: Session
    let done: () -> Void
    @State private var content = DumpContent.all
    @State private var format = DumpFormat.sql
    @State private var stopOnError = true
    @State private var file: URL?
    @State private var typed = ""
    @State private var running = false
    @State private var result: String?
    @State private var error: String?
    @State private var cancel = TransferCancel()
    @State private var started = Date()

    private var target: String { session.conn.kind == .sqlite ? session.conn.name : "\(session.conn.name) · \(session.conn.database)" }
    private var production: Bool { session.conn.isProd }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .export ? "Export Database" : "Import Database").font(.headline)
            LabeledContent(mode == .export ? "From" : "Into") { Text(target).fontWeight(.medium) }
            if mode == .export {
                Picker("Format", selection: $format) { ForEach(DumpFormat.available(for: session.conn.kind)) { Text($0.rawValue).tag($0) } }
                if !(format == .backup && session.conn.kind == .sqlite) { // a SQLite backup is always the whole file
                    Picker("Content", selection: $content) { ForEach(DumpContent.allCases) { Text($0.rawValue).tag($0) } }
                }
                Text(formatNote).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text(file?.lastPathComponent ?? "No file chosen").foregroundStyle(file == nil ? .secondary : .primary).lineLimit(1)
                    Spacer()
                    Button("Choose…") { chooseFile() }.disabled(running)
                }
                Text(importNote).font(.caption).foregroundStyle(.secondary)
                Toggle("Stop at the first error", isOn: $stopOnError)
                if production {
                    // Imports can overwrite whole tables: on production, the database name must be typed.
                    TextField("Type \(session.conn.database) to confirm", text: $typed).textFieldStyle(.roundedBorder)
                }
            }
            if running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: started, by: 1)) { ctx in
                        Text("\(mode == .export ? "Exporting" : "Importing")… \(Int(ctx.date.timeIntervalSince(started)))s").foregroundStyle(.secondary)
                    }
                }
            }
            if let result { Text(result).font(.callout).textSelection(.enabled) }
            if let error { ScrollView { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160) }
            HStack {
                Spacer()
                if running {
                    Button("Cancel") { cancel.cancel() }
                } else {
                    Button(result == nil ? "Cancel" : "Close", action: done).keyboardShortcut(.cancelAction)
                    if result == nil {
                        Button(mode == .export ? "Export…" : "Import") { mode == .export ? startExport() : startImport() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(mode == .import && (file == nil || (production && typed != session.conn.database)))
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private var importNote: String {
        switch session.conn.kind {
        case .postgres: "SQL scripts and every pg_dump archive: custom (.dump, .backup, .bak), tar (.tar) or a directory archive folder. The format is read from the file, not its name."
        case .sqlite: "SQL scripts, or a SQLite database file / .bak to restore over this database."
        default: "SQL scripts (.sql, .bak)."
        }
    }

    private var formatNote: String {
        switch (session.conn.kind, format) {
        case (.postgres, .custom), (.postgres, .backup):
            "pg_dump custom archive (\(format == .custom ? ".dump" : ".bak") is only the name): compressed, restored with pg_restore, including into other PostgreSQL versions."
        case (.postgres, .tar): "pg_dump tar archive: uncompressed, restored with pg_restore."
        case (.postgres, .directory): "pg_dump directory archive: a folder with one compressed file per table, restored with pg_restore."
        case (.sqlite, .backup): "A consistent copy of the whole database file."
        case (.mysql, .backup): "Same SQL dump as .sql, with a .bak name."
        default: "Plain SQL statements, readable and editable; imports into this or another server version."
        }
    }

    private func chooseFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["sql", "bak", "dump", "backup", "tar", "db", "sqlite"].compactMap { .init(filenameExtension: $0) } + [.data]
        p.canChooseDirectories = session.conn.kind == .postgres // pg_dump directory archives
        if p.runModal() == .OK { file = p.url }
    }

    private func startExport() {
        let p = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)) + "-" +
            Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)).replacingOccurrences(of: ":", with: "")
        let base = session.conn.kind == .sqlite ? (session.conn.path as NSString).lastPathComponent : session.conn.database
        p.nameFieldStringValue = "\(base)-\(stamp)" + (format.ext.isEmpty ? "" : ".\(format.ext)")
        guard p.runModal() == .OK, let url = p.url else { return }
        go {
            try await session.exportDatabase(to: url, content: content, format: format, cancel: cancel)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return "Saved \(url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))"
        }
    }

    private func startImport() {
        guard let file else { return }
        go { try await session.importFile(file, stopOnError: stopOnError, cancel: cancel) }
    }

    private func go(_ work: @escaping () async throws -> String) {
        running = true; error = nil; result = nil; cancel = TransferCancel(); started = Date()
        Task {
            defer { running = false }
            do { result = try await work() + " in \(Int(Date().timeIntervalSince(started)))s" }
            catch { self.error = error.localizedDescription }
        }
    }
}
