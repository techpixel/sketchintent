import Foundation
import os

/// Tells speech from silence on the iPad, so silence never goes to Cartesia.
/// Each 20 ms frame's level is compared with a noise floor that follows the room.
struct SpeechDetector {
    enum Change {
        case began
        case ended
    }

    /// Speech is this far above the floor, and never quieter than `quietest`.
    static let margin: Float = 10
    static let quietest: Float = -58
    /// Loud frames in a row before speech begins. A Pencil tap on the glass is shorter.
    static let onsetFrames = 3
    /// Quiet frames in a row before speech ends. Short pauses between words stay in.
    static let hangoverFrames = 40
    /// Frames that only measure the room before anything counts as speech.
    static let warmupFrames = 15
    /// Below this a frame is digital silence, as the engine sends while it starts. It says
    /// nothing about the room.
    static let silence: Float = -100
    /// Speech dips between words and syllables within this many frames. A sound that never
    /// does is the room getting louder, such as a fan turning on.
    static let dipFrames = 75

    private(set) var speaking = false
    private(set) var floor: Float = -60
    private var heardFrames = 0
    private var loudRun = 0
    private var quietRun = 0
    /// A running level while speaking, to step over noise that was mistaken for speech.
    private var speechLevel: Float = -60
    /// The quietest frame of the last `dipFrames` while speaking.
    private var recent: [Float] = []

    var warmedUp: Bool { heardFrames >= Self.warmupFrames }

    mutating func feed(_ level: Float) -> Change? {
        guard level > Self.silence else { return nil }
        if !warmedUp {
            floor = heardFrames == 0 ? level : floor + (level - floor) / Float(heardFrames + 1)
            heardFrames += 1
            if warmedUp {
                floor = min(max(floor, -90), -25)
            }
            return nil
        }
        let loud = level > max(floor + Self.margin, Self.quietest)
        guard speaking else {
            // The floor drops quickly into a quieter room and rises slowly, so a word does not lift it.
            floor += (level - floor) * (level < floor ? 0.3 : 0.02)
            floor = min(max(floor, -90), -25)
            loudRun = loud ? loudRun + 1 : 0
            guard loudRun >= Self.onsetFrames else { return nil }
            speaking = true
            quietRun = 0
            speechLevel = level
            recent.removeAll()
            return .began
        }
        speechLevel += (level - speechLevel) * 0.05
        // The floor still follows the room while speaking. If even the quietest moment of the
        // last second and a half was loud, the room rose, so speech can end above the old floor.
        if level < floor {
            floor = max(level, -90)
        }
        recent.append(level)
        if recent.count > Self.dipFrames {
            recent.removeFirst(recent.count - Self.dipFrames)
            if let quietestRecent = recent.min(), quietestRecent > floor + Self.margin {
                floor = min(-25, quietestRecent - 3)
            }
        }
        let stillLoud = level > max(floor + Self.margin, Self.quietest)
        quietRun = stillLoud ? 0 : quietRun + 1
        guard quietRun >= Self.hangoverFrames else { return nil }
        endSpeech()
        return .ended
    }

    /// What sounded like speech was steady noise, such as a fan or music. Lift the floor above it.
    mutating func ignoreCurrentLevel() {
        floor = min(-25, max(floor, speechLevel - Self.margin + 4))
        endSpeech()
    }

    /// Stops counting the current sound as speech without moving the floor. Speech that goes on
    /// begins again after `onsetFrames`.
    mutating func endSpeech() {
        speaking = false
        loudRun = 0
        quietRun = 0
        recent.removeAll()
    }

    /// Loudness of 16-bit PCM in dB below full scale.
    static func level(of frame: Data) -> Float {
        frame.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return -120 }
            var sum: Float = 0
            for sample in samples {
                let value = Float(sample) / 32_768
                sum += value * value
            }
            let rms = (sum / Float(samples.count)).squareRoot()
            return 20 * log10(max(rms, 1e-6))
        }
    }
}

/// Keeps the microphone open in live mode, but only speech reaches Cartesia.
/// The microphone runs on the iPad without a socket. When `SpeechDetector` hears speech, a
/// Cartesia socket opens with the half second before it, so the first word is kept. After
/// 0.8 s of quiet the socket is asked to close and its words come back as one utterance.
/// Silence, Pencil taps and steady room noise are never sent. A socket that hears no words
/// within a few seconds is closed, since Cartesia bills for every second it receives.
/// Start and stop from the main queue. Callbacks run on the main queue.
final class LiveListener {
    var onSpeaking: ((Bool) -> Void)?
    /// The words of the utterance being spoken, so far.
    var onHeard: ((String) -> Void)?
    /// One finished utterance. Empty when Cartesia heard no words in it.
    var onUtterance: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    /// 20 ms of 16 kHz 16-bit mono.
    private static let frameBytes = 640
    private static let prerollBytes = 16_000
    /// An utterance this long with no words back is noise, so its socket closes early.
    private static let noiseFrames = 200
    /// An utterance is cut here even with words, so a stuck one cannot run up the bill.
    /// Speech that goes on opens the next one.
    private static let longestFrames = 750
    /// Sockets in a row that fail before words come back. Then live mode stops.
    private static let failuresAllowed = 3
    private static let log = Logger(subsystem: "sketchintent", category: "live")

    private let microphone = MicrophoneTap()
    private let queue = DispatchQueue(label: "sketchintent.live")
    private var running = false

    // Owned by `queue`.
    private var listening = false
    private var apiKey = ""
    private var detector = SpeechDetector()
    private var carry = Data()
    private var preroll = Data()
    private var segment: CartesiaTurns?
    private var segmentFrames = 0
    private var closing: [ObjectIdentifier: CartesiaTurns] = [:]
    private var failures = 0
    private var failed: Set<ObjectIdentifier> = []

    func start() throws {
        guard !running else { return }
        let key = CartesiaSettings.apiKey
        guard !key.isEmpty else { throw VoiceCaptureBlock.missingKey }
        queue.sync {
            listening = true
            apiKey = key
            detector = SpeechDetector()
            carry.removeAll()
            preroll.removeAll()
            failures = 0
            failed.removeAll()
        }
        do {
            try microphone.start { [weak self] pcm in
                guard let self else { return }
                self.queue.async { self.consume(pcm) }
            }
            running = true
        } catch {
            queue.sync { listening = false }
            throw error as? VoiceCaptureBlock ?? .unavailable
        }
    }

    /// Stops the microphone. Words already spoken still come back as an utterance.
    func stop() {
        guard running else { return }
        running = false
        microphone.stop()
        queue.async {
            self.listening = false
            self.endSegment()
        }
    }

    private func consume(_ pcm: Data) {
        guard listening else { return }
        carry.append(pcm)
        while carry.count >= Self.frameBytes {
            let frame = Data(carry.prefix(Self.frameBytes))
            carry.removeFirst(Self.frameBytes)
            process(frame)
        }
    }

    private func process(_ frame: Data) {
        let level = SpeechDetector.level(of: frame)
        let wasWarm = detector.warmedUp
        let change = detector.feed(level)
        if !wasWarm, detector.warmedUp {
            Self.log.debug("Room floor \(self.detector.floor, format: .fixed(precision: 1)) dB")
        }
        guard let segment else {
            preroll.append(frame)
            if preroll.count > Self.prerollBytes {
                preroll.removeFirst(preroll.count - Self.prerollBytes)
            }
            if change == .began {
                Self.log.debug("Speech at \(level, format: .fixed(precision: 1)) dB, floor \(self.detector.floor, format: .fixed(precision: 1)) dB")
                openSegment()
            }
            return
        }
        segment.append(frame)
        segmentFrames += 1
        if change == .ended {
            endSegment()
        } else if segmentFrames >= Self.noiseFrames, segment.text.isEmpty {
            detector.ignoreCurrentLevel()
            Self.log.debug("No words, so noise. Floor now \(self.detector.floor, format: .fixed(precision: 1)) dB")
            dropSegment()
        } else if segmentFrames >= Self.longestFrames {
            detector.endSpeech()
            Self.log.debug("Utterance cut at its longest")
            endSegment()
        }
    }

    private func openSegment() {
        guard let turns = try? CartesiaTurns(apiKey: apiKey) else { return }
        let id = ObjectIdentifier(turns)
        turns.onTranscript = { [weak self] text in
            self?.queue.async { self?.failures = 0 }
            DispatchQueue.main.async { self?.onHeard?(text) }
        }
        turns.onFailure = { [weak self] message in
            self?.queue.async { self?.segmentFailed(id, message: message) }
        }
        turns.onClosed = { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard let closed = self.closing.removeValue(forKey: id) else { return }
                let text = closed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async { self.onUtterance?(text) }
            }
        }
        turns.open()
        turns.append(preroll)
        preroll.removeAll()
        segment = turns
        segmentFrames = 0
        DispatchQueue.main.async { self.onSpeaking?(true) }
    }

    private func endSegment() {
        guard let turns = segment else { return }
        segment = nil
        closing[ObjectIdentifier(turns)] = turns
        turns.finish()
        DispatchQueue.main.async { self.onSpeaking?(false) }
    }

    /// Closes the socket without waiting for its last words. What it heard so far still comes
    /// back, empty for noise, so the listening line clears.
    private func dropSegment() {
        guard let turns = segment else { return }
        segment = nil
        turns.cancel()
        let text = turns.text.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async {
            self.onSpeaking?(false)
            self.onUtterance?(text)
        }
    }

    /// One socket failing, as a dropped connection does, loses only that utterance. Several in
    /// a row, as with a bad key or no network, end live mode.
    private func segmentFailed(_ id: ObjectIdentifier, message: String) {
        guard failed.insert(id).inserted else { return }
        Self.log.error("Cartesia failed: \(message, privacy: .public)")
        // Words that came back before the failure still count.
        if let current = segment, ObjectIdentifier(current) == id {
            detector.endSpeech()
            dropSegment()
        } else if let closed = closing.removeValue(forKey: id) {
            closed.cancel()
            let text = closed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { self.onUtterance?(text) }
        }
        failures += 1
        guard failures >= Self.failuresAllowed else { return }
        DispatchQueue.main.async { self.fail(message) }
    }

    private func fail(_ message: String) {
        guard running else { return }
        stop()
        onFailure?(message)
    }
}

/// Live mode: the agent gets what the person says and draws, a moment at a time, without Send.
/// A moment goes out when the person pauses: shortly after they finish a sentence, or after
/// a few seconds with the Pencil up when they only drew. One moment is with the agent at a
/// time. Anything said or drawn meanwhile waits and goes out together once it answers.
final class LiveSession: ObservableObject {
    /// Something that takes the microphone from live mode for a while.
    enum Hold: Hashable {
        case voiceNote
        case background
    }

    @Published private(set) var isOn = false
    /// The words being spoken now, or nil while nobody is talking.
    @Published private(set) var heard: String?

    /// True when the agent can take a moment now: it is idle, the Mac is connected, and the
    /// Pencil is up.
    var canSend: () -> Bool = { false }
    /// Sends a moment with the words said since the last one, and the page as it is now.
    var send: (String) -> Void = { _ in }
    var onFailure: (String) -> Void = { _ in }

    /// Wait after a sentence, so a stroke drawn while saying it can land.
    private static let afterSpeech: TimeInterval = 0.7
    /// Wait after the last stroke when nothing was said, so a drawing is not sent half done.
    private static let afterInk: TimeInterval = 4
    /// Check again this often while the agent is busy or the Pencil is down.
    private static let retry: TimeInterval = 0.5

    private let permissions = VoicePermissionGate()
    private let listener = LiveListener()
    private var words: [String] = []
    private var pageChanged = false
    private var speaking = false
    private var holds: Set<Hold> = []
    private var pending: DispatchWorkItem?

    init() {
        listener.onSpeaking = { [weak self] speaking in
            guard let self, self.isOn else { return }
            self.speaking = speaking
            if speaking, self.heard == nil {
                self.heard = ""
            }
        }
        listener.onHeard = { [weak self] text in
            guard let self, self.isOn else { return }
            self.heard = text
        }
        listener.onUtterance = { [weak self] text in
            guard let self, self.isOn else { return }
            if !self.speaking {
                self.heard = nil
            }
            guard !text.isEmpty else { return }
            self.words.append(text)
            self.schedule(after: Self.afterSpeech)
        }
        listener.onFailure = { [weak self] message in
            self?.fail(message)
        }
    }

    func start() {
        guard !isOn else { return }
        isOn = true
        words = []
        pageChanged = false
        permissions.authorize { [weak self] result in
            guard let self, self.isOn else { return }
            switch result {
            case .failure(let reason):
                self.fail(reason.message)
            case .success:
                self.listen()
            }
        }
    }

    /// Ends live mode. Words not yet sent are dropped.
    func stop() {
        guard isOn else { return }
        isOn = false
        listener.stop()
        pending?.cancel()
        pending = nil
        words = []
        pageChanged = false
        speaking = false
        heard = nil
    }

    /// The person drew, erased, moved ink, or left a voice note.
    func pageEdited() {
        guard isOn else { return }
        pageChanged = true
        schedule(after: words.isEmpty ? Self.afterInk : Self.afterSpeech)
    }

    /// Lends the microphone out, or takes it back once nothing else holds it.
    func hold(_ hold: Hold, _ held: Bool) {
        if held {
            holds.insert(hold)
        } else {
            holds.remove(hold)
        }
        guard isOn else { return }
        if holds.isEmpty {
            listen()
        } else {
            listener.stop()
            speaking = false
            heard = nil
        }
    }

    private func listen() {
        guard isOn, holds.isEmpty else { return }
        do {
            try listener.start()
        } catch let reason as VoiceCaptureBlock {
            fail(reason.message)
        } catch {
            fail(VoiceCaptureBlock.unavailable.message)
        }
    }

    private func schedule(after delay: TimeInterval) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.sendIfReady()
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func sendIfReady() {
        pending = nil
        guard isOn, !words.isEmpty || pageChanged else { return }
        // Mid-sentence. The end of the sentence schedules this again.
        guard !speaking else { return }
        guard canSend() else {
            schedule(after: Self.retry)
            return
        }
        let spoken = words.joined(separator: " ")
        words = []
        pageChanged = false
        send(spoken)
    }

    private func fail(_ message: String) {
        guard isOn else { return }
        stop()
        onFailure(message)
    }
}
