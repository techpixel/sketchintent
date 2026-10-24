import Foundation
import StreamProtocol

/// Fans encoded video out to every connected iPad, in decode order.
final class FrameHub {
    var onNeedsKeyframe: (() -> Void)?

    private let lock = NSLock()
    private var sessions: [UUID: StreamSession] = [:]
    private var hello: StreamHello
    private var lastConfig: VideoConfig?
    private var frames = 0
    private var bytes = 0

    init(hostName: String) {
        hello = StreamHello(name: hostName, width: 0, height: 0)
    }

    func add(_ session: StreamSession) {
        let id = session.id
        let previousStop = session.onStop
        session.onStop = { [weak self] in
            previousStop?()
            self?.detach(id)
        }
        session.onBehind = { [weak self] in
            self?.onNeedsKeyframe?()
        }
        lock.lock()
        sessions[id] = session
        let hello = self.hello
        let config = lastConfig
        lock.unlock()
        if hello.width > 0 && hello.height > 0 {
            session.offerHello(hello)
        }
        if let config {
            session.offer(StreamFraming.encode(.videoConfig(config)), kind: .control)
        }
        onNeedsKeyframe?()
    }

    private func detach(_ id: UUID) {
        lock.lock()
        sessions.removeValue(forKey: id)
        lock.unlock()
    }

    func updateDisplay(width: Int, height: Int) {
        lock.lock()
        hello.width = width
        hello.height = height
        let hello = self.hello
        let current = Array(sessions.values)
        lock.unlock()
        for session in current {
            session.offerHello(hello)
        }
    }

    func broadcast(config: VideoConfig?, frame: VideoFrame) {
        if let config {
            lock.lock()
            lastConfig = config
            lock.unlock()
        }
        lock.lock()
        frames += 1
        bytes += frame.data.count
        let current = Array(sessions.values)
        lock.unlock()

        let configPacket = config.map { StreamFraming.encode(.videoConfig($0)) }
        let framePacket = StreamFraming.encode(.videoFrame(frame))
        for session in current {
            if let configPacket {
                session.offer(configPacket, kind: .control)
            }
            session.offer(framePacket, kind: .frame(keyframe: frame.isKeyframe))
        }
    }

    func takeStats() -> (frames: Int, bytes: Int, clients: Int) {
        lock.lock()
        let snapshot = (frames, bytes, sessions.count)
        frames = 0
        bytes = 0
        lock.unlock()
        return snapshot
    }
}
