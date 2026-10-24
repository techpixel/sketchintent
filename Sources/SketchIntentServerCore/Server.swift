import Foundation
import StreamProtocol

public final class Server {
    private let config: ServerConfig
    private let hub: FrameHub
    private let capturer: ScreenCapturer
    private let pointer: MacPointer
    private let ink = InkOverlay()
    private let listener = TCPListener()
    private let advertiser = ServiceAdvertiser()
    private var usb: USBWatcher?
    /// Dispatch sources, not run-loop timers. `main.swift` parks on `NSApplication.run()`,
    /// which services this queue. `Timer` is not used.
    private var mainQueueTimers: [DispatchSourceTimer] = []

    public init(config: ServerConfig) {
        self.config = config
        let host = Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName
        hub = FrameHub(hostName: host.hasSuffix(".local") ? String(host.dropLast(".local".count)) : host)
        capturer = ScreenCapturer(fps: config.fps)
        pointer = MacPointer(displayIndex: config.displayIndex)
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
        capturer.onDisplay = { [pointer, ink, capturer] id in
            pointer.noteDisplay(id)
            ink.place(on: id) { windowID, completion in
                capturer.excludeOverlayWindow(windowID, completion: completion)
            }
        }
        capturer.onSize = { [hub, pointer] width, height in
            hub.updateDisplay(width: width, height: height)
            pointer.noteFrame(width: width, height: height)
            print("[sketchintent] Display \(width)×\(height).")
        }

        if let id = DesktopSwitcher.currentLayout()?.spaceID, hub.updateSpace(id) {
            ink.noteSpace(id)
        }

        try listener.start(port: config.tcpPort) { [hub, pointer, ink] fd in
            Server.attach(fd: fd, label: "tcp", hub: hub, pointer: pointer, ink: ink)
        }

        let watcher = USBWatcher(port: config.usbPort)
        usb = watcher
        watcher.onSession = { [hub, pointer, ink] fd, label, onDisconnect in
            Server.attach(fd: fd, label: label, hub: hub, pointer: pointer, ink: ink, onDisconnect: onDisconnect)
        }
        watcher.start()
        advertiser.start(name: hostName, port: Int(config.tcpPort))

        scheduleOnMainQueue(every: 0.2) { [hub, ink] in
            guard let id = DesktopSwitcher.currentLayout()?.spaceID else { return }
            if hub.updateSpace(id) {
                ink.noteSpace(id)
            }
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

    private static func attach(
        fd: Int32,
        label: String,
        hub: FrameHub,
        pointer: MacPointer,
        ink: InkOverlay,
        onDisconnect: (() -> Void)? = nil
    ) {
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
            case .pointer(let phase, let x, let y, let contact):
                pointer.post(phase: phase, x: x, y: y, contact: contact)
            case .trackpadScroll(let dx, let dy, let phase):
                pointer.postTrackpadScroll(dx: dx, dy: dy, phase: phase)
            case .trackpadClick(let button, let phase):
                pointer.postTrackpadClick(button: button, phase: phase)
            }
        }
        session.onInk = { snapshot in
            ink.show(snapshot)
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
