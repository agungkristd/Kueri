import SwiftUI

enum PGDumpFilter {
    /// `SET` parameters newer pg_dump writes that older servers reject, with the first version that knows them.
    static let settings: [(name: String, since: Int)] = [
        ("transaction_timeout", 170000), ("default_table_access_method", 120000),
        ("idle_in_transaction_session_timeout", 90600), ("row_security", 90500),
    ]

    /// Temp copy of the dump for psql: unsupported top-level SET lines dropped (`removed` counts them),
    /// the dump's own \restrict/\unrestrict lines dropped, and the whole file wrapped in \restrict with a
    /// random key, so psql runs it as plain SQL and refuses any meta-command inside. Streams the file.
    static func filtered(_ url: URL, serverVersion: Int, key: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")) throws -> (URL, removed: Int) {
        let drop = settings.filter { serverVersion > 0 && serverVersion < $0.since }.map { Array("SET \($0.name) = ".utf8) }
        let ownRestrict = [Array("\\restrict ".utf8), Array("\\unrestrict ".utf8)]
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("kueri-import-\(UUID()).sql")
        FileManager.default.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let w = try FileHandle(forWritingTo: out)
        defer { try? w.close() }
        let r = try FileHandle(forReadingFrom: url)
        defer { try? r.close() }
        w.write(Data("\\restrict \(key)\n".utf8))
        var removed = 0, pending: [UInt8] = []
        func emit(_ line: ArraySlice<UInt8>) {
            if drop.contains(where: { line.starts(with: $0) }) { removed += 1; return }
            if ownRestrict.contains(where: { line.starts(with: $0) }) { return }
            w.write(Data(line)); w.write(Data([10]))
        }
        while let chunk = try r.read(upToCount: 1 << 20), !chunk.isEmpty {
            pending += chunk
            var start = 0
            while let nl = pending[start...].firstIndex(of: 10) { emit(pending[start..<nl]); start = nl + 1 }
            pending.removeFirst(start)
        }
        if !pending.isEmpty { emit(pending[...]) }
        w.write(Data("\\unrestrict \(key)\n".utf8))
        return (out, removed)
    }
}
