import AVFoundation
import Combine
import Speech
import UIKit

/// The Cartesia key for Ink-2. It stays in Settings on this iPad and is not part of the stream.
enum CartesiaSettings {
    static let key = "cartesiaAPIKey"

    static var apiKey: String {
        (UserDefaults.standard.string(forKey: key) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A voice note anchored to one canvas point. Notes stay on the iPad, keyed by desktop space.
struct VoiceNote: Identifiable, Equatable {
    let id: UUID
    var anchor: CGPoint
    var text: String
}

enum VoiceCaptureBlock: Error {
    case microphone
    case missingKey
    case unavailable

    var message: String {
        switch self {
        case .microphone:
            return "Microphone access is off"
        case .missingKey:
            return "Add a Cartesia API key in Settings"
        case .unavailable:
            return "Voice notes aren't available"
        }
    }
}

enum VoiceNoteHit {
    case dot(UUID)
    case bubble
    case none
}

/// Asks for the microphone the first time the voice tool is used.
final class VoicePermissionGate {
    private var inFlight = false
    private var waiters: [(Result<Void, VoiceCaptureBlock>) -> Void] = []

    func promptIfUndetermined() {
        guard Self.decision() == nil, !inFlight else { return }
        authorize { _ in }
    }

    func authorize(_ completion: @escaping (Result<Void, VoiceCaptureBlock>) -> Void) {
        if let decision = Self.decision() {
            completion(decision)
            return
        }
        waiters.append(completion)
        guard !inFlight else { return }
        inFlight = true
        AVAudioApplication.requestRecordPermission { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                let result = Self.decision() ?? .failure(.unavailable)
                let pending = self.waiters
                self.waiters.removeAll()
                pending.forEach { $0(result) }
            }
        }
    }

    private static func decision() -> Result<Void, VoiceCaptureBlock>? {
        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            return .failure(.microphone)
        case .undetermined:
            return nil
        case .granted:
            return .success(())
        @unknown default:
            return .failure(.unavailable)
        }
    }
}

/// Streams the microphone to Cartesia Ink-2 and reports the live transcript.
/// Partial transcripts are delivered on the main queue. Start and stop from the main queue.
final class VoiceTranscriber {
    var onPartial: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    /// Replaced after the audio session is active. An engine created earlier keeps
    /// a stale hardware rate, and `installTap` terminates the app when they differ.
    private var engine = AVAudioEngine()
    private let sampleRate = 16_000
    private let chunkBytes = 3_200
    private var socket: URLSessionWebSocketTask?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var tapInstalled = false
    private var listening = false
    private var generation = 0
    private let lock = NSLock()
    private var pending = Data()
    private var finishedTurns: [String] = []
    private var activeTurn = ""
    private var latest = ""

    func start() throws {
        guard !CartesiaSettings.apiKey.isEmpty else {
            throw VoiceCaptureBlock.missingKey
        }
        generation += 1
        finishedTurns = []
        activeTurn = ""
        pending.removeAll()
        store("")
        tearDownEngine()
        listening = true
        do {
            try beginEngine()
            try openSocket()
        } catch let block as VoiceCaptureBlock {
            listening = false
            tearDownEngine()
            throw block
        } catch {
            listening = false
            tearDownEngine()
            throw VoiceCaptureBlock.unavailable
        }
    }

    func stop() -> String {
        let text = currentText()
        guard listening else { return text }
        listening = false
        generation += 1
        flushPending()
        socket?.send(.string("{\"type\":\"close\"}")) { _ in }
        tearDownEngine()
        return text
    }

    private func beginEngine() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        // A new engine picks up the active session. One created earlier keeps a
        // hardware rate that no longer matches, and installTap then terminates the app.
        engine = AVAudioEngine()
        var input = engine.inputNode
        let hardwareRate = input.inputFormat(forBus: 0).sampleRate
        if hardwareRate > 0, abs(hardwareRate - session.sampleRate) > 1 {
            try session.setPreferredSampleRate(hardwareRate)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            engine = AVAudioEngine()
            input = engine.inputNode
        }
        let format = try tapFormat(for: input)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: true
        ) else {
            throw VoiceCaptureBlock.unavailable
        }
        targetFormat = target
        converter = AVAudioConverter(from: format, to: target)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        tapInstalled = true
        try engine.start()
    }

    /// The tap format's sample rate has to be the hardware rate. Prefer the
    /// output format once it already matches; otherwise build one at the hardware rate.
    private func tapFormat(for input: AVAudioInputNode) throws -> AVAudioFormat {
        let hardware = input.inputFormat(forBus: 0)
        let output = input.outputFormat(forBus: 0)
        if output.sampleRate > 0, output.channelCount > 0,
           hardware.sampleRate == 0 || abs(hardware.sampleRate - output.sampleRate) < 1 {
            return output
        }
        let rate = hardware.sampleRate > 0 ? hardware.sampleRate : output.sampleRate
        let channels = hardware.channelCount > 0 ? hardware.channelCount : output.channelCount
        guard rate > 0, channels > 0,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: rate,
                channels: channels,
                interleaved: false
              ) else {
            throw VoiceCaptureBlock.unavailable
        }
        return format
    }

    private func openSocket() throws {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.cartesia.ai"
        components.path = "/stt/turns/websocket"
        components.queryItems = [
            URLQueryItem(name: "model", value: "ink-2"),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "cartesia_version", value: "2026-08-14")
        ]
        guard let url = components.url else {
            throw VoiceCaptureBlock.unavailable
        }
        var request = URLRequest(url: url)
        request.setValue(CartesiaSettings.apiKey, forHTTPHeaderField: "X-API-Key")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        receive(generation: generation)
    }

    private func receive(generation: Int) {
        socket?.receive { [weak self] result in
            guard let self, self.generation == generation, self.listening else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                self.receive(generation: generation)
            case .failure:
                DispatchQueue.main.async {
                    guard self.generation == generation, self.listening else { return }
                    if self.currentText().isEmpty {
                        self.fail(VoiceCaptureBlock.unavailable.message)
                    }
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let value):
            text = value
        case .data(let value):
            text = String(data: value, encoding: .utf8)
        @unknown default:
            text = nil
        }
        guard let text, let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "turn.update", "turn.eager_end", "turn.resume":
            if let transcript = json["transcript"] as? String {
                activeTurn = transcript
                publish()
            }
        case "turn.end":
            if let transcript = json["transcript"] as? String {
                commitTurn(transcript)
            }
            publish()
        case "error":
            let message = (json["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? VoiceCaptureBlock.unavailable.message
            DispatchQueue.main.async { [weak self] in
                self?.fail(message)
            }
        default:
            break
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard listening, let pcm = convert(buffer) else { return }
        lock.lock()
        pending.append(pcm)
        var chunks: [Data] = []
        while pending.count >= chunkBytes {
            chunks.append(pending.prefix(chunkBytes))
            pending.removeFirst(chunkBytes)
        }
        lock.unlock()
        for chunk in chunks {
            send(chunk)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let targetFormat else { return nil }
        if converter == nil || converter?.inputFormat.sampleRate != buffer.format.sampleRate {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var provided = false
        converter.convert(to: output, error: &error) { _, status in
            if provided {
                status.pointee = .noDataNow
                return nil
            }
            provided = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let samples = output.int16ChannelData else { return nil }
        let count = Int(output.frameLength) * MemoryLayout<Int16>.size
        guard count > 0 else { return nil }
        return Data(bytes: samples[0], count: count)
    }

    private func send(_ data: Data) {
        socket?.send(.data(data)) { _ in }
    }

    private func flushPending() {
        lock.lock()
        let rest = pending
        pending.removeAll()
        lock.unlock()
        if !rest.isEmpty {
            send(rest)
        }
    }

    private func commitTurn(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        activeTurn = ""
        guard !trimmed.isEmpty else { return }
        if finishedTurns.last == trimmed { return }
        finishedTurns.append(trimmed)
    }

    private func publish() {
        let text = displayedText()
        store(text)
        guard !text.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.listening else { return }
            self.onPartial?(text)
        }
    }

    private func displayedText() -> String {
        var parts = finishedTurns
        let trimmed = activeTurn.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, parts.last != trimmed {
            parts.append(trimmed)
        }
        return parts.joined(separator: " ")
    }

    private func fail(_ message: String) {
        listening = false
        generation += 1
        tearDownEngine()
        onFailure?(message)
    }

    private func store(_ text: String) {
        lock.lock()
        latest = text
        lock.unlock()
    }

    private func currentText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    private func tearDownEngine() {
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        converter = nil
        targetFormat = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Talks to the agent while the dictation button is held. The words go out when it is let go.
/// Start and end from the main queue.
final class AgentDictation: ObservableObject {
    /// The words heard so far, or nil when not listening.
    @Published private(set) var heard: String?

    private let permissions = VoicePermissionGate()
    private let transcriber = VoiceTranscriber()
    private var generation = 0
    private var recording = false

    /// Starts listening. `onFailure` gets the reason when the microphone or Cartesia can't be used.
    func begin(onFailure: @escaping (String) -> Void) {
        generation += 1
        let current = generation
        heard = ""
        permissions.authorize { [weak self] result in
            guard let self, self.generation == current else { return }
            switch result {
            case .failure(let reason):
                self.fail(reason.message, onFailure)
            case .success:
                self.startRecording(generation: current, onFailure: onFailure)
            }
        }
    }

    /// Stops listening and returns what was said. Empty when nothing was heard.
    func end() -> String {
        generation += 1
        heard = nil
        transcriber.onPartial = nil
        transcriber.onFailure = nil
        guard recording else { return "" }
        recording = false
        return transcriber.stop().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startRecording(generation current: Int, onFailure: @escaping (String) -> Void) {
        transcriber.onPartial = { [weak self] text in
            guard let self, self.generation == current else { return }
            self.heard = text
        }
        transcriber.onFailure = { [weak self] message in
            guard let self, self.generation == current else { return }
            self.recording = false
            self.fail(message, onFailure)
        }
        do {
            try transcriber.start()
            recording = true
        } catch let reason as VoiceCaptureBlock {
            fail(reason.message, onFailure)
        } catch {
            fail(VoiceCaptureBlock.unavailable.message, onFailure)
        }
    }

    private func fail(_ message: String, _ onFailure: (String) -> Void) {
        generation += 1
        heard = nil
        transcriber.onPartial = nil
        transcriber.onFailure = nil
        onFailure(message)
    }
}

/// Dots and the transcription bubble. The view does not take touches; the canvas tap asks it what was hit.
final class VoiceNoteLayer: UIView {
    private var notes: [VoiceNote] = []
    private var openID: UUID?
    private var liveAnchor: CGPoint?
    private var liveText = ""
    private var noticeAnchor: CGPoint?
    private var noticeText = ""
    private var dotViews: [UUID: UIView] = [:]
    private var transcripts: [UUID: TranscriptBubble] = [:]
    private let liveDot = UIView()
    private var pulsing = false

    private let bubbleHost = UIView()
    private let bubble = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let icon = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false

        liveDot.isHidden = true
        liveDot.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        liveDot.layer.cornerRadius = 6
        liveDot.backgroundColor = .systemBlue
        liveDot.layer.borderWidth = 1
        liveDot.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        addSubview(liveDot)

        bubbleHost.isHidden = true
        bubbleHost.layer.shadowColor = UIColor.black.cgColor
        bubbleHost.layer.shadowOpacity = 0.28
        bubbleHost.layer.shadowRadius = 16
        bubbleHost.layer.shadowOffset = CGSize(width: 0, height: 8)
        bubble.clipsToBounds = true
        bubble.layer.cornerCurve = .continuous
        bubble.layer.cornerRadius = 18
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.numberOfLines = 0
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .white
        bubble.contentView.addSubview(icon)
        bubble.contentView.addSubview(label)
        bubbleHost.addSubview(bubble)
        addSubview(bubbleHost)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSaved(notes: [VoiceNote], openID: UUID?) {
        self.notes = notes
        self.openID = openID
        render()
    }

    func setLive(anchor: CGPoint?, text: String) {
        liveAnchor = anchor
        liveText = text
        if anchor != nil {
            noticeAnchor = nil
            noticeText = ""
        }
        render()
    }

    func setNotice(anchor: CGPoint?, text: String) {
        noticeAnchor = anchor
        noticeText = text
        render()
    }

    func relayout() {
        render()
    }

    func hit(at point: CGPoint) -> VoiceNoteHit {
        if !bubbleHost.isHidden, bubbleHost.frame.contains(point) {
            return .bubble
        }
        if transcripts.values.contains(where: { !$0.isHidden && $0.frame.contains(point) }) {
            return .bubble
        }
        if let id = noteID(at: point) {
            return .dot(id)
        }
        return .none
    }

    /// Saved note for this space whose 44pt target contains the point.
    /// The open bubble is not a dot. A pen tap or hold resolves the dot here.
    func noteID(at point: CGPoint) -> UUID? {
        let hits = notes.filter { Self.targetRect(around: $0.anchor).contains(point) }
        return hits.min(by: { lhs, rhs in
            Self.distance(lhs.anchor, point) < Self.distance(rhs.anchor, point)
        })?.id
    }

    private func render() {
        syncDots()
        syncTranscripts()
        syncLiveDot()
        if let liveAnchor {
            showBubble(
                text: liveText,
                symbol: "mic",
                near: liveAnchor,
                placeholder: "Listening…"
            )
        } else if let noticeAnchor, !noticeText.isEmpty {
            showBubble(
                text: noticeText,
                symbol: "mic.slash",
                near: noticeAnchor,
                placeholder: nil
            )
        } else {
            bubbleHost.isHidden = true
        }
        for bubble in transcripts.values {
            bringSubviewToFront(bubble)
        }
        bringSubviewToFront(liveDot)
        bringSubviewToFront(bubbleHost)
    }

    /// Every saved note keeps its transcript visible. A tap does not hide it.
    private func syncTranscripts() {
        let ids = Set(notes.map(\.id))
        for (id, bubble) in transcripts where !ids.contains(id) {
            bubble.removeFromSuperview()
            transcripts.removeValue(forKey: id)
        }
        for note in notes {
            let bubble: TranscriptBubble
            if let existing = transcripts[note.id] {
                bubble = existing
            } else {
                bubble = TranscriptBubble()
                transcripts[note.id] = bubble
                insertSubview(bubble, belowSubview: bubbleHost)
            }
            layout(bubble, text: note.text, symbol: "mic", near: note.anchor)
        }
    }

    private func syncDots() {
        let ids = Set(notes.map(\.id))
        for (id, view) in dotViews where !ids.contains(id) {
            view.removeFromSuperview()
            dotViews.removeValue(forKey: id)
        }
        for note in notes {
            let dot: UIView
            let created = dotViews[note.id] == nil
            if let existing = dotViews[note.id] {
                dot = existing
            } else {
                dot = Self.makeDot()
                dotViews[note.id] = dot
                insertSubview(dot, belowSubview: bubbleHost)
            }
            dot.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
            dot.center = note.anchor
            if created {
                dot.alpha = 0
                UIView.animate(withDuration: 0.16, delay: 0, options: [.allowUserInteraction]) {
                    dot.alpha = 1
                }
            }
        }
    }

    private func syncLiveDot() {
        guard let liveAnchor else {
            if pulsing {
                liveDot.layer.removeAllAnimations()
                pulsing = false
            }
            liveDot.alpha = 1
            liveDot.isHidden = true
            return
        }
        liveDot.isHidden = false
        liveDot.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        liveDot.center = liveAnchor
        guard !pulsing else { return }
        pulsing = true
        liveDot.alpha = 1
        UIView.animate(
            withDuration: 0.7,
            delay: 0,
            options: [.repeat, .autoreverse, .allowUserInteraction, .curveEaseInOut]
        ) {
            self.liveDot.alpha = 0.4
        }
    }

    private func showBubble(text: String, symbol: String, near anchor: CGPoint, placeholder: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaceholder = trimmed.isEmpty
        let shown = Self.tail(isPlaceholder ? (placeholder ?? "") : trimmed)
        label.text = shown
        label.textColor = isPlaceholder ? UIColor.white.withAlphaComponent(0.72) : .white
        icon.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium, scale: .medium)
        )

        let maxTextWidth = min(240, max(120, bounds.width - 88))
        let textSize = label.sizeThatFits(CGSize(width: maxTextWidth, height: 220))
        let textWidth = min(maxTextWidth, ceil(textSize.width))
        let textHeight = min(220, ceil(textSize.height))
        let width = textWidth + 54
        let height = max(textHeight + 24, 46)
        label.frame = CGRect(x: 42, y: (height - textHeight) / 2, width: textWidth, height: textHeight)
        icon.frame = CGRect(x: 12, y: (height - 22) / 2, width: 22, height: 22)

        bubbleHost.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        bubble.frame = bubbleHost.bounds
        bubbleHost.center = bubbleOrigin(size: CGSize(width: width, height: height), near: anchor)
        bubbleHost.isHidden = shown.isEmpty
    }

    /// Keeps the bubble on screen and off the pencil point. Above the point when there is room.
    private func bubbleOrigin(size: CGSize, near anchor: CGPoint) -> CGPoint {
        let margin: CGFloat = 12
        let gap: CGFloat = 18
        let safe = safeAreaInsets
        let minX = margin + safe.left
        let maxX = bounds.width - margin - safe.right
        let minY = margin + safe.top
        let maxY = bounds.height - margin - safe.bottom

        var x = anchor.x
        var y = anchor.y - gap - size.height / 2
        if y - size.height / 2 < minY {
            y = anchor.y + gap + size.height / 2
        }
        let halfW = size.width / 2
        let halfH = size.height / 2
        if maxX - minX > size.width {
            x = min(max(x, minX + halfW), maxX - halfW)
        } else {
            x = bounds.midX
        }
        if maxY - minY > size.height {
            y = min(max(y, minY + halfH), maxY - halfH)
        } else {
            y = bounds.midY
        }
        return CGPoint(x: x, y: y)
    }

    private func layout(_ bubble: TranscriptBubble, text: String, symbol: String, near anchor: CGPoint) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = Self.tail(trimmed)
        bubble.label.text = shown
        bubble.label.textColor = .white
        bubble.icon.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium, scale: .medium)
        )
        let maxTextWidth = min(240, max(120, bounds.width - 88))
        let textSize = bubble.label.sizeThatFits(CGSize(width: maxTextWidth, height: 220))
        let textWidth = min(maxTextWidth, ceil(textSize.width))
        let textHeight = min(220, ceil(textSize.height))
        let width = textWidth + 54
        let height = max(textHeight + 24, 46)
        bubble.label.frame = CGRect(x: 42, y: (height - textHeight) / 2, width: textWidth, height: textHeight)
        bubble.icon.frame = CGRect(x: 12, y: (height - 22) / 2, width: 22, height: 22)
        bubble.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        bubble.material.frame = bubble.bounds
        bubble.center = bubbleOrigin(size: CGSize(width: width, height: height), near: anchor)
        bubble.isHidden = shown.isEmpty
    }

    private static func makeDot() -> UIView {
        let dot = UIView()
        dot.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        dot.layer.cornerRadius = 6
        dot.backgroundColor = .white
        dot.layer.borderWidth = 1
        dot.layer.borderColor = UIColor.black.withAlphaComponent(0.4).cgColor
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.35
        dot.layer.shadowRadius = 2
        dot.layer.shadowOffset = .zero
        dot.isUserInteractionEnabled = false
        return dot
    }

    /// Visual dots stay small. The tappable area is a 44pt square.
    private static func targetRect(around anchor: CGPoint) -> CGRect {
        CGRect(x: anchor.x - 22, y: anchor.y - 22, width: 44, height: 44)
    }

    private static func distance(_ anchor: CGPoint, _ point: CGPoint) -> CGFloat {
        hypot(anchor.x - point.x, anchor.y - point.y)
    }

    /// Live speech grows at the end. Keep the newest words when a note gets long.
    private static func tail(_ text: String) -> String {
        let limit = 280
        guard text.count > limit else { return text }
        return "…" + text.suffix(limit)
    }
}

/// One saved transcript. These stay on screen; tapping the page does not dismiss them.
private final class TranscriptBubble: UIView {
    let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    let icon = UIImageView()
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 8)
        material.clipsToBounds = true
        material.layer.cornerCurve = .continuous
        material.layer.cornerRadius = 18
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.numberOfLines = 0
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .white
        material.contentView.addSubview(icon)
        material.contentView.addSubview(label)
        addSubview(material)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
