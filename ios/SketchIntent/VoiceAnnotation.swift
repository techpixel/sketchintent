import AVFoundation
import Speech
import UIKit

/// A voice note anchored to one canvas point. Notes stay on the iPad, keyed by desktop space.
struct VoiceNote: Identifiable, Equatable {
    let id: UUID
    var anchor: CGPoint
    var text: String
}

enum VoiceCaptureBlock: Error {
    case microphone
    case speech
    case unavailable

    var message: String {
        switch self {
        case .microphone:
            return "Microphone access is off"
        case .speech:
            return "Speech recognition is off"
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

/// Asks for the microphone and speech recognition the first time the voice tool is used.
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
            SFSpeechRecognizer.requestAuthorization { _ in
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
    }

    private static func decision() -> Result<Void, VoiceCaptureBlock>? {
        let mic = AVAudioApplication.shared.recordPermission
        let speech = SFSpeechRecognizer.authorizationStatus()
        if mic == .denied {
            return .failure(.microphone)
        }
        if speech == .denied || speech == .restricted {
            return .failure(.speech)
        }
        if mic == .undetermined || speech == .notDetermined {
            return nil
        }
        if mic == .granted, speech == .authorized {
            return .success(())
        }
        return .failure(.unavailable)
    }
}

/// On-device speech when the recognizer supports it, otherwise the system recognizer.
/// Partial transcripts are delivered on the main queue. Start and stop from the main queue.
final class VoiceTranscriber {
    var onPartial: ((String) -> Void)?
    var onFailure: (() -> Void)?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var listening = false
    private var didFallBack = false
    private var generation = 0
    private let lock = NSLock()
    private var latest = ""

    func start() throws {
        listening = false
        generation += 1
        didFallBack = false
        store("")
        tearDownEngine()
        do {
            try beginEngine(onDevice: recognizer?.supportsOnDeviceRecognition == true)
            listening = true
        } catch {
            tearDownEngine()
            throw VoiceCaptureBlock.unavailable
        }
    }

    func stop() -> String {
        let text = currentText()
        guard listening else { return text }
        listening = false
        generation += 1
        tearDownEngine()
        return text
    }

    private func beginEngine(onDevice: Bool) throws {
        guard let recognizer, recognizer.isAvailable else {
            throw VoiceCaptureBlock.unavailable
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if onDevice {
            request.requiresOnDeviceRecognition = true
        }
        lock.lock()
        self.request = request
        lock.unlock()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceCaptureBlock.unavailable
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        listen(onDevice: onDevice)
    }

    private func listen(onDevice: Bool) {
        guard let recognizer, let request else { return }
        let generation = self.generation
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let text = result?.bestTranscription.formattedString, !text.isEmpty, self.generation == generation {
                self.store(text)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation, self.listening else { return }
                    self.onPartial?(text)
                }
            }
            guard error != nil else { return }
            let empty = self.currentText().isEmpty
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation, self.listening else { return }
                if onDevice, empty, !self.didFallBack {
                    self.didFallBack = true
                    self.restart(onDevice: false)
                    return
                }
                if empty {
                    self.onFailure?()
                }
            }
        }
    }

    /// On-device recognition can fail when the locale asset is missing. One system retry, then surface the error.
    private func restart(onDevice: Bool) {
        listening = false
        generation += 1
        tearDownEngine()
        do {
            try beginEngine(onDevice: onDevice)
            listening = true
        } catch {
            listening = false
            tearDownEngine()
            onFailure?()
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.append(buffer)
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
        lock.lock()
        let activeRequest = request
        request = nil
        lock.unlock()
        activeRequest?.endAudio()
        task?.cancel()
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
        let hits = notes.filter { Self.targetRect(around: $0.anchor).contains(point) }
        guard let nearest = hits.min(by: { lhs, rhs in
            Self.distance(lhs.anchor, point) < Self.distance(rhs.anchor, point)
        }) else {
            return .none
        }
        return .dot(nearest.id)
    }

    private func render() {
        syncDots()
        syncLiveDot()
        if let liveAnchor {
            showBubble(
                text: liveText,
                symbol: "mic.fill",
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
        } else if let openID, let note = notes.first(where: { $0.id == openID }) {
            showBubble(
                text: note.text,
                symbol: "mic.fill",
                near: note.anchor,
                placeholder: nil
            )
        } else {
            bubbleHost.isHidden = true
        }
        bringSubviewToFront(liveDot)
        bringSubviewToFront(bubbleHost)
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
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
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
