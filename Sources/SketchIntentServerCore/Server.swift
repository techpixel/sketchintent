import Foundation
import StreamProtocol

public final class Server {
    private let config: ServerConfig
    private let hub: FrameHub
    private let capturer: ScreenCapturer
    private let listener = TCPListener()
    private let advertiser = ServiceAdvertiser()
    private var usb: USBWatcher?

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

        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [hub] _ in
            guard let id = DesktopSwitcher.currentLayout()?.spaceID else { return }
            hub.updateSpace(id)
        }

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [hub] _ in
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
}
