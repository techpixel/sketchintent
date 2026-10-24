import Foundation
import StreamProtocol

enum OutboundKind {
    case control
    case frame(keyframe: Bool)
}

/// Writes encoded frames in order. A couple of frames may wait on the socket.
/// If more pile up, they are dropped and the next keyframe is requested immediately.
/// P-frames are never sent after a drop; that would corrupt the GOP.
final class StreamSession {
    let id = UUID()
    let label: String
    var onStop: (() -> Void)?
    var onBehind: (() -> Void)?
    var onInput: ((RemoteInput) -> Void)?
    var onInk: ((InkSnapshot) -> Void)?

    /// Steady state keeps one frame in flight and one waiting. A third means the link is behind.
    private let maxQueuedFrames = 2
    private let fd: Int32
    private let condition = NSCondition()
    private var queue: [(Data, OutboundKind)] = []
    private var waitForKeyframe = false
    private var running = true
    private var finished = false

    init(fd: Int32, label: String) {
        self.fd = fd
        self.label = label
    }

    func start() {
        let writer = Thread {
            self.run()
        }
        writer.name = "sketchintent.session"
        writer.start()
        let reader = Thread {
            self.readInbound()
        }
        reader.name = "sketchintent.input"
        reader.start()
    }

    func stop() {
        condition.lock()
        running = false
        condition.signal()
        condition.unlock()
        _ = Darwin.shutdown(fd, SHUT_RDWR)
    }

    func offerHello(_ hello: StreamHello) {
        offer(StreamFraming.encode(.hello(hello)), kind: .control)
    }

    func offer(_ packet: Data, kind: OutboundKind) {
        var fellBehind = false
        condition.lock()
        switch kind {
        case .control:
            queue.append((packet, kind))
        case .frame(let keyframe):
            if waitForKeyframe && !keyframe {
                condition.unlock()
                return
            }
            queue.append((packet, kind))
            if queuedFrameCount > maxQueuedFrames {
                queue.removeAll { item in
                    if case .frame = item.1 { return true }
                    return false
                }
                if keyframe {
                    queue.append((packet, kind))
                    waitForKeyframe = false
                } else {
                    waitForKeyframe = true
                    fellBehind = true
                }
            } else {
                waitForKeyframe = false
            }
        }
        condition.signal()
        condition.unlock()
        if fellBehind {
            onBehind?()
        }
    }

    private var queuedFrameCount: Int {
        queue.reduce(into: 0) { count, item in
            if case .frame = item.1 { count += 1 }
        }
    }

    private func run() {
        var nextHeartbeat = Date().addingTimeInterval(2)
        while true {
            condition.lock()
            while running && queue.isEmpty && Date() < nextHeartbeat {
                condition.wait(until: nextHeartbeat)
            }
            if !running {
                condition.unlock()
                break
            }
            let next = queue.isEmpty ? nil : queue.removeFirst()
            condition.unlock()

            if let next {
                if !POSIX.writeAll(fd, next.0) { break }
            } else if !POSIX.writeAll(fd, StreamFraming.encode(.heartbeat)) {
                break
            }
            nextHeartbeat = Date().addingTimeInterval(2)
        }
        finish()
    }

    /// Gestures travel iPad → Mac on the same socket the video uses in the other direction.
    private func readInbound() {
        let parser = StreamParser()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            do {
                let messages = try parser.append(Data(buffer.prefix(count)))
                for message in messages {
                    switch message {
                    case .input(let input):
                        onInput?(input)
                    case .ink(let ink):
                        onInk?(ink)
                    default:
                        break
                    }
                }
            } catch {
                fputs("[sketchintent] Closing \(label) after a bad packet: \(error)\n", stderr)
                break
            }
        }
        stop()
    }

    private func finish() {
        condition.lock()
        if finished {
            condition.unlock()
            return
        }
        finished = true
        condition.unlock()
        POSIX.close(fd)
        onStop?()
    }
}
