import Foundation
import COpenSSL

/// Blocking TCP socket with a read buffer and optional TLS (OpenSSL). Used by the MySQL and Redis
/// drivers, which always run on their session's background queue.
final class Socket {
    private let fd: Int32
    private var buf: [UInt8] = []
    private var pos = 0
    private var ctx: OpaquePointer?
    private var ssl: OpaquePointer?
    var isEncrypted: Bool { ssl != nil }
    private(set) var isVerified = false  // certificate chain and host name checked

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
    deinit {
        if let ssl { SSL_shutdown(ssl); SSL_free(ssl) }
        if let ctx { SSL_CTX_free(ctx) }
        close(fd)
    }

    /// Upgrades the connection to TLS 1.2+. `verify`: check the certificate chain against the
    /// system CAs and that it was issued for `host`; otherwise encrypt without checking.
    func startTLS(host: String, verify: Bool) throws {
        guard pos == buf.count else { throw DBError("Unexpected data before TLS handshake") }
        guard let c = SSL_CTX_new(TLS_client_method()) else { throw DBError("TLS: \(Self.opensslError())") }
        ctx = c
        SSL_CTX_ctrl(c, SSL_CTRL_SET_MIN_PROTO_VERSION, Int(TLS1_2_VERSION), nil)
        if verify {
            SSL_CTX_set_default_verify_paths(c)
            SSL_CTX_set_verify(c, SSL_VERIFY_PEER, nil)
        } else {
            SSL_CTX_set_verify(c, SSL_VERIFY_NONE, nil)
        }
        guard let s = SSL_new(c) else { throw DBError("TLS: \(Self.opensslError())") }
        ssl = s
        SSL_set_fd(s, fd)
        let isIP = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
        if !isIP { _ = host.withCString { SSL_ctrl(s, SSL_CTRL_SET_TLSEXT_HOSTNAME, Int(TLSEXT_NAMETYPE_host_name), UnsafeMutableRawPointer(mutating: $0)) } }
        if verify { SSL_set1_host(s, host) }
        guard SSL_connect(s) == 1 else {
            let result = SSL_get_verify_result(s)
            let why = result != X509_V_OK ? String(cString: X509_verify_cert_error_string(result)) : Self.opensslError()
            ssl = nil; SSL_free(s)
            throw DBError("TLS handshake with \(host) failed: \(why)")
        }
        isVerified = verify
    }

    private static func opensslError() -> String {
        var b = [CChar](repeating: 0, count: 256)
        ERR_error_string_n(ERR_get_error(), &b, b.count)
        return String(cString: b)
    }

    private func rawWrite(_ p: UnsafeRawPointer, _ n: Int) -> Int {
        if let ssl { return Int(SSL_write(ssl, p, Int32(min(n, Int(Int32.max))))) }
        return Darwin.write(fd, p, n)
    }
    private func rawRead(_ p: UnsafeMutableRawPointer, _ n: Int) -> Int {
        if let ssl { return Int(SSL_read(ssl, p, Int32(n))) }
        return Darwin.read(fd, p, n)
    }

    func write(_ bytes: [UInt8]) throws {
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBufferPointer { rawWrite($0.baseAddress! + off, bytes.count - off) }
            guard n > 0 else { throw DBError("Connection lost") }
            off += n
        }
    }

    private func fill() throws {
        if pos > 0 { buf.removeFirst(pos); pos = 0 }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = chunk.withUnsafeMutableBytes { rawRead($0.baseAddress!, $0.count) }
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
