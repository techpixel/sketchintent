import PencilKit
import SwiftUI
import UIKit

enum FingerSwipe {
    case left
    case right
}

enum SketchTool: Equatable, CaseIterable {
    case pen
    case pointer
    case eraser
    case voice

    /// Clockwise around the dial, starting with the pen on the right.
    static let dialOrder: [SketchTool] = [.pen, .pointer, .eraser, .voice]

    var nextOnDial: SketchTool {
        let order = Self.dialOrder
        guard let index = order.firstIndex(of: self) else { return .pen }
        return order[(index + 1) % order.count]
    }

    var symbolName: String {
        switch self {
        case .pen: return "pencil.and.outline"
        case .pointer: return "hand.point.up.fill"
        case .eraser: return "eraser.fill"
        case .voice: return "mic.fill"
        }
    }

    var accessibilityName: String {
        switch self {
        case .pen: return "Pencil"
        case .pointer: return "Pointer"
        case .eraser: return "Eraser"
        case .voice: return "Voice note"
        }
    }

    /// Radians clockwise from the right side of the dial. UIKit's y axis points down.
    var dialAngle: CGFloat {
        let order = Self.dialOrder
        let index = CGFloat(order.firstIndex(of: self) ?? 0)
        return index * (2 * .pi / CGFloat(order.count))
    }

    var rawTag: Int {
        switch self {
        case .pen: return 1
        case .pointer: return 2
        case .eraser: return 3
        case .voice: return 4
        }
    }

    init?(rawTag: Int) {
        switch rawTag {
        case 1: self = .pen
        case 2: self = .pointer
        case 3: self = .eraser
        case 4: self = .voice
        default: return nil
        }
    }
}

/// Holds the live canvas so the markup controls can read a snapshot without covering the stream.
final class SketchCanvas: ObservableObject {
    fileprivate weak var overlay: PencilOverlayView?
    @Published private(set) var hasInk = false

    func snapshot() -> UIImage? {
        overlay?.snapshot()
    }

    fileprivate func attach(_ overlay: PencilOverlayView) {
        self.overlay = overlay
    }

    fileprivate func noteInk(_ hasInk: Bool) {
        guard self.hasInk != hasInk else { return }
        if Thread.isMainThread {
            self.hasInk = hasInk
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.hasInk = hasInk
            }
        }
    }
}

/// Black pen strokes over the Mac picture, with a white halo so a line stays
/// visible on light and dark desktops. When a pen stroke ends it is smoothed
/// lightly, and the halo is redrawn from that smoothed ink. The same pen ink is
/// sent to the Mac. Voice notes stay on the iPad. The pointer tool uses the Pencil
/// as one finger on the Mac. When Control the Mac with Pencil is on, every tool
/// does the same instead of drawing or recording.
struct PencilOverlay: UIViewRepresentable {
    var spaceID: String?
    var canvas: SketchCanvas
    var tool: SketchTool
    var acceptsTap: Bool
    var drawsWithPencil: Bool
    var sendsPointer: Bool
    var frameWidth: Int
    var frameHeight: Int
    var onPencilPointer: (PointerPhase, UInt16, UInt16) -> Void
    var onInk: (Data, Int, Int, String) -> Void
    var onTap: () -> Void
    var onDoubleTap: () -> Void
    var onFingerSwipe: (FingerSwipe) -> Void
    var onToggleTool: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            acceptsTap: acceptsTap,
            onTap: onTap,
            onDoubleTap: onDoubleTap,
            onFingerSwipe: onFingerSwipe,
            onToggleTool: onToggleTool
        )
    }

    func makeUIView(context: Context) -> PencilOverlayView {
        let view = PencilOverlayView()
        view.installGestures(target: context.coordinator)
        view.installPencilDoubleTap(delegate: context.coordinator)
        view.onInkChange = { [weak canvas] hasInk in
            canvas?.noteInk(hasInk)
        }
        view.onInk = onInk
        canvas.attach(view)
        view.setPointer(
            sends: sendsPointer,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            onPencil: onPencilPointer
        )
        view.apply(tool: tool, drawsWithPencil: drawsWithPencil)
        return view
    }

    func updateUIView(_ uiView: PencilOverlayView, context: Context) {
        context.coordinator.acceptsTap = acceptsTap
        context.coordinator.onTap = onTap
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.onFingerSwipe = onFingerSwipe
        context.coordinator.onToggleTool = onToggleTool
        uiView.onInkChange = { [weak canvas] hasInk in
            canvas?.noteInk(hasInk)
        }
        uiView.onInk = onInk
        canvas.attach(uiView)
        uiView.setPointer(
            sends: sendsPointer,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            onPencil: onPencilPointer
        )
        uiView.apply(tool: tool, drawsWithPencil: drawsWithPencil)
        if let spaceID {
            uiView.showSpace(spaceID)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
        var acceptsTap: Bool
        var onTap: () -> Void
        var onDoubleTap: () -> Void
        var onFingerSwipe: (FingerSwipe) -> Void
        var onToggleTool: () -> Void
        private var reportedDesktopSwipe = false

        init(
            acceptsTap: Bool,
            onTap: @escaping () -> Void,
            onDoubleTap: @escaping () -> Void,
            onFingerSwipe: @escaping (FingerSwipe) -> Void,
            onToggleTool: @escaping () -> Void
        ) {
            self.acceptsTap = acceptsTap
            self.onTap = onTap
            self.onDoubleTap = onDoubleTap
            self.onFingerSwipe = onFingerSwipe
            self.onToggleTool = onToggleTool
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touch.type != .pencil
        }

        /// The desktop pan may proceed with the drawing gesture and the scroll pan.
        /// Neither of those is asked to wait until this pan fails.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer is ThreeFingerDesktopPan || otherGestureRecognizer is ThreeFingerDesktopPan
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard acceptsTap else { return }
            if let host = recognizer.view?.superview as? PencilOverlayView {
                let point = recognizer.location(in: host)
                if host.handleCanvasTap(at: point) {
                    return
                }
            }
            onTap()
        }

        /// Finger double-tap. The single-tap recognizer waits for this to fail,
        /// so the status badge does not toggle on the way to the trackpad.
        @objc func fingerDoubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, acceptsTap else { return }
            onDoubleTap()
        }

        @objc func desktopPanned(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .changed:
                reportDesktopSwipeIfNeeded(recognizer)
            case .ended:
                reportDesktopSwipeIfNeeded(recognizer)
                reportedDesktopSwipe = false
            case .began, .cancelled, .failed:
                reportedDesktopSwipe = false
            default:
                break
            }
        }

        private func reportDesktopSwipeIfNeeded(_ recognizer: UIPanGestureRecognizer) {
            guard !reportedDesktopSwipe else { return }
            let translation = recognizer.translation(in: recognizer.view)
            guard abs(translation.x) >= 36, abs(translation.x) > abs(translation.y) else { return }
            reportedDesktopSwipe = true
            onFingerSwipe(translation.x < 0 ? .left : .right)
        }

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            toggleToolFromPencilDoubleTap()
        }

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            toggleToolFromPencilDoubleTap()
        }

        /// Barrel double-tap. A finger never arrives here.
        /// A finger single tap shows the status badge. A finger double-tap shows the trackpad.
        private func toggleToolFromPencilDoubleTap() {
            guard pencilDoubleTapSwitchesTools() else { return }
            onToggleTool()
        }

        /// Settings → Apple Pencil. Switch-tool actions move to the next tool on the dial.
        /// Ignore does nothing. A preference this build cannot name still moves it.
        private func pencilDoubleTapSwitchesTools() -> Bool {
            let action = UIPencilInteraction.preferredTapAction
            switch action {
            case .ignore:
                return false
            case .switchEraser, .switchPrevious:
                return true
            case .showColorPalette, .showInkAttributes:
                return false
            default:
                return pencilDoubleTapSwitchesUnlistedToolAction(action)
            }
        }

        private func pencilDoubleTapSwitchesUnlistedToolAction(_ action: UIPencilPreferredAction) -> Bool {
            if #available(iOS 17.5, *) {
                switch action {
                case .showContextualPalette, .runSystemShortcut:
                    return false
                default:
                    return true
                }
            }
            return true
        }
    }
}

/// Horizontal three-finger pan. Finger, trackpad, and pointer only — never Pencil.
private final class ThreeFingerDesktopPan: UIPanGestureRecognizer {
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        minimumNumberOfTouches = 3
        maximumNumberOfTouches = 3
        allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
    }
}

final class PencilOverlayView: UIView, PKCanvasViewDelegate {
    private let halo = UIImageView()
    private let canvas = InkCanvasView()
    private var drawings: [String: PKDrawing] = [:]
    private var currentSpaceID: String?
    private var appliedTool: SketchTool?
    var onInkChange: ((Bool) -> Void)?
    /// PNG of this space's pen ink in captured-frame pixels. Empty data clears the Mac.
    var onInk: (Data, Int, Int, String) -> Void = { _, _, _, _ in }
    var frameWidth = 0
    var frameHeight = 0
    var sendsPointer = false
    var onPencilPointer: (PointerPhase, UInt16, UInt16) -> Void = { _, _, _ in }
    private var pointerDown = false
    private var lastPixel: (x: UInt16, y: UInt16)?
    /// Last drawing-space point of an in-progress stroke erase, so a fast drag still covers the gap between touches.
    private var lastEraserPoint: CGPoint?
    /// True from pencil-down to lift while the pen tool is inking. Eraser, pointer, and Mac-control touches never set this.
    private var penStrokeOpen = false
    private var inkWork: DispatchWorkItem?
    private var inkLayoutSize = CGSize.zero
    private var lastSentInk: (png: Data, width: Int, height: Int, spaceID: String)?
    /// How many strokes were already stored when the current pen stroke began. Earlier strokes are left as they are.
    private var strokeCountAtPenDown = 0
    /// Set while a smoothed stroke is written back, so that write is not smoothed again.
    private var isApplyingSmoothedStroke = false
    /// Voice notes for the desktop on screen, and the notes kept for every other space.
    private var notes: [VoiceNote] = []
    private var notesBySpace: [String: [VoiceNote]] = [:]
    private var openNoteID: UUID?
    private let noteLayer = VoiceNoteLayer()
    private let voicePermissions = VoicePermissionGate()
    private let voiceTranscriber = VoiceTranscriber()
    private var voiceHold: VoiceHold?
    private var voiceHoldItem: DispatchWorkItem?
    private var voiceArmed = false
    private var noticeToken = 0
    private let recordHaptic = UIImpactFeedbackGenerator(style: .soft)

    private struct VoiceHold {
        let token: UUID
        let anchor: CGPoint
        var armed = false
        var recording = false
    }

    /// A hold shorter than this, or a move past the slop before it, does not record.
    private static let voiceHoldDelay: TimeInterval = 0.5
    private static let voiceSlop: CGFloat = 12

    /// Half of the old 32-point bitmap tip. Touching ink deletes that whole stroke.
    private static let eraserRadius: CGFloat = 16
    /// Distance between path samples, in stroke space. Shorter than the tip, so a graze between samples still hits.
    private static let eraserSampleDistance: CGFloat = 2
    /// Live ink while a stroke is down stays under this width so the link is not flooded.
    private static let liveInkMaxWidth = 1280
    private static let liveInkMaxBytes = 400_000

    var hasInk: Bool {
        !canvas.drawing.strokes.isEmpty
    }

    func setPointer(
        sends: Bool,
        frameWidth: Int,
        frameHeight: Int,
        onPencil: @escaping (PointerPhase, UInt16, UInt16) -> Void
    ) {
        onPencilPointer = onPencil
        let sizeChanged = self.frameWidth != frameWidth || self.frameHeight != frameHeight
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        if sizeChanged {
            publishInk(immediate: true)
        }
        if sendsPointer && !sends {
            endPointer()
        }
        sendsPointer = sends
    }

    /// Pen, eraser, and voice notes take effect only while the Pencil is drawing.
    /// Pointer mode, and Control the Mac with Pencil, leave the page alone and forward the Pencil.
    func apply(tool: SketchTool, drawsWithPencil: Bool) {
        let sendsPencilAsPointer = !drawsWithPencil || tool == .pointer
        let erasing = drawsWithPencil && tool == .eraser
        let annotating = drawsWithPencil && tool == .voice && !sendsPencilAsPointer
        canvas.forwardsPencilAsPointer = sendsPencilAsPointer
        canvas.erasesWholeStrokes = erasing
        canvas.capturesVoiceHold = annotating
        if !erasing {
            lastEraserPoint = nil
        }
        if annotating != voiceArmed {
            if annotating {
                voicePermissions.promptIfUndetermined()
                recordHaptic.prepare()
            } else {
                endVoiceHold(commit: false)
            }
            voiceArmed = annotating
        }
        // The stroke eraser and the voice hold handle Pencil touches themselves.
        // PencilKit's vector eraser waits until lift, and its bitmap eraser only
        // clears the pixels underneath. The voice tool must not lay down ink.
        canvas.drawingGestureRecognizer.isEnabled = drawsWithPencil && !erasing && !sendsPencilAsPointer && !annotating
        canvas.drawingGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.pencil.rawValue)
        ]
        canvas.keepScrollPanOffDesktopSwipe()
        guard drawsWithPencil, appliedTool != tool else { return }
        appliedTool = tool
        switch tool {
        case .pen:
            canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        case .eraser, .voice:
            break
        case .pointer:
            canvas.drawingGestureRecognizer.isEnabled = false
            canvas.forwardsPencilAsPointer = true
            canvas.erasesWholeStrokes = false
            canvas.capturesVoiceHold = false
            lastEraserPoint = nil
        }
    }

    func snapshot() -> UIImage? {
        let strokeBounds = canvas.drawing.bounds
        guard hasInk, strokeBounds.width > 0, strokeBounds.height > 0 else { return nil }
        let scale = max(window?.screen.scale ?? traitCollection.displayScale, 1)
        return canvas.drawing.image(from: strokeBounds.insetBy(dx: -16, dy: -16), scale: scale)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        halo.isOpaque = false
        halo.backgroundColor = .clear
        halo.isUserInteractionEnabled = false
        halo.contentMode = .scaleToFill
        halo.layer.shadowColor = UIColor.white.cgColor
        halo.layer.shadowOpacity = 1
        halo.layer.shadowRadius = 2.5
        halo.layer.shadowOffset = .zero
        halo.layer.masksToBounds = false
        addSubview(halo)

        canvas.frame = bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.delegate = self
        addSubview(canvas)
        noteLayer.frame = bounds
        noteLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        noteLayer.isUserInteractionEnabled = false
        addSubview(noteLayer)
        canvas.onPencilPointer = { [weak self] phase, point in
            guard let self else { return }
            self.handlePencil(phase: phase, at: self.canvas.convert(point, to: self))
        }
        canvas.onPencilErase = { [weak self] phase, samples in
            self?.eraseStrokes(phase: phase, samples: samples)
        }
        canvas.onPencilVoice = { [weak self] phase, samples in
            guard let self else { return }
            let points = samples.map { self.canvas.convert($0, to: self) }
            switch phase {
            case .began:
                guard let anchor = points.first else { return }
                self.beginVoiceTouch(at: anchor)
                self.moveVoiceTouch(points)
            case .moved:
                self.moveVoiceTouch(points)
            case .ended:
                self.endVoiceTouch()
            case .cancelled:
                self.endVoiceHold(commit: false)
            default:
                break
            }
        }
    }

    deinit {
        voiceHoldItem?.cancel()
        voiceTranscriber.onPartial = nil
        voiceTranscriber.onFailure = nil
        _ = voiceTranscriber.stop()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func installGestures(target: PencilOverlay.Coordinator) {
        let finger: [NSNumber] = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]

        let doubleTap = UITapGestureRecognizer(target: target, action: #selector(PencilOverlay.Coordinator.fingerDoubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.numberOfTouchesRequired = 1
        doubleTap.allowedTouchTypes = finger
        doubleTap.delegate = target

        let tap = UITapGestureRecognizer(target: target, action: #selector(PencilOverlay.Coordinator.tapped(_:)))
        tap.numberOfTouchesRequired = 1
        tap.allowedTouchTypes = finger
        tap.delegate = target
        tap.require(toFail: doubleTap)
        canvas.addGestureRecognizer(doubleTap)
        canvas.addGestureRecognizer(tap)

        let desktopPan = ThreeFingerDesktopPan(target: target, action: #selector(PencilOverlay.Coordinator.desktopPanned(_:)))
        desktopPan.minimumNumberOfTouches = 3
        desktopPan.maximumNumberOfTouches = 3
        desktopPan.allowedTouchTypes = finger
        desktopPan.delegate = target
        canvas.addGestureRecognizer(desktopPan)

        canvas.drawingGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.pencil.rawValue)
        ]
        canvas.keepScrollPanOffDesktopSwipe()
    }

    /// Apple Pencil barrel double-tap. This is not a screen touch, so it does not
    /// compete with the one-finger badge tap or the three-finger desktop pan.
    func installPencilDoubleTap(delegate: UIPencilInteractionDelegate) {
        let interaction = UIPencilInteraction()
        interaction.delegate = delegate
        addInteraction(interaction)
    }

    /// Keeps each desktop's strokes and voice notes with that desktop. The first id
    /// adopts whatever is already on the page, so a stroke or note started before
    /// the Mac checks in is not dropped.
    func showSpace(_ id: String) {
        guard id != currentSpaceID else { return }
        if voiceHold?.recording == true {
            endVoiceHold(commit: true)
        } else if voiceHold != nil {
            endVoiceHold(commit: false)
        }
        lastEraserPoint = nil
        penStrokeOpen = false
        inkWork?.cancel()
        inkWork = nil
        if let currentSpaceID {
            drawings[currentSpaceID] = canvas.drawing
            notesBySpace[currentSpaceID] = notes
        }
        let adoptingExistingInk = currentSpaceID == nil && !canvas.drawing.strokes.isEmpty
        let adoptingNotes = currentSpaceID == nil && !notes.isEmpty
        currentSpaceID = id
        if adoptingExistingInk {
            drawings[id] = canvas.drawing
        } else {
            canvas.drawing = drawings[id] ?? PKDrawing()
            canvasViewDrawingDidChange(canvas)
        }
        if adoptingNotes {
            notesBySpace[id] = notes
        } else {
            notes = notesBySpace[id] ?? []
        }
        openNoteID = nil
        noticeToken += 1
        noteLayer.setLive(anchor: nil, text: "")
        noteLayer.setNotice(anchor: nil, text: "")
        noteLayer.setSaved(notes: notes, openID: nil)
        publishInk(immediate: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        noteLayer.frame = bounds
        noteLayer.relayout()
        if bounds.width > 1, bounds.height > 1, bounds.size != inkLayoutSize {
            inkLayoutSize = bounds.size
            publishInk(immediate: true)
        }
    }

    /// Finger taps on a dot open its note. A tap on the open bubble leaves it up.
    /// Anywhere else closes it and lets the status-badge tap run.
    func handleCanvasTap(at point: CGPoint) -> Bool {
        switch noteLayer.hit(at: convert(point, to: noteLayer)) {
        case .bubble:
            return true
        case .dot(let id):
            openNoteID = id
            noteLayer.setSaved(notes: notes, openID: id)
            return true
        case .none:
            guard openNoteID != nil else { return false }
            openNoteID = nil
            noteLayer.setSaved(notes: notes, openID: nil)
            return false
        }
    }

    private func beginVoiceTouch(at anchor: CGPoint) {
        if voiceHold?.recording == true {
            endVoiceHold(commit: true)
        } else if voiceHold != nil {
            endVoiceHold(commit: false)
        }
        recordHaptic.prepare()
        let token = UUID()
        voiceHold = VoiceHold(token: token, anchor: anchor)
        let work = DispatchWorkItem { [weak self] in
            self?.armVoiceHold(token: token)
        }
        voiceHoldItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.voiceHoldDelay, execute: work)
    }

    private func moveVoiceTouch(_ samples: [CGPoint]) {
        guard let hold = voiceHold, !hold.armed else { return }
        let broke = samples.contains { hypot($0.x - hold.anchor.x, $0.y - hold.anchor.y) > Self.voiceSlop }
        guard broke else { return }
        endVoiceHold(commit: false)
    }

    private func endVoiceTouch() {
        let commit = voiceHold?.recording == true
        endVoiceHold(commit: commit)
    }

    private func armVoiceHold(token: UUID) {
        guard var hold = voiceHold, hold.token == token, !hold.armed else { return }
        hold.armed = true
        voiceHold = hold
        let anchor = hold.anchor
        voicePermissions.authorize { [weak self] result in
            guard let self, self.voiceHold?.token == token else { return }
            switch result {
            case .failure(let reason):
                self.voiceHold = nil
                self.showVoiceNotice(reason.message, at: anchor)
            case .success:
                self.startVoiceRecording(token: token, anchor: anchor)
            }
        }
    }

    private func startVoiceRecording(token: UUID, anchor: CGPoint) {
        guard voiceHold?.token == token, voiceHold?.recording == false else { return }
        openNoteID = nil
        noteLayer.setSaved(notes: notes, openID: nil)
        noteLayer.setLive(anchor: anchor, text: "")
        voiceTranscriber.onPartial = { [weak self] text in
            guard let self, self.voiceHold?.token == token else { return }
            self.noteLayer.setLive(anchor: anchor, text: text)
        }
        voiceTranscriber.onFailure = { [weak self] in
            guard let self, self.voiceHold?.token == token else { return }
            let point = self.voiceHold?.anchor ?? anchor
            self.endVoiceHold(commit: false)
            self.showVoiceNotice(VoiceCaptureBlock.unavailable.message, at: point)
        }
        do {
            try voiceTranscriber.start()
        } catch {
            voiceTranscriber.onPartial = nil
            voiceTranscriber.onFailure = nil
            voiceHold = nil
            noteLayer.setLive(anchor: nil, text: "")
            showVoiceNotice(VoiceCaptureBlock.unavailable.message, at: anchor)
            return
        }
        guard var hold = voiceHold, hold.token == token else {
            _ = voiceTranscriber.stop()
            return
        }
        hold.recording = true
        voiceHold = hold
        recordHaptic.impactOccurred()
        recordHaptic.prepare()
    }

    private func endVoiceHold(commit: Bool) {
        guard let hold = voiceHold else { return }
        voiceHoldItem?.cancel()
        voiceHoldItem = nil
        voiceHold = nil
        voiceTranscriber.onPartial = nil
        voiceTranscriber.onFailure = nil
        let text = hold.recording
            ? voiceTranscriber.stop().trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        noteLayer.setLive(anchor: nil, text: "")
        guard commit, hold.recording, !text.isEmpty else { return }
        addVoiceNote(VoiceNote(id: UUID(), anchor: hold.anchor, text: text))
    }

    private func addVoiceNote(_ note: VoiceNote) {
        notes.append(note)
        if let currentSpaceID {
            notesBySpace[currentSpaceID] = notes
        }
        openNoteID = nil
        noteLayer.setSaved(notes: notes, openID: nil)
    }

    private func showVoiceNotice(_ text: String, at anchor: CGPoint) {
        noticeToken += 1
        let token = noticeToken
        noteLayer.setNotice(anchor: anchor, text: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self, self.noticeToken == token else { return }
            self.noteLayer.setNotice(anchor: nil, text: "")
        }
    }

    /// One sample per touch callback. Coalesced history is not forwarded, so the
    /// stream stays at the touch rate. A point in the letterbox is ignored.
    private func handlePencil(phase: UITouch.Phase, at point: CGPoint) {
        guard sendsPointer else { return }
        switch phase {
        case .began:
            guard let pixel = pixel(at: point) else { return }
            pointerDown = true
            lastPixel = pixel
            onPencilPointer(.down, pixel.x, pixel.y)
        case .moved:
            guard pointerDown, let pixel = pixel(at: point) else { return }
            guard lastPixel?.x != pixel.x || lastPixel?.y != pixel.y else { return }
            lastPixel = pixel
            onPencilPointer(.move, pixel.x, pixel.y)
        case .ended, .cancelled:
            if let pixel = pixel(at: point) {
                lastPixel = pixel
            }
            endPointer()
        default:
            break
        }
    }

    /// Releases a button that is already down, including when pointer mode turns off
    /// while the Pencil is still on the glass. Uses the last point that was on the picture.
    func endPointer() {
        guard pointerDown else { return }
        pointerDown = false
        let pixel = lastPixel
        lastPixel = nil
        if let pixel {
            onPencilPointer(.up, pixel.x, pixel.y)
        }
    }

    private func pixel(at point: CGPoint) -> (x: UInt16, y: UInt16)? {
        guard frameWidth > 0, frameHeight > 0 else { return nil }
        return FrameCoordinates.pixel(
            viewX: Double(point.x),
            viewY: Double(point.y),
            viewWidth: Double(bounds.width),
            viewHeight: Double(bounds.height),
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard !isApplyingSmoothedStroke else { return }
        penStrokeOpen = true
        strokeCountAtPenDown = canvasView.drawing.strokes.count
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard !isApplyingSmoothedStroke else { return }
        smoothFinishedPenStroke(on: canvasView)
        halo.isHidden = false
        canvasViewDrawingDidChange(canvasView)
    }

    /// Replaces only the pen stroke that just finished. The live stroke is left alone until lift,
    /// and the halo refresh below reads the drawing after this replacement.
    private func smoothFinishedPenStroke(on canvasView: PKCanvasView) {
        guard penStrokeOpen else { return }
        penStrokeOpen = false
        let strokes = canvasView.drawing.strokes
        let firstNew = min(strokeCountAtPenDown, strokes.count)
        guard firstNew < strokes.count else { return }
        var updated = strokes
        var didSmooth = false
        for index in firstNew..<strokes.count {
            guard let smoothed = StrokeSmoothing.smoothedPenStroke(from: strokes[index]) else { continue }
            updated[index] = smoothed
            didSmooth = true
        }
        guard didSmooth else { return }
        isApplyingSmoothedStroke = true
        canvasView.drawing = PKDrawing(strokes: updated)
        isApplyingSmoothedStroke = false
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        if let currentSpaceID {
            drawings[currentSpaceID] = canvasView.drawing
        }
        let strokeBounds = canvasView.drawing.bounds
        guard !strokeBounds.isNull, !strokeBounds.isInfinite, strokeBounds.width > 0, strokeBounds.height > 0 else {
            halo.image = nil
            onInkChange?(false)
            publishInk(immediate: !penStrokeOpen)
            return
        }
        let rect = strokeBounds.insetBy(dx: -12, dy: -12)
        let scale = max(window?.screen.scale ?? traitCollection.displayScale, 1)
        halo.image = canvasView.drawing.image(from: rect, scale: scale)
        halo.frame = rect
        onInkChange?(hasInk)
        publishInk(immediate: !penStrokeOpen)
    }

    /// Sends this desktop's pen ink. Stroke end, erase, and a space change go immediately.
    /// While the Pencil is down, updates are throttled and kept small.
    private func publishInk(immediate: Bool) {
        guard frameWidth > 1, frameHeight > 1 else { return }
        if immediate || !penStrokeOpen {
            inkWork?.cancel()
            inkWork = nil
            renderAndSend(live: false)
            return
        }
        guard inkWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.inkWork = nil
            self.renderAndSend(live: self.penStrokeOpen)
        }
        inkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func renderAndSend(live: Bool) {
        let spaceID = currentSpaceID ?? ""
        if canvas.drawing.strokes.isEmpty {
            emitInk(Data(), width: 0, height: 0, spaceID: spaceID)
            return
        }
        guard let drawingRect = pictureDrawingRect(), drawingRect.width > 0, drawingRect.height > 0 else { return }
        let budget = min(live ? Self.liveInkMaxBytes : Int.max, protocolInkBudget(spaceID: spaceID))
        var cap = live ? min(frameWidth, Self.liveInkMaxWidth) : frameWidth
        for _ in 0..<6 {
            guard let raster = rasterize(drawingRect: drawingRect, maxPixelWidth: cap) else { return }
            if raster.png.count <= budget {
                emitInk(raster.png, width: raster.width, height: raster.height, spaceID: spaceID)
                return
            }
            if cap <= 480 { break }
            cap = max(480, cap / 2)
        }
    }

    private func emitInk(_ png: Data, width: Int, height: Int, spaceID: String) {
        if let lastSentInk,
           lastSentInk.png == png,
           lastSentInk.width == width,
           lastSentInk.height == height,
           lastSentInk.spaceID == spaceID {
            return
        }
        lastSentInk = (png, width, height, spaceID)
        onInk(png, width, height, spaceID)
    }

    /// The letterboxed picture, in PencilKit drawing coordinates. Same fit as `FrameCoordinates`.
    private func pictureDrawingRect() -> CGRect? {
        guard frameWidth > 1, frameHeight > 1, bounds.width > 1, bounds.height > 1 else { return nil }
        guard let picture = FrameCoordinates.pictureRect(
            viewWidth: Double(bounds.width),
            viewHeight: Double(bounds.height),
            frameWidth: frameWidth,
            frameHeight: frameHeight
        ), picture.width > 0, picture.height > 0 else { return nil }
        let scale = canvas.zoomScale > 0 ? canvas.zoomScale : 1
        return CGRect(
            x: (CGFloat(picture.x) + canvas.contentOffset.x) / scale,
            y: (CGFloat(picture.y) + canvas.contentOffset.y) / scale,
            width: CGFloat(picture.width) / scale,
            height: CGFloat(picture.height) / scale
        )
    }

    private func protocolInkBudget(spaceID: String) -> Int {
        let header = 1 + 8 + 1 + spaceID.utf8.count
        return max(0, StreamFraming.maxPayloadLength - header)
    }

    /// Frame-sized PNG of the ink inside the picture, with the same white halo the iPad draws.
    private func rasterize(drawingRect: CGRect, maxPixelWidth: Int) -> (png: Data, width: Int, height: Int)? {
        let pixelWidth = min(frameWidth, max(2, maxPixelWidth))
        let pixelHeight = max(2, Int((Double(frameHeight) * Double(pixelWidth) / Double(frameWidth)).rounded()))
        let renderScale = max(CGFloat(pixelWidth) / drawingRect.width, 0.5)
        let ink = canvas.drawing.image(from: drawingRect, scale: renderScale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: pixelWidth, height: pixelHeight),
            format: format
        )
        let image = renderer.image { context in
            let blur = max(renderScale * 2.5, 1)
            context.cgContext.setShadow(offset: .zero, blur: blur, color: UIColor.white.cgColor)
            ink.draw(in: CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
        }
        guard let png = image.pngData(), !png.isEmpty else { return nil }
        return (png, pixelWidth, pixelHeight)
    }

    /// Deletes every stroke the eraser touches on the way down and while it moves.
    /// A lift is not required. Pointer mode never reaches this; that path reports clicks instead.
    private func eraseStrokes(phase: UITouch.Phase, samples: [CGPoint]) {
        guard canvas.erasesWholeStrokes, !canvas.forwardsPencilAsPointer else { return }
        let points = samples.map { drawingPoint($0) }
        switch phase {
        case .began:
            guard !points.isEmpty else { return }
            removeTouchedStrokes(along: points)
            lastEraserPoint = points.last
        case .moved, .ended:
            guard !points.isEmpty else {
                if phase == .ended { lastEraserPoint = nil }
                return
            }
            var polyline = points
            if let lastEraserPoint {
                polyline.insert(lastEraserPoint, at: 0)
            }
            removeTouchedStrokes(along: polyline)
            lastEraserPoint = phase == .ended ? nil : points.last
        case .cancelled:
            lastEraserPoint = nil
        default:
            break
        }
    }

    private func removeTouchedStrokes(along polyline: [CGPoint]) {
        let strokes = canvas.drawing.strokes
        guard !strokes.isEmpty else { return }
        let kept = strokes.filter { !stroke($0, touches: polyline) }
        guard kept.count != strokes.count else { return }
        canvas.drawing = PKDrawing(strokes: kept)
        halo.isHidden = false
        canvasViewDrawingDidChange(canvas)
    }

    private func drawingPoint(_ viewPoint: CGPoint) -> CGPoint {
        let scale = canvas.zoomScale > 0 ? canvas.zoomScale : 1
        return CGPoint(
            x: (viewPoint.x + canvas.contentOffset.x) / scale,
            y: (viewPoint.y + canvas.contentOffset.y) / scale
        )
    }

    private func stroke(_ stroke: PKStroke, touches polyline: [CGPoint]) -> Bool {
        let radius = Self.eraserRadius
        var eraserBounds = CGRect.null
        for point in polyline {
            let dot = CGRect(origin: point, size: .zero).insetBy(dx: -radius, dy: -radius)
            eraserBounds = eraserBounds.union(dot)
        }
        guard stroke.renderBounds.insetBy(dx: -1, dy: -1).intersects(eraserBounds) else { return false }

        let path = stroke.path
        guard path.count > 0 else { return false }
        let transform = stroke.transform
        if inkSample(path.interpolatedPoint(at: 0), transform: transform, touches: polyline, radius: radius) {
            return true
        }
        let end = CGFloat(path.count - 1)
        if end > 0, inkSample(path.interpolatedPoint(at: end), transform: transform, touches: polyline, radius: radius) {
            return true
        }
        guard end > 0 else { return false }
        for sample in path.interpolatedPoints(by: .distance(Self.eraserSampleDistance)) {
            if inkSample(sample, transform: transform, touches: polyline, radius: radius) {
                return true
            }
        }
        return false
    }

    private func inkSample(
        _ sample: PKStrokePoint,
        transform: CGAffineTransform,
        touches polyline: [CGPoint],
        radius: CGFloat
    ) -> Bool {
        let location = sample.location.applying(transform)
        let scale = max(hypot(transform.a, transform.c), hypot(transform.b, transform.d))
        let inkRadius = max(sample.size.width, sample.size.height) * (scale > 0 ? scale : 1) / 2
        return distance(location, toPolyline: polyline) <= inkRadius + radius
    }

    private func distance(_ point: CGPoint, toPolyline polyline: [CGPoint]) -> CGFloat {
        guard let first = polyline.first else { return .greatestFiniteMagnitude }
        if polyline.count == 1 {
            return hypot(point.x - first.x, point.y - first.y)
        }
        var best = CGFloat.greatestFiniteMagnitude
        for index in 1..<polyline.count {
            best = min(best, distance(point, toSegmentFrom: polyline[index - 1], to: polyline[index]))
        }
        return best
    }

    private func distance(_ point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared <= 0.0001 {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }
}

/// PencilKit canvas. Finger gestures are attached here; only the Pencil draws.
final class InkCanvasView: PKCanvasView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isScrollEnabled = false
        bounces = false
        bouncesZoom = false
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        minimumZoomScale = 1
        maximumZoomScale = 1
        contentInsetAdjustmentBehavior = .never
        delaysContentTouches = false
        canCancelContentTouches = false
        clipsToBounds = false
        drawingPolicy = .pencilOnly
        tool = PKInkingTool(.pen, color: .black, width: 4)
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        keepScrollPanOffDesktopSwipe()
    }

    /// When set, Pencil touches are reported instead of drawing. Finger touches still draw nothing.
    var forwardsPencilAsPointer = false
    var onPencilPointer: ((UITouch.Phase, CGPoint) -> Void)?
    /// When set, a Pencil touch deletes each stroke it meets. Finger touches still draw nothing.
    var erasesWholeStrokes = false
    var onPencilErase: ((UITouch.Phase, [CGPoint]) -> Void)?
    /// When set, a Pencil hold can record a voice note. Finger touches still draw nothing.
    var capturesVoiceHold = false
    var onPencilVoice: ((UITouch.Phase, [CGPoint]) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliver(touches, phase: .began, event: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliver(touches, phase: .moved, event: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliver(touches, phase: .ended, event: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        deliver(touches, phase: .cancelled, event: event)
    }

    private func deliver(_ touches: Set<UITouch>, phase: UITouch.Phase, event: UIEvent?) {
        if forwardsPencilAsPointer {
            drawingGestureRecognizer.isEnabled = false
            var pencil: UITouch?
            var others = Set<UITouch>()
            for touch in touches {
                if touch.type == .pencil, pencil == nil {
                    pencil = touch
                } else if touch.type != .pencil {
                    others.insert(touch)
                }
            }
            if let pencil {
                onPencilPointer?(phase, pencil.location(in: self))
            }
            if !others.isEmpty {
                pass(others, phase: phase, event: event)
            }
            return
        }
        if erasesWholeStrokes {
            drawingGestureRecognizer.isEnabled = false
            var pencil: UITouch?
            var others = Set<UITouch>()
            for touch in touches {
                if touch.type == .pencil, pencil == nil {
                    pencil = touch
                } else if touch.type != .pencil {
                    others.insert(touch)
                }
            }
            if let pencil {
                let history = event?.coalescedTouches(for: pencil) ?? [pencil]
                onPencilErase?(phase, history.map { $0.preciseLocation(in: self) })
            }
            if !others.isEmpty {
                pass(others, phase: phase, event: event)
            }
            return
        }
        if capturesVoiceHold {
            drawingGestureRecognizer.isEnabled = false
            var pencil: UITouch?
            var others = Set<UITouch>()
            for touch in touches {
                if touch.type == .pencil, pencil == nil {
                    pencil = touch
                } else if touch.type != .pencil {
                    others.insert(touch)
                }
            }
            if let pencil {
                let history = event?.coalescedTouches(for: pencil) ?? [pencil]
                onPencilVoice?(phase, history.map { $0.preciseLocation(in: self) })
            }
            if !others.isEmpty {
                pass(others, phase: phase, event: event)
            }
            return
        }
        pass(touches, phase: phase, event: event)
    }

    private func pass(_ touches: Set<UITouch>, phase: UITouch.Phase, event: UIEvent?) {
        switch phase {
        case .began:
            super.touchesBegan(touches, with: event)
        case .moved:
            super.touchesMoved(touches, with: event)
        case .ended:
            super.touchesEnded(touches, with: event)
        case .cancelled:
            super.touchesCancelled(touches, with: event)
        default:
            break
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        keepScrollPanOffDesktopSwipe()
    }

    /// PKCanvasView is a scroll view. Its pan still tracks every finger and
    /// cancels a three-finger swipe. One- and two-finger pans stay unchanged,
    /// and this screen does not zoom.
    func keepScrollPanOffDesktopSwipe() {
        panGestureRecognizer.maximumNumberOfTouches = 2
        pinchGestureRecognizer?.isEnabled = false
    }

    /// PencilKit repaints a solid background over the stream. Keep the page clear
    /// so the stroke, not a white sheet, is what shows.
    override var backgroundColor: UIColor? {
        get { .clear }
        set { super.backgroundColor = .clear }
    }
}

/// One light pass over a finished pen stroke. PencilKit has no smoothing API, so the
/// stroke's own control points are averaged and the stroke is replaced.
///
/// The window is 10 points of arc length, with triangular weights. The first and last
/// samples stay where the Pencil put them. Size, opacity, and force use the same
/// weights, so pressure and width follow the smoothed centerline. Nothing here fits
/// a circle, rectangle, or straight line.
private enum StrokeSmoothing {
    /// How far along the stroke, in points, a sample may influence its neighbors.
    private static let radius: CGFloat = 10

    /// Nil when the stroke should be kept as PencilKit produced it.
    static func smoothedPenStroke(from stroke: PKStroke) -> PKStroke? {
        let path = stroke.path
        guard path.count >= 3, stroke.ink.inkType == .pen else { return nil }
        let controls = (0..<path.count).map { path[$0] }
        let smoothedPath = PKStrokePath(
            controlPoints: smoothedControls(controls),
            creationDate: path.creationDate
        )
        return PKStroke(
            ink: stroke.ink,
            path: smoothedPath,
            transform: stroke.transform,
            mask: stroke.mask,
            randomSeed: stroke.randomSeed
        )
    }

    private static func smoothedControls(_ points: [PKStrokePoint]) -> [PKStrokePoint] {
        let count = points.count
        var distanceFromStart = [CGFloat](repeating: 0, count: count)
        for index in 1..<count {
            let previous = points[index - 1].location
            let current = points[index].location
            distanceFromStart[index] = distanceFromStart[index - 1] + hypot(current.x - previous.x, current.y - previous.y)
        }
        return points.indices.map { index in
            let point = points[index]
            if index == 0 || index == count - 1 { return point }
            let center = distanceFromStart[index]
            var left = index
            while left > 0, center - distanceFromStart[left] <= radius {
                left -= 1
            }
            if center - distanceFromStart[left] > radius {
                left += 1
            }
            var right = index
            while right + 1 < count, distanceFromStart[right + 1] - center <= radius {
                right += 1
            }
            var weightSum: CGFloat = 0
            var x: CGFloat = 0
            var y: CGFloat = 0
            var width: CGFloat = 0
            var height: CGFloat = 0
            var opacity: CGFloat = 0
            var force: CGFloat = 0
            for other in left...right {
                let weight = 1 - abs(distanceFromStart[other] - center) / radius
                guard weight > 0 else { continue }
                let sample = points[other]
                weightSum += weight
                x += sample.location.x * weight
                y += sample.location.y * weight
                width += sample.size.width * weight
                height += sample.size.height * weight
                opacity += sample.opacity * weight
                force += sample.force * weight
            }
            guard weightSum > 0 else { return point }
            return copy(
                point,
                location: CGPoint(x: x / weightSum, y: y / weightSum),
                size: CGSize(width: width / weightSum, height: height / weightSum),
                opacity: opacity / weightSum,
                force: force / weightSum
            )
        }
    }

    /// Keeps time, tilt, and ink extras from the original sample. Only the smoothed
    /// position and the pressure-driven width move.
    private static func copy(
        _ point: PKStrokePoint,
        location: CGPoint,
        size: CGSize,
        opacity: CGFloat,
        force: CGFloat
    ) -> PKStrokePoint {
        if #available(iOS 27, *) {
            return PKStrokePoint(
                location: location,
                timeOffset: point.timeOffset,
                size: size,
                opacity: opacity,
                force: force,
                azimuth: point.azimuth,
                altitude: point.altitude,
                secondaryScale: point.secondaryScale,
                threshold: point.threshold,
                lateralJitter: point.lateralJitter
            )
        }
        if #available(iOS 26, *) {
            return PKStrokePoint(
                location: location,
                timeOffset: point.timeOffset,
                size: size,
                opacity: opacity,
                force: force,
                azimuth: point.azimuth,
                altitude: point.altitude,
                secondaryScale: point.secondaryScale,
                threshold: point.threshold
            )
        }
        return PKStrokePoint(
            location: location,
            timeOffset: point.timeOffset,
            size: size,
            opacity: opacity,
            force: force,
            azimuth: point.azimuth,
            altitude: point.altitude,
            secondaryScale: point.secondaryScale
        )
    }
}
