import Foundation
import StreamProtocol

/// Fans encoded video out to every connected iPad, in decode order.
final class FrameHub {
    var onNeedsKeyframe: (() -> Void)?

    private let lock = NSLock()
    private var sessions: [UUID: StreamSession] = [:]
    private var hello: StreamHello
    private var lastConfig: VideoConfig?
    private var lastSpaceID: String?
    private var lastDesktops: (index: Int, count: Int)?
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
        let spaceID = lastSpaceID
        let desktops = lastDesktops
        lock.unlock()
        if hello.width > 0 && hello.height > 0 {
            session.offerHello(hello)
        }
        if let config {
            session.offer(StreamFraming.encode(.videoConfig(config)), kind: .control)
        }
        if let spaceID {
            session.offer(StreamFraming.encode(.space(spaceID)), kind: .control)
        }
        if let desktops {
            session.offer(StreamFraming.encode(.desktops(index: desktops.index, count: desktops.count)), kind: .control)
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

    /// Tells every iPad which desktop is on screen. Repeated ids are not sent again.
    /// True when this id is new.
    @discardableResult
    func updateSpace(_ id: String) -> Bool {
        lock.lock()
        let changed = lastSpaceID != id
        if changed { lastSpaceID = id }
        let current = changed ? Array(sessions.values) : []
        lock.unlock()
        guard changed else { return false }
        let packet = StreamFraming.encode(.space(id))
        for session in current {
            session.offer(packet, kind: .control)
        }
        return true
    }

    /// Tells every iPad where the current desktop sits in Mission Control. Repeats are not sent.
    func updateDesktops(index: Int, count: Int) {
        lock.lock()
        let changed = lastDesktops?.index != index || lastDesktops?.count != count
        if changed { lastDesktops = (index, count) }
        let current = changed ? Array(sessions.values) : []
        lock.unlock()
        guard changed else { return }
        let packet = StreamFraming.encode(.desktops(index: index, count: count))
        for session in current {
            session.offer(packet, kind: .control)
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
