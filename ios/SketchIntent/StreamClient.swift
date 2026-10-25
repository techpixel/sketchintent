import CoreMedia
import Foundation
import Network
import UIKit

/// Receives the Mac's screen. USB is a listener the Mac dials through usbmuxd.
/// The simulator and a Mac on the same network connect the other way.
final class StreamClient: ObservableObject {
    @Published var hasFrame = false
    /// Captured frame size from the latest hello or video config. Pointer mapping uses this.
    @Published var frameWidth = 0
    @Published var frameHeight = 0
    /// Mission Control id of the desktop on screen. Sketches are stored under this.
    @Published var spaceID: String?
    /// Zero-based position of that desktop in Mission Control, or -1 when unknown.
    @Published private(set) var desktopIndex = -1
    /// Desktops on the streamed display. Zero until the Mac reports them.
    @Published private(set) var desktopCount = 0
    /// True once the socket to the Mac is ready. Blank canvas uses this before any picture arrives.
    @Published var isConnected = false
    /// Absolute path on the Mac where the agent works. Empty until one is chosen.
    @Published private(set) var workingFolder = UserDefaults.standard.string(forKey: StreamClient.folderKey) ?? ""
    /// True while the Mac folder panel is open.
    @Published private(set) var isChoosingFolder = false
    #if targetEnvironment(simulator)
    @Published var badge = "Looking for SketchIntent Server"
    #else
    @Published var badge = "Listening over USB"
    #endif

    private let queue = DispatchQueue(label: "sketchintent.client")
    private let parser = StreamParser()
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var connectionPriority = -1
    private var connectionWasReady = false
    private var bonjourEndpoint: NWEndpoint?
    private var didStart = false
    private var frameTimes: [Date] = []
    private var macName = "Mac"
    private var resolution = ""
    /// Frames decoded in the last second. Shown at the bottom left of the picture.
    @Published var framesPerSecond = 0
    private var isLive = false
    private var lastPacket = Date()
    private var timer: Timer?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private weak var display: SampleDisplayView?
    private let stateLock = NSLock()
    private var latestInk: Data?
    private var lastSentInk: Data?
    private var inkSending = false
    private var inkGeneration = 0
    private var pendingSamples: [CMSampleBuffer] = []
    private var pendingParameterFlush = false
    private var pendingReceivedAt = Date()
    private var displayScheduled = false

    func start() {
        guard !didStart else { return }
        didStart = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshLiveness()
        }
        queue.async { [weak self] in
            self?.startListener()
            self?.startBrowser()
            self?.connectFallback()
            self?.scheduleRetry()
        }
    }

    func attachDisplay(_ view: SampleDisplayView) {
        display = view
    }

    /// The Mac picture on screen right now, for a sketch that should stay on that frame.
    func captureDisplayedFrame() -> (image: UIImage, width: Int, height: Int)? {
        display?.capturedFrame()
    }

    func send(_ input: RemoteInput) {
        let packet = StreamFraming.encode(.input(input))
        queue.async { [weak self] in
            guard let self, let connection = self.connection, self.connectionWasReady else { return }
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    /// The sketch travels on the socket the Mac already opened, USB included.
    /// False when that socket is down or the packet would exceed the frame limit.
    func sendIntent(_ request: IntentRequest) -> Bool {
        let packet = StreamFraming.encode(.intent(request))
        guard packet.count <= 4 + StreamFraming.maxPayloadLength else { return false }
        var sent = false
        queue.sync {
            guard connectionWasReady, let connection else { return }
            sent = true
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
        return sent
    }

    var onIntentReply: ((IntentReply) -> Void)?

    /// Asks the Mac to stop the agent working on `id`.
    func cancelIntent(_ id: UInt32) {
        let packet = StreamFraming.encode(.cancelIntent(id))
        queue.async { [weak self] in
            guard let self, let connection = self.connection, self.connectionWasReady else { return }
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    private static let folderKey = "agentWorkingFolder"

    /// Asks the Mac to open a folder panel. The current folder, if any, is where the panel starts.
    func requestWorkingFolder() {
        guard isConnected, !isChoosingFolder else { return }
        isChoosingFolder = true
        let packet = StreamFraming.encode(.chooseFolder(workingFolder))
        queue.async { [weak self] in
            guard let self, let connection = self.connection, self.connectionWasReady else {
                DispatchQueue.main.async { self?.isChoosingFolder = false }
                return
            }
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    func clearWorkingFolder() {
        workingFolder = ""
        UserDefaults.standard.removeObject(forKey: Self.folderKey)
    }

    /// Latest pen-ink PNG for the active desktop. An empty PNG clears the Mac overlay.
    /// Only one ink packet is in flight; a newer drawing replaces one that has not been sent.
    func sendInk(png: Data, width: Int, height: Int, spaceID: String) {
        let snapshot = InkSnapshot(width: width, height: height, spaceID: spaceID, png: png)
        let packet = StreamFraming.encode(.ink(snapshot))
        guard packet.count <= 4 + StreamFraming.maxPayloadLength else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.latestInk = packet
            self.flushInk()
        }
    }

    /// Called on `queue`. Keeps the newest ink and does not queue a stack of PNGs behind the video.
    private func flushInk() {
        guard !inkSending, connectionWasReady, let connection, let latestInk, latestInk != lastSentInk else { return }
        inkSending = true
        let packet = latestInk
        let generation = inkGeneration
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                guard let self, self.inkGeneration == generation else { return }
                self.inkSending = false
                if error == nil {
                    self.lastSentInk = packet
                }
                self.flushInk()
            }
        })
    }

    private func startListener() {
        guard let port = NWEndpoint.Port(rawValue: SketchIntentPorts.usb) else { return }
        do {
            let listener = try NWListener(using: tcpParameters(), on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.adopt(connection, priority: 2, label: "USB")
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.setBadge("USB listen failed: \(error.localizedDescription)")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            setBadge("Could not listen for USB: \(error.localizedDescription)")
        }
    }

    private func startBrowser() {
        let browser = NWBrowser(
            for: .bonjour(type: SketchIntentPorts.bonjourType, domain: nil),
            using: tcpParameters()
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, let endpoint = results.first?.endpoint else { return }
            self.bonjourEndpoint = endpoint
            self.adopt(
                NWConnection(to: endpoint, using: self.tcpParameters()),
                priority: 1,
                label: "Network"
            )
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.setBadge("Network search failed: \(error.localizedDescription)")
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func scheduleRetry() {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if self.connection == nil {
                self.connectFallback()
            }
            self.scheduleRetry()
        }
    }

    private func connectFallback() {
        #if targetEnvironment(simulator)
        if let port = NWEndpoint.Port(rawValue: SketchIntentPorts.tcp) {
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: port)
            adopt(NWConnection(to: endpoint, using: tcpParameters()), priority: 1, label: "Simulator")
        }
        #endif
        if let bonjourEndpoint {
            adopt(NWConnection(to: bonjourEndpoint, using: tcpParameters()), priority: 1, label: "Network")
        }
    }

    private func adopt(_ connection: NWConnection, priority: Int, label: String) {
        if self.connection != nil && priority <= connectionPriority {
            connection.cancel()
            return
        }
        self.connection?.cancel()
        parser.reset()
        format = nil
        parameterSets = []
        connectionWasReady = false
        inkGeneration += 1
        inkSending = false
        lastSentInk = nil
        self.connection = connection
        connectionPriority = priority
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state, on: connection, label: label)
        }
        connection.start(queue: queue)
        receive(connection)
    }

    private func handle(_ state: NWConnection.State, on connection: NWConnection, label: String) {
        switch state {
        case .ready:
            connectionWasReady = true
            lastSentInk = nil
            flushInk()
            setConnected(true)
            setBadge("Connected over \(label)")
        case .failed(let error):
            let message = connectionWasReady ? "\(label) failed: \(error.localizedDescription)" : nil
            drop(connection, badge: message)
        case .cancelled:
            drop(connection, badge: nil)
        default:
            break
        }
    }

    private func drop(_ connection: NWConnection, badge: String?) {
        guard self.connection === connection else { return }
        self.connection = nil
        connectionPriority = -1
        parser.reset()
        format = nil
        if let badge {
            setBadge(badge)
        }
        DispatchQueue.main.async {
            self.isConnected = false
            self.isChoosingFolder = false
            self.desktopIndex = -1
            self.desktopCount = 0
            self.isLive = false
            self.updateBadge()
        }
    }

    private func applyWorkingFolder(_ path: String) {
        isChoosingFolder = false
        guard path.hasPrefix("/") else { return }
        workingFolder = path
        UserDefaults.standard.set(path, forKey: Self.folderKey)
    }

    private func setConnected(_ connected: Bool) {
        DispatchQueue.main.async {
            if self.isConnected != connected {
                self.isConnected = connected
            }
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.connection === connection else { return }
            if let data, !data.isEmpty {
                self.consume(data, from: connection)
            }
            if isComplete || error != nil {
                self.drop(connection, badge: self.connectionWasReady ? "Connection closed" : nil)
                return
            }
            self.receive(connection)
        }
    }

    private func consume(_ data: Data, from connection: NWConnection) {
        let messages: [StreamMessage]
        do {
            messages = try parser.append(data)
        } catch {
            connection.cancel()
            return
        }
        guard !messages.isEmpty else { return }

        var samples: [CMSampleBuffer] = []
        var flushDisplay = false
        var announcedSpace: String?
        for message in messages {
            switch message {
            case .hello(let hello):
                noteHello(hello)
            case .videoConfig(let config):
                if config.parameterSets != parameterSets {
                    parameterSets = config.parameterSets
                    format = H264Display.formatDescription(from: config)
                    flushDisplay = true
                }
                noteSize(width: config.width, height: config.height)
            case .videoFrame(let frame):
                guard let format, let sample = H264Display.sampleBuffer(from: frame, format: format) else { continue }
                samples.append(sample)
                noteFrame()
            case .space(let id):
                announcedSpace = id
            case .intentReply(let reply):
                let handler = onIntentReply
                DispatchQueue.main.async {
                    handler?(reply)
                }
            case .workingFolder(let path):
                DispatchQueue.main.async {
                    self.applyWorkingFolder(path)
                }
            case .desktops(let index, let count):
                DispatchQueue.main.async {
                    if self.desktopIndex != index { self.desktopIndex = index }
                    if self.desktopCount != count { self.desktopCount = count }
                }
            case .heartbeat, .input, .ink, .intent, .chooseFolder, .cancelIntent:
                break
            }
        }

        if let announcedSpace {
            DispatchQueue.main.async {
                if self.spaceID != announcedSpace {
                    self.spaceID = announcedSpace
                }
            }
        }
        scheduleUI(samples: samples, parameterFlush: flushDisplay)
    }

    /// One main-queue pass per burst. Per-frame hops were letting the badge redraw
    /// ahead of the picture and letting old frames enqueue before newer ones.
    private func scheduleUI(samples: [CMSampleBuffer], parameterFlush: Bool) {
        stateLock.lock()
        if parameterFlush {
            pendingParameterFlush = true
        }
        pendingSamples.append(contentsOf: samples)
        pendingReceivedAt = Date()
        let schedule = !displayScheduled
        displayScheduled = true
        stateLock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.drainDisplay()
        }
    }

    private func drainDisplay() {
        stateLock.lock()
        let samples = pendingSamples
        let parameterFlush = pendingParameterFlush
        let receivedAt = pendingReceivedAt
        pendingSamples = []
        pendingParameterFlush = false
        displayScheduled = false
        stateLock.unlock()

        lastPacket = receivedAt
        let wasLive = isLive
        isLive = true
        let showed = display?.present(samples, parameterSetsChanged: parameterFlush) ?? false
        let hadFrame = hasFrame
        if showed && !hasFrame {
            hasFrame = true
        }
        if !wasLive || hadFrame != hasFrame {
            framesPerSecond = capturedFrameRate()
            updateBadge()
        }
    }

    private func noteHello(_ hello: StreamHello) {
        noteSize(width: hello.width, height: hello.height)
        let name = hello.name
        DispatchQueue.main.async {
            self.macName = name
            self.isLive = true
            self.updateBadge()
        }
    }

    private func noteSize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let size = "\(width)×\(height)"
        DispatchQueue.main.async {
            self.frameWidth = width
            self.frameHeight = height
            self.resolution = size
            self.updateBadge()
        }
    }

    private func noteFrame() {
        let now = Date()
        stateLock.lock()
        frameTimes.append(now)
        frameTimes.removeAll { now.timeIntervalSince($0) > 1 }
        stateLock.unlock()
    }

    private func capturedFrameRate() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        let now = Date()
        frameTimes.removeAll { now.timeIntervalSince($0) > 1 }
        return frameTimes.count
    }

    private func refreshLiveness() {
        let fps = capturedFrameRate()
        if fps != framesPerSecond {
            framesPerSecond = fps
            updateBadge()
        }
        guard hasFrame else { return }
        if Date().timeIntervalSince(lastPacket) > 5 {
            isLive = false
            updateBadge()
        }
    }

    private func setBadge(_ text: String) {
        DispatchQueue.main.async {
            if !self.hasFrame {
                self.badge = text
            }
        }
    }

    private func updateBadge() {
        let next: String
        if hasFrame && !isLive {
            next = "Reconnecting"
        } else if isLive {
            let size = resolution.isEmpty ? macName : "\(macName) · \(resolution)"
            next = size
        } else {
            return
        }
        if badge != next {
            badge = next
        }
    }

    private func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        return parameters
    }
}
