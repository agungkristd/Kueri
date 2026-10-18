import AppKit

/// Port forward through the system's `ssh` (so ~/.ssh/config, keys and ssh-agent apply):
/// `127.0.0.1:<free port>` → `dbHost:dbPort` as seen from the SSH server.
/// Password logins aren't supported (BatchMode); key-based auth only.
final class SSHTunnel: @unchecked Sendable {
    let localPort: Int
    private let process = Process()
    private let stderr = Pipe()

    nonisolated(unsafe) private static var live: [ObjectIdentifier: Process] = [:]
    private static let lock = NSLock()

    init(sshHost: String, sshPort: String, sshUser: String, keyPath: String?, dbHost: String, dbPort: String) throws {
        localPort = try Self.freePort()
        var args = ["-N",
                    "-o", "BatchMode=yes",                 // fail instead of prompting for a password
                    "-o", "ExitOnForwardFailure=yes",
                    "-o", "ConnectTimeout=10",
                    "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
                    "-o", "StrictHostKeyChecking=accept-new", // trust on first use; a changed key is still refused
                    "-L", "127.0.0.1:\(localPort):\(dbHost.isEmpty ? "localhost" : dbHost):\(dbPort)",
                    "-p", sshPort.isEmpty ? "22" : sshPort]
        if let keyPath, !keyPath.isEmpty { args += ["-i", (keyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        args.append(sshUser.isEmpty ? sshHost : "\(sshUser)@\(sshHost)")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        Self.lock.withLock { Self.live[ObjectIdentifier(self)] = process }

        // Ready when the local end accepts connections; fail with ssh's own message if it exits.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if !process.isRunning {
                let msg = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw DBError("SSH tunnel to \(sshHost) failed: \(msg.isEmpty ? "ssh exited with status \(process.terminationStatus)" : msg)")
            }
            if Self.canConnect(localPort) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.terminate()
        throw DBError("SSH tunnel to \(sshHost) timed out")
    }

    deinit {
        if process.isRunning { process.terminate() }
        Self.lock.withLock { _ = Self.live.removeValue(forKey: ObjectIdentifier(self)) }
    }

    /// Called at app quit so no ssh process outlives Kueri.
    static func terminateAll() { lock.withLock { live.values.forEach { if $0.isRunning { $0.terminate() } } } }

    private static func freePort() throws -> Int {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(s) }
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                               sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) == 0 && getsockname(s, $0, &len) == 0 }
        }
        guard ok else { throw DBError("No free local port for the SSH tunnel") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private static func canConnect(_ port: Int) -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(s) }
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                               sin_port: in_port_t(UInt16(port).bigEndian), sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
                               sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
