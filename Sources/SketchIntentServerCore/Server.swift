import Foundation
import StreamProtocol

public final class Server {
    private let config: ServerConfig
    private let hub: FrameHub
    private let capturer: ScreenCapturer
    private let listener = TCPListener()
    private let advertiser = ServiceAdvertiser()
    private var usb: USBWatcher?
    /// Dispatch sources, not run-loop timers. `main.swift` parks the process with
    /// `dispatchMain()`, which does not fire `Timer`.
    private var mainQueueTimers: [DispatchSourceTimer] = []

    public init(config: ServerConfig) {
        self.config = config
        let host = Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName
        hub = FrameHub(hostName: host.hasSuffix(".local") ? String(host.dropLast(".local".count)) : host)
        capturer = ScreenCapturer(fps: config.fps)
    }

    public func run() throws {
        signal(SIGPIPE, SIG_IGN)
        try ScreenCapturer.ensureAccess()
        let hostName = Host.current().localizedName ?? "This Mac"
        let megabits = config.bitrate / 1_000_000
        print("""
        [sketchintent] \(hostName) is streaming.
          USB    device port \(config.usbPort) through usbmuxd
          TCP    0.0.0.0:\(config.tcpPort)
          Video  H.264 \(config.fps) fps, \(megabits) Mbps, max width \(config.maxWidth)
        """)

        hub.onNeedsKeyframe = { [capturer] in
            capturer.requestKeyframe()
        }
        capturer.onVideo = { [hub] config, frame in
            hub.broadcast(config: config, frame: frame)
        }
        capturer.onSize = { [hub] width, height in
            hub.updateDisplay(width: width, height: height)
            print("[sketchintent] Display \(width)×\(height).")
        }

        if let id = DesktopSwitcher.currentLayout()?.spaceID {
            hub.updateSpace(id)
        }

        try listener.start(port: config.tcpPort) { [hub] fd in
            Server.attach(fd: fd, label: "tcp", hub: hub)
        }

        let watcher = USBWatcher(port: config.usbPort)
        usb = watcher
        watcher.onSession = { [hub] fd, label, onDisconnect in
            Server.attach(fd: fd, label: label, hub: hub, onDisconnect: onDisconnect)
        }
        watcher.start()
        advertiser.start(name: hostName, port: Int(config.tcpPort))

        scheduleOnMainQueue(every: 0.2) { [hub] in
            guard let id = DesktopSwitcher.currentLayout()?.spaceID else { return }
            hub.updateSpace(id)
        }

        scheduleOnMainQueue(every: 2) { [hub] in
            let stats = hub.takeStats()
            guard stats.frames > 0 || stats.clients > 0 else { return }
            let fps = stats.frames / 2
            let kilobytes = stats.bytes / 2 / 1024
            print("[sketchintent] \(stats.clients) client(s), \(fps) fps, \(kilobytes) KB/s")
        }

        Task {
            do {
                _ = try await self.capturer.start(
                    bitrate: self.config.bitrate,
                    maxWidth: self.config.maxWidth,
                    displayIndex: self.config.displayIndex
                )
            } catch {
                fputs("[sketchintent] \(error)\n", stderr)
                exit(1)
            }
        }
    }

    private static func attach(fd: Int32, label: String, hub: FrameHub, onDisconnect: (() -> Void)? = nil) {
        let session = StreamSession(fd: fd, label: label)
        print("[sketchintent] Client connected (\(label)).")
        session.onStop = {
            print("[sketchintent] Client disconnected (\(label)).")
            onDisconnect?()
        }
        session.onInput = { input in
            switch input {
            case .switchDesktop(let direction):
                DesktopSwitcher.switchDesktop(direction)
            }
        }
        hub.add(session)
        session.start()
    }

    /// Repeating work on the main queue. The source is retained so it is not cancelled.
    private func scheduleOnMainQueue(every seconds: TimeInterval, _ handler: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = DispatchTimeInterval.milliseconds(Int((seconds * 1000).rounded()))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(40))
        timer.setEventHandler(handler: handler)
        mainQueueTimers.append(timer)
        timer.resume()
    }
}
