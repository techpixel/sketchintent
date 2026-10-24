import Foundation

/// Accepts direct TCP clients: the iOS Simulator, and an iPad that can route to this Mac.
final class TCPListener {
    private var listenFD: Int32 = -1

    func start(port: UInt16, onAccept: @escaping (Int32) -> Void) throws {
        let fd = try POSIX.listenTCP(port: port)
        listenFD = fd
        let thread = Thread {
            while true {
                let client = Darwin.accept(fd, nil, nil)
                if client >= 0 {
                    POSIX.configure(client)
                    onAccept(client)
                } else if errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
        thread.name = "sketchintent.accept"
        thread.start()
    }
}
