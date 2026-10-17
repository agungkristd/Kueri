import Foundation

/// Blocking TCP socket with a read buffer. Used by the MySQL and Redis drivers,
/// which always run on their session's background queue.
// Limitation: no TLS, add Network.framework NWConnection with TLS options if you connect to remote servers over the internet
final class Socket {
    private let fd: Int32
    private var buf: [UInt8] = []
    private var pos = 0

    init(host: String, port: String) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host.isEmpty ? "localhost" : host, port, &hints, &res)
        guard rc == 0 else { throw DBError("\(host): \(String(cString: gai_strerror(rc)))") }
        defer { freeaddrinfo(res) }
        var err = ECONNREFUSED
        var p = res
        while let a = p {
            let s = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if s >= 0 {
                var one: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                if connect(s, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 { fd = s; return }
                err = errno
                close(s)
            }
            p = a.pointee.ai_next
        }
        throw DBError("Cannot connect to \(host):\(port): \(String(cString: strerror(err)))")
    }
    deinit { close(fd) }

    func write(_ bytes: [UInt8]) throws {
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress! + off, bytes.count - off) }
            guard n > 0 else { throw DBError("Connection lost") }
            off += n
        }
    }

    private func fill() throws {
        if pos > 0 { buf.removeFirst(pos); pos = 0 }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(fd, &chunk, chunk.count)
        guard n > 0 else { throw DBError("Connection closed by server") }
        buf += chunk[0..<n]
    }

    func read(count: Int) throws -> [UInt8] {
        while buf.count - pos < count { try fill() }
        defer { pos += count }
        return Array(buf[pos..<pos + count])
    }

    /// Reads up to and excluding "\r\n" (header lines never contain a bare LF).
    /// Header lines are short; a server that never sends LF must not grow the buffer forever.
    static let maxLine = 64 * 1024

    func readLine() throws -> [UInt8] {
        while true {
            if let i = buf[pos...].firstIndex(of: 10) {
                defer { pos = i + 1 }
                return Array(buf[pos..<max(pos, i - 1)])
            }
            guard buf.count - pos <= Self.maxLine else { throw DBError("Server sent a line longer than \(Self.maxLine / 1024) KB") }
            try fill()
        }
    }
}
