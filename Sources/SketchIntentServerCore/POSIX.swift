import Darwin
import Foundation

enum SocketError: Error, CustomStringConvertible {
    case failed(String, Int32)

    var description: String {
        switch self {
        case .failed(let action, let code):
            return "\(action) failed: \(String(cString: strerror(code)))"
        }
    }
}

enum POSIX {
    static func configure(_ fd: Int32) {
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        // Autotuned send buffers hold hundreds of milliseconds of video after the iPad
        // stops reading as fast as we encode. 256 KB is about two frames, so write()
        // pushes back instead of hiding the stall.
        var sendBuffer = 256 * 1024
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout.size(ofValue: sendBuffer)))
    }

    static func connectUNIX(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.failed("socket", errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        try writeUNIXPath(path, into: &address)

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.connect(fd, socketPointer, size)
            }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketError.failed("connect \(path)", code)
        }
        configure(fd)
        return fd
    }

    static func listenTCP(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.failed("socket", errno) }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(0))

        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                bind(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketError.failed("bind port \(port)", code)
        }
        guard listen(fd, 8) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketError.failed("listen", code)
        }
        configure(fd)
        return fd
    }

    static func boundPort(_ fd: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                getsockname(fd, socketPointer, &length)
            }
        }
        guard result == 0 else { throw SocketError.failed("getsockname", errno) }
        return UInt16(bigEndian: address.sin_port)
    }

    static func connectTCP(host: String, port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.failed("socket", errno) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            Darwin.close(fd)
            throw SocketError.failed("resolve \(host)", EINVAL)
        }

        let connected = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.connect(fd, socketPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketError.failed("connect \(host):\(port)", code)
        }
        configure(fd)
        return fd
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        if data.isEmpty { return true }
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(fd, base, buffer.count)
            }
            if written > 0 {
                remaining.removeFirst(written)
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    static func readExact(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var filled = 0
        while filled < count {
            let readCount = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: filled), count - filled)
            }
            if readCount > 0 {
                filled += readCount
            } else if readCount < 0 && errno == EINTR {
                continue
            } else {
                throw SocketError.failed("read", readCount == 0 ? ECONNRESET : errno)
            }
        }
        return data
    }

    static func close(_ fd: Int32) {
        _ = Darwin.close(fd)
    }

    private static func writeUNIXPath(_ path: String, into address: inout sockaddr_un) throws {
        let bytes = path.utf8CString
        guard let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) else {
            throw SocketError.failed("unix address", EINVAL)
        }
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else {
            throw SocketError.failed("unix path length", ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address) { raw in
            bytes.withUnsafeBytes { source in
                guard let destination = raw.baseAddress, let start = source.baseAddress else { return }
                destination.advanced(by: offset).copyMemory(from: start, byteCount: bytes.count)
            }
        }
    }
}
