import PencilKit
import SwiftUI
import UIKit
import WebKit

enum FingerSwipe {
    case left
    case right
}

/// Pen ink colors in the bottom bar. Red, blue, and yellow are Figma 55:950.
/// White and black follow them.
enum InkColor: String, CaseIterable {
    case red
    case blue
    case yellow
    case white
    case black

    var color: UIColor {
        switch self {
        case .red: return UIColor(named: "InkRed") ?? .systemRed
        case .blue: return UIColor(named: "InkBlue") ?? .systemBlue
        case .yellow: return UIColor(named: "InkYellow") ?? .systemYellow
        case .white: return .white
        case .black: return .black
        }
    }

    var accessibilityName: String {
        switch self {
        case .red: return "Red"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .white: return "White"
        case .black: return "Black"
        }
    }
}

extension PKDrawing {
    /// Ink in the colors it was drawn with. PencilKit otherwise renders under the
    /// current trait, and this app is dark, so black ink would come out white.
    func literalImage(from rect: CGRect, scale: CGFloat) -> UIImage {
        var rendered = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            rendered = image(from: rect, scale: scale)
        }
        return rendered
    }
}

enum SketchTool: Equatable, CaseIterable {
    case pen
    case eraser
    case voice
    case lasso

    /// Clockwise around the old dial. Kept so angles stay stable for every case.
    static let dialOrder: [SketchTool] = [.pen, .eraser, .voice, .lasso]

    /// Top to bottom on the right-edge slider. Dictation is its own tool.
    static let edgeOrder: [SketchTool] = [.pen, .eraser, .voice, .lasso]

    var nextOnDial: SketchTool {
        let order = Self.edgeOrder
        guard let index = order.firstIndex(of: self) else { return order.first ?? .pen }
        return order[(index + 1) % order.count]
    }

    /// Figma 55:956. `microphone` is newer than the deployment target, so `mic` stands in where it is missing.
    var symbolName: String {
        switch self {
        case .pen: return "pencil.tip"
        case .eraser: return "eraser.fill"
        case .voice: return UIImage(systemName: "microphone") == nil ? "mic" : "microphone"
        case .lasso: return "lasso"
        }
    }

    var accessibilityName: String {
        switch self {
        case .pen: return "Pen"
        case .eraser: return "Eraser"
        case .voice: return "Dictation"
        case .lasso: return "Lasso"
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
        case .eraser: return 3
        case .voice: return 4
        case .lasso: return 5
        }
    }

    init?(rawTag: Int) {
        switch rawTag {
        case 1: self = .pen
        case 3: self = .eraser
        case 4: self = .voice
        case 5: self = .lasso
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

    /// The screen under the ink, plus each voice note in that image's pixel space.
    /// With `wholePage`, an empty page still gives the whole picture, or the canvas on screen.
    func intentSketch(screen: UIImage?, wholePage: Bool = false) -> IntentSketch? {
        overlay?.intentSketch(screen: screen, wholePage: wholePage)
    }

    /// Removes this desktop's pen ink and shapes, and tells the Mac to clear that overlay.
    func clearSketch() {
        overlay?.clearCurrentSketch()
    }

    /// Renders the agent's code and places the image on the desktop the sketch came from.
    /// `onPlaced` runs once the image is on the page.
    func showAgentRender(_ render: AgentRender, placement: AgentPlacement, onPlaced: @escaping () -> Void = {}) {
        overlay?.showAgentRender(render, placement: placement, onPlaced: onPlaced)
    }

    /// Remembers the ink, shapes and voice notes that were just sent, and pulses that ink
    /// while the agent reads it.
    func markSent() {
        overlay?.markSent()
    }

    /// Wipes what the agent read from the page it was drawn on. The agent's images and
    /// anything added after sending stay. `onEmptied` gets that page's id when nothing is left on it.
    func wipeSentInk(onEmptied: @escaping (String) -> Void) {
        overlay?.wipeSentInk(onEmptied: onEmptied)
    }

    /// The agent stopped without answering. The sent ink stays and stops pulsing.
    func cancelSent() {
        overlay?.cancelSent()
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

/// Black pen strokes over the Mac picture. While the Pencil is down, the stroke
/// being drawn has a white glow so it stays visible on the screen. The glow goes
/// away when the Pencil lifts. When the Pencil holds still at the end of
/// a pen stroke, that stroke snaps to a line, circle, square, or clean curve.
/// Each voice note keeps its transcript on screen. Holding still on the dot records, and the text is saved
/// onto that dot. Selecting a stroke or shape, then moving, resizing, or rotating
/// it, is the lasso.
/// The same pen ink is
/// sent to the Mac. Voice notes stay on the iPad with their desktop.
/// A finger on an empty page drives the Mac with the pen or the eraser, and a
/// two-finger pinch there zooms on the Mac.
/// Lasso keeps the finger off the Mac. A Pencil touch never sends pointer input.
struct PencilOverlay: UIViewRepresentable {
    var spaceID: String?
    var canvas: SketchCanvas
    var tool: SketchTool
    var strokeWidth: CGFloat
    var inkColor: UIColor
    /// A faint light edge on every stroke, so dark ink reads on the black canvas.
    var outlinesInk = false
    var acceptsTap: Bool
    /// PencilKit takes a three-finger swipe only while a frozen sketch is on screen.
    var acceptsCanvasSwipe: Bool
    /// A finger drag moves the page. Only the Canvas page pans; a desktop keeps the finger for the Mac.
    var pansPage = false
    var sendsFingerPointer: Bool
    var frameWidth: Int
    var frameHeight: Int
    var onFingerPointer: (PointerPhase, UInt16, UInt16) -> Void
    var onFingerCancel: (UInt16, UInt16) -> Void
    var onInk: (Data, Int, Int, String) -> Void
    var onTap: () -> Void
    var onDoubleTap: () -> Void
    var onFingerSwipe: (FingerSwipe) -> Void
    /// Separation ratio since the last sample. The closing sample is 1.
    var onFingerPinch: (CGFloat, TrackpadScrollPhase) -> Void = { _, _ in }
    var onToggleTool: () -> Void
    var onSketchBegan: () -> Void = {}
    var onSketchAbandoned: (String) -> Void = { _ in }

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
        view.setAcceptsCanvasSwipe(acceptsCanvasSwipe)
        view.onFingerPinch = onFingerPinch
        view.onInkChange = { [weak canvas] hasInk in
            canvas?.noteInk(hasInk)
        }
        view.onInk = onInk
        view.onSketchBegan = onSketchBegan
        view.onSketchAbandoned = onSketchAbandoned
        canvas.attach(view)
        view.setFrameSize(width: frameWidth, height: frameHeight)
        view.setFingerPointer(
            sends: sendsFingerPointer,
            onFinger: onFingerPointer,
            onCancel: onFingerCancel
        )
        view.apply(tool: tool, strokeWidth: strokeWidth, color: inkColor)
        view.setOutlinesInk(outlinesInk)
        view.setPansPage(pansPage)
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
        uiView.onSketchBegan = onSketchBegan
        uiView.onSketchAbandoned = onSketchAbandoned
        canvas.attach(uiView)
        uiView.setFrameSize(width: frameWidth, height: frameHeight)
        uiView.setFingerPointer(
            sends: sendsFingerPointer,
            onFinger: onFingerPointer,
            onCancel: onFingerCancel
        )
        uiView.setAcceptsCanvasSwipe(acceptsCanvasSwipe)
        uiView.onFingerPinch = onFingerPinch
        uiView.apply(tool: tool, strokeWidth: strokeWidth, color: inkColor)
        uiView.setOutlinesInk(outlinesInk)
        uiView.setPansPage(pansPage)
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
        /// A finger tap may also finish while PencilKit is drawing or the canvas pan is active.
        /// The single tap and the double tap stay ordered by `require(toFail:)`.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if gestureRecognizer is ThreeFingerDesktopPan || otherGestureRecognizer is ThreeFingerDesktopPan {
                return true
            }
            let fingerTap = gestureRecognizer is FingerTapRecognizer
            let otherFingerTap = otherGestureRecognizer is FingerTapRecognizer
            if fingerTap && otherFingerTap { return false }
            return fingerTap || otherFingerTap
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, acceptsTap else { return }
            var view = recognizer.view
            while let current = view {
                if let host = current as? PencilOverlayView {
                    let point = recognizer.location(in: host)
                    if host.handleCanvasTap(at: point) {
                        return
                    }
                    break
                }
                view = current.superview
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
        /// A finger drag on the picture drives the Mac. The Pencil draws with the current tool.
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

/// Finger tap on the drawing canvas. PencilKit's drawing gesture prevents a normal
/// tap while that gesture can see the touch, so a double tap never reaches `.ended`
/// and the trackpad stays hidden. These taps finish on their own, including during a
/// pencil stroke. `canPrevent` stays off so `require(toFail:)` can still order the
/// single tap after the double tap.
final class FingerTapRecognizer: UITapGestureRecognizer {
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
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
        delaysTouchesEnded = false
    }
}

/// Holds the page pan back while a Pencil gesture is open, and lets it share two fingers with the pinch.
private final class PagePanGate: NSObject, UIGestureRecognizerDelegate {
    var canBegin: () -> Bool = { true }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        canBegin()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        otherGestureRecognizer is UIPinchGestureRecognizer
    }
}

private final class HaloFrameLink: NSObject {
    weak var owner: PencilOverlayView?

    @objc func tick() {
        owner?.rasterScheduledHalo()
    }
}

final class PencilOverlayView: UIView, PKCanvasViewDelegate {
    private let halo = UIImageView()
    private let canvas = InkCanvasView()
    private var lastPinchScale: CGFloat = 1
    /// The open pinch began while the finger drove the Mac, so its end is sent too.
    private var pinchSendsToMac = false
    private let fingerPinch = UIPinchGestureRecognizer()
    private let pagePan = UIPanGestureRecognizer()
    private let pagePanGate = PagePanGate()
    private var pagePanOpen = false
    /// How far the page has moved since undo was last cleared. Each undo snapshot keeps
    /// the shift it was taken at, so restoring one lands where the page sits now.
    private var pageShift = CGPoint.zero
    var onFingerPinch: (CGFloat, TrackpadScrollPhase) -> Void = { _, _ in }
    private var drawings: [String: PKDrawing] = [:]
    private var currentSpaceID: String?
    private var appliedTool: SketchTool?
    /// Tool width for new pen strokes and snapped shapes. Point size is this plus 2.
    private var strokeWidth: CGFloat = StrokeSettings.defaultWidth
    /// Color for new pen strokes and snapped shapes. Ink already on the page keeps its color.
    private var inkColor: UIColor = InkColor.red.color
    var onInkChange: ((Bool) -> Void)?
    /// PNG of this space's pen ink in captured-frame pixels. Empty data clears the Mac.
    var onInk: (Data, Int, Int, String) -> Void = { _, _, _, _ in }
    /// The current desktop had no ink, and a pen stroke just started.
    var onSketchBegan: () -> Void = {}
    /// That stroke did not leave ink, so the frozen picture for this desktop can go.
    var onSketchAbandoned: (String) -> Void = { _ in }
    var frameWidth = 0
    var frameHeight = 0
    var sendsFingerPointer = false
    var onFingerPointer: (PointerPhase, UInt16, UInt16) -> Void = { _, _, _ in }
    var onFingerCancel: (UInt16, UInt16) -> Void = { _, _ in }
    private var fingerDown = false
    private var fingerPixel: (x: UInt16, y: UInt16)?
    /// Last drawing-space point of an in-progress stroke erase, so a fast drag still covers the gap between touches.
    private var lastEraserPoint: CGPoint?
    /// True from pencil-down to lift while the pen tool is inking. Eraser and finger touches leave this clear.
    private var penStrokeOpen = false
    /// Samples for the pen stroke under the Pencil. A hold corrects this stroke before PencilKit finishes it.
    private var penHoldSamples: [PKStrokePoint] = []
    private var penHoldStart: TimeInterval = 0
    private var penHoldAnchor: CGPoint?
    private var penHoldAnchorIndex = 0
    private var penHoldItem: DispatchWorkItem?
    private var penHoldTouch: UITouch?
    /// The drawing gesture stays off while a hold correction is in place and the Pencil has not lifted.
    private var penHoldSuspended = false
    private var committingPenHold = false
    /// Strokes written by the hold correction. A later commit of the raw stroke is put back to this.
    private var holdLockedStrokes: [PKStroke]?
    private struct ShapeMark {
        let id: UUID
        var shape: FittedShape
        var strokeIndex: Int
        var width: CGFloat
        var color: UIColor
        var opacity: CGFloat
        var force: CGFloat
    }
    private var shapeMarks: [ShapeMark] = []
    private var shapesBySpace: [String: [ShapeMark]] = [:]
    private var selectedShapeID: UUID?
    private enum ShapeAdjust {
        case move(Int, CGPoint)
        case handle(Int, Int)
        case rotate(index: Int, lastAngle: CGFloat, accumulated: CGFloat, original: FittedShape)
    }
    private var shapeAdjust: ShapeAdjust?
    /// A freehand stroke chosen by a tap. Shapes keep `selectedShapeID`. Only one is set.
    private struct StrokePick {
        var index: Int
        var created: Date
        var count: Int
        var anchor: CGPoint
    }
    private var selectedStroke: StrokePick?
    private enum StrokeAdjust {
        case move(Int, CGPoint)
        case resize(Int, CGPoint)
        case rotate(Int, CGPoint)
    }
    private var strokeAdjust: StrokeAdjust?
    private var strokeAdjustPoint = CGPoint.zero
    private var adjustingStroke: PKStroke?
    private var adjustingStrokeIndex = -1
    private var adjustingCenter = CGPoint.zero
    private var adjustingTransform = CGAffineTransform.identity
    private struct PendingStrokeTap {
        var index: Int
        var point: CGPoint
        var time: TimeInterval
        var strokeCount: Int
    }
    /// One settled sketch. Undo restores this instead of PencilKit's stroke stack,
    /// because replacing `canvas.drawing` does not record an undo action.
    private struct SketchUndoSnapshot {
        var drawing: PKDrawing
        var marks: [ShapeMark]
        var selectedShapeID: UUID?
        var images: [AgentImage] = []
        var shift = CGPoint.zero
    }
    /// UndoManager retains its target. This proxy keeps that retain from cycling back to the overlay.
    /// The selector form is required. The closure form of `registerUndo` shares a callback with
    /// PencilKit, which then casts a `PKStrokeProviderSlice` to this proxy and crashes.
    private final class SketchUndoProxy: NSObject {
        weak var owner: PencilOverlayView?
        let snapshot: SketchUndoSnapshot
        init(owner: PencilOverlayView, snapshot: SketchUndoSnapshot) {
            self.owner = owner
            self.snapshot = snapshot
        }
        @objc func apply(_ sender: Any?) {
            owner?.applySketchSnapshot(snapshot)
        }
    }
    private var pendingStrokeTap: PendingStrokeTap?
    /// Set when a tap should drop the dot PencilKit started on the way down.
    /// `strokeCount` is the count before that dot, and it still includes the geometry.
    private var tapDotCleanup: (point: CGPoint, strokeCount: Int)?
    /// A shape touch lifts its stroke only after the Pencil actually drags.
    private var shapeAdjustLifted = false
    private var shapeAdjustAnchor = CGPoint.zero
    /// Stroke count before a shape tap, kept until the Pencil lifts so a late dot can be dropped.
    private var shapeTapBaseline: Int?
    /// Drawing and shape marks from before the drag, so undo can put them back.
    private var shapeDragUndo: SketchUndoSnapshot?
    /// Drawing from before the open pen stroke. Registered once the stroke settles.
    private var gestureUndoSnapshot: SketchUndoSnapshot?
    /// Drawing from before the current erase or lasso drag.
    private var pendingUndoSnapshot: SketchUndoSnapshot?
    private let sketchUndo: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    private var applyingSketchUndo = false
    private var sketchUndoTap: FingerTapRecognizer?
    private var sketchRedoTap: FingerTapRecognizer?
    /// Ink for the stroke lifted out of PencilKit while a shape is being dragged.
    private var adjustingInk: PKInk?
    private var shapePreviewScheduled = false
    private var lassoArmed = false
    private var lassoTransforming = false
    private var lassoSelection: [Int] = []
    private var lassoBox: LassoBox?
    private var lassoLoop: [CGPoint] = []
    private var lassoDrag: LassoDrag?
    private var lassoLifted: [LiftedInk] = []
    private var lassoBaseBox: LassoBox?
    private var lassoLiveTransform = CGAffineTransform.identity
    /// When a pen drag starts on a corrected shape's box, ink begun during that drag is dropped.
    private var boxDragStarted: Date?
    private let shapeHandles = ShapeHandleView()
    private var desktopPan: ThreeFingerDesktopPan?
    private var inkWork: DispatchWorkItem?
    private var inkRenderBusy = false
    private var inkLayoutSize = CGSize.zero
    private var lastSentInk: (png: Data, width: Int, height: Int, spaceID: String)?
    /// Eraser contact is down. The Mac PNG waits for lift.
    private var eraserOpen = false
    /// One glow raster of the open stroke is waiting for the next display refresh.
    private var haloFramePending = false
    private var haloLink: CADisplayLink?
    private var haloBox: HaloFrameLink?
    /// Stroke count when the current pen stroke began. The glow uses only strokes added after this.
    private var liveGlowBaseline = 0
    /// Set while a smoothed stroke is written back, so that write is not smoothed again.
    private var isApplyingSmoothedStroke = false
    /// Voice notes for the desktop on screen, and the notes kept for every other space.
    private var notes: [VoiceNote] = []
    private var notesBySpace: [String: [VoiceNote]] = [:]
    private var openNoteID: UUID?
    /// What the agent was sent, so only that is wiped once it answers.
    private struct SentSketch {
        var spaceID: String?
        var strokes: [PKStroke]
        var markIDs: Set<UUID>
        var noteIDs: Set<UUID>
    }
    private var sent: SentSketch?
    private let readingPulse = UIImageView()
    /// The agent's rendered guesses on this desktop, under the ink.
    private var agentImages: [AgentImage] = []
    private var agentImagesBySpace: [String: [AgentImage]] = [:]
    private let agentImageLayer = AgentImageLayer()
    private var agentRenderers: Set<AgentHTMLRenderer> = []
    private let noteLayer = VoiceNoteLayer()
    private let voicePermissions = VoicePermissionGate()
    private let voiceTranscriber = VoiceTranscriber()
    private var voiceHold: VoiceHold?
    private var voiceHoldItem: DispatchWorkItem?
    /// Pencil went down on a saved dot with the pen. A still hold records onto that dot.
    private var dotDictation: DotDictation?
    /// Canvas point where a still Pencil went down, and the stroke count then.
    /// The count is used to drop the speck once dictation actually starts.
    private var stationaryCanvasAnchor: CGPoint?
    private var stationaryInkBaseline: Int?
    /// While set, new PencilKit strokes from the resting Pencil are removed.
    private var dictationInkBaseline: Int?
    /// Identifies that speck watch so a later stroke is not removed with it.
    private var dictationInkToken: UUID?
    /// A pen tap that can hide the open transcript when the Pencil lifts.
    private var pendingTranscriptDismiss: PendingTranscriptDismiss?
    private var voiceArmed = false
    private var noticeToken = 0
    private let recordHaptic = UIImpactFeedbackGenerator(style: .soft)

    private struct VoiceHold {
        let token: UUID
        let anchor: CGPoint
        /// Pen hold on an existing dot. Releasing after the hold saves the transcript there.
        var targetNoteID: UUID? = nil
        /// Separate voice-tool hold on a saved dot. That path reveals the note and does not record.
        var readingNoteID: UUID? = nil
        /// Pen hold that should record when the Pencil stays in one place.
        var placesNote = false
        var armed = false
        var recording = false
    }

    private struct DotDictation {
        var noteID: UUID
        var anchor: CGPoint
        var strokeCount: Int
    }

    private struct PendingTranscriptDismiss {
        var point: CGPoint
        var time: TimeInterval
    }

    /// Time the Pencil must stay in one place on the dictation tool before recording starts.
    /// Moving farther than `voiceSlop` before then cancels the hold.
    private static let voiceHoldDelay: TimeInterval = 0.25
    private static let voiceSlop: CGFloat = 12
    /// How long the Pencil rests before the stroke under it is corrected.
    private static let penHoldDelay: TimeInterval = 0.4
    /// Resting jitter inside this distance keeps the same hold.
    private static let penHoldSlop: CGFloat = 12
    /// Points past the ink edge that still count as touching a stroke.
    private static let inkHitPadding: CGFloat = 8
    /// Corner, end, and resize handles.
    private static let shapeHandleRadius: CGFloat = 14
    /// Rotate handle. Larger than a corner so it stays easy to grab.
    private static let rotateHandleRadius: CGFloat = 16
    /// Pencil travel that still counts as a tap on a freehand stroke.
    private static let strokeTapSlop: CGFloat = 10
    /// Lift inside this time, and inside the tap slop, selects a freehand stroke.
    private static let strokeTapDuration: TimeInterval = 0.3
    /// How far the freehand rotate handle sits above the selection box.
    private static let rotateHandleGap: CGFloat = 28

    /// Space kept between a centered agent image and the page edge.
    private static let agentImageMargin: CGFloat = 32

    /// Half of the old 32-point bitmap tip. Touching ink deletes that whole stroke.
    private static let eraserRadius: CGFloat = 16
    /// Distance between path samples, in stroke space. Shorter than the tip, so a graze between samples still hits.
    private static let eraserSampleDistance: CGFloat = 2
    /// Live ink while a stroke is down stays under this width so the link is not flooded.
    private static let liveInkMaxWidth = 1280
    private static let liveInkMaxBytes = 400_000
    /// The crop and the whole screen share the stream's frame limit. Base64 on the Mac needs the rest.
    private static let intentByteBudget = 8_000_000
    private static let screenPngBudget = 4_000_000

    var hasInk: Bool {
        !canvas.drawing.strokes.isEmpty
    }

    /// A pen stroke, erase, shape drag, or lasso transform is in progress.
    private var inkGestureOpen: Bool {
        penStrokeOpen || eraserOpen || shapeAdjust != nil || lassoTransforming
    }

    /// The canvas mode is black, so black ink gets a light edge there. Over the Mac
    /// picture, ink stays as drawn.
    func setOutlinesInk(_ outlines: Bool) {
        canvas.layer.shadowOpacity = outlines ? 0.6 : 0
    }

    func setFrameSize(width: Int, height: Int) {
        let sizeChanged = frameWidth != width || frameHeight != height
        frameWidth = width
        frameHeight = height
        if sizeChanged, !inkGestureOpen {
            publishInk(immediate: true)
        }
    }

    func setFingerPointer(
        sends: Bool,
        onFinger: @escaping (PointerPhase, UInt16, UInt16) -> Void,
        onCancel: @escaping (UInt16, UInt16) -> Void
    ) {
        onFingerPointer = onFinger
        onFingerCancel = onCancel
        if sendsFingerPointer && !sends {
            endFingerPointer()
        }
        sendsFingerPointer = sends
    }

    /// PencilKit's three-finger editing swipe stays off unless a frozen sketch is showing.
    /// The desktop pan on the picture handles that swipe the rest of the time.
    func setAcceptsCanvasSwipe(_ accepts: Bool) {
        canvas.acceptsSystemFingerSwipe = accepts
        desktopPan?.isEnabled = !accepts
    }

    /// Pen, eraser, dictation, and lasso follow the Pencil. The Pencil never drives the Mac.
    /// Dictation is the mic tool: a still hold records, and the pen only draws.
    /// A finger on the picture drives the Mac with the pen or the eraser, until the page has ink.
    /// Dictation and lasso keep the finger off the Mac.
    func apply(tool: SketchTool, strokeWidth: CGFloat = StrokeSettings.defaultWidth, color: UIColor = InkColor.red.color) {
        let width = StrokeSettings.clamped(strokeWidth)
        let widthChanged = self.strokeWidth != width || !inkColor.isEqual(color)
        self.strokeWidth = width
        inkColor = color
        let erasing = tool == .eraser
        let annotating = tool == .voice
        let selecting = tool == .lasso
        if tool != .pen, dotDictation != nil || voiceHold?.placesNote == true || voiceHold?.targetNoteID != nil {
            let recording = voiceHold?.recording == true
            pendingTranscriptDismiss = nil
            endVoiceHold(commit: recording)
        }
        canvas.erasesWholeStrokes = erasing
        canvas.capturesVoiceHold = annotating
        canvas.capturesLasso = selecting
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
        if selecting != lassoArmed {
            if !selecting {
                endLassoInteraction(commitLoop: false)
                if tool == .pen {
                    clearLassoSelection()
                }
            }
            lassoArmed = selecting
        } else if tool == .pen {
            clearLassoSelection()
        }
        // The stroke eraser, lasso, and voice hold handle Pencil touches themselves.
        // PencilKit's vector eraser waits until lift, and its bitmap eraser only
        // clears the pixels underneath. The voice tool must not lay down ink.
        if appliedTool != tool || (tool == .pen && widthChanged) {
            appliedTool = tool
            if tool == .pen {
                canvas.tool = PKInkingTool(.monoline, color: color, width: width)
            }
        }
        // Assigning the pen tool resets the drawing gesture's touch types. Put
        // pencil-only back afterwards so a finger is not claimed as a stroke.
        // A claimed finger keeps the double-tap recognizer from ending.
        if erasing || annotating || selecting {
            if shapeAdjust != nil {
                finishShapeAdjust()
            }
            if strokeAdjust != nil {
                finishStrokeAdjust()
            }
            selectedShapeID = nil
            selectedStroke = nil
            pendingStrokeTap = nil
            tapDotCleanup = nil
            holdLockedStrokes = nil
            clearPenHoldTracking()
        }
        let drawing = !erasing && !annotating && !selecting && !penHoldSuspended
        canvas.drawingGestureRecognizer.isEnabled = drawing
        canvas.restrictDrawingToPencil()
        canvas.keepScrollPanOffDesktopSwipe()
        refreshShapeHandles()
        refreshLassoChrome()
    }

    func snapshot() -> UIImage? {
        let strokeBounds = canvas.drawing.bounds
        guard hasInk, strokeBounds.width > 0, strokeBounds.height > 0 else { return nil }
        let scale = max(window?.screen.scale ?? traitCollection.displayScale, 1)
        return canvas.drawing.literalImage(from: strokeBounds.insetBy(dx: -16, dy: -16), scale: scale)
    }

    /// The Mac screen with the ink on top, cropped to the strokes and the voice notes.
    /// Note points are pixels in that image, origin at the top left. With `wholePage`, an
    /// empty page is sent whole: the Mac picture, or the part of the canvas on screen.
    func intentSketch(screen: UIImage?, wholePage: Bool = false) -> IntentSketch? {
        let placed = notes.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let anchors = placed.map { drawingPoint($0.anchor) }
        var rect = canvas.drawing.bounds
        if rect.isNull || rect.isInfinite || rect.width <= 0 || rect.height <= 0 {
            rect = .null
        }
        for anchor in anchors {
            let point = CGRect(origin: anchor, size: .zero)
            rect = rect.isNull ? point : rect.union(point)
        }
        for image in agentImages {
            rect = rect.isNull ? image.frame : rect.union(image.frame)
        }
        // The crop is already the whole page, so the whole-screen image would only repeat it.
        let sendsPage = rect.isNull && wholePage
        if sendsPage {
            rect = pictureDrawingRect() ?? visibleDrawingRect()
        } else {
            guard !rect.isNull, !rect.isInfinite else { return nil }
            rect = rect.insetBy(dx: -16, dy: -16)
        }
        guard rect.width > 1, rect.height > 1 else { return nil }
        let scale = max(window?.screen.scale ?? traitCollection.displayScale, 1)
        // PencilKit draws into the current graphics context. Building the ink image
        // inside the renderer below returns a blank bitmap, so render it first.
        let ink = canvas.drawing.literalImage(from: rect, scale: scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: rect.size))
            drawScreen(screen, into: rect)
            for image in agentImages {
                image.image.draw(in: image.frame.offsetBy(dx: -rect.minX, dy: -rect.minY))
            }
            ink.draw(in: CGRect(origin: .zero, size: rect.size))
        }
        guard let png = image.pngData() else { return nil }
        let mapped = zip(placed, anchors).map { note, anchor in
            IntentNote(
                text: note.text.trimmingCharacters(in: .whitespacesAndNewlines),
                x: Double((anchor.x - rect.minX) * scale),
                y: Double((anchor.y - rect.minY) * scale)
            )
        }
        let whole = sendsPage ? nil : fullScreenImage(screen, room: max(500_000, Self.intentByteBudget - png.count))
        let picture = whole == nil ? nil : pictureDrawingRect()
        return IntentSketch(
            png: png,
            width: Int(image.size.width * image.scale),
            height: Int(image.size.height * image.scale),
            notes: mapped,
            screenPng: whole?.png ?? Data(),
            screenWidth: whole?.width ?? 0,
            screenHeight: whole?.height ?? 0,
            placement: AgentPlacement(
                spaceID: currentSpaceID,
                sketchOrigin: rect.origin,
                sketchPixelsPerPoint: scale,
                screenOrigin: picture?.origin,
                screenPixelsPerPoint: picture.flatMap { picture in
                    whole.map { CGFloat($0.width) / picture.width }
                }
            )
        )
    }

    /// The whole Mac frame with the ink on it. Shrunk until it fits beside the cropped sketch.
    private func fullScreenImage(_ screen: UIImage?, room: Int) -> (png: Data, width: Int, height: Int)? {
        guard let screen, let picture = pictureDrawingRect(), picture.width > 1, picture.height > 1,
              frameWidth > 1, frameHeight > 1 else { return nil }
        var pixelWidth = frameWidth
        let budget = min(Self.screenPngBudget, room)
        for _ in 0..<6 {
            let pixelHeight = max(2, Int((Double(frameHeight) * Double(pixelWidth) / Double(frameWidth)).rounded()))
            let renderScale = max(CGFloat(pixelWidth) / picture.width, 0.5)
            let ink = canvas.drawing.literalImage(from: picture, scale: renderScale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: pixelWidth, height: pixelHeight),
                format: format
            )
            let pixelsPerPoint = CGFloat(pixelWidth) / picture.width
            let image = renderer.image { _ in
                screen.draw(in: CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
                for agentImage in agentImages {
                    let frame = agentImage.frame
                    agentImage.image.draw(in: CGRect(
                        x: (frame.minX - picture.minX) * pixelsPerPoint,
                        y: (frame.minY - picture.minY) * pixelsPerPoint,
                        width: frame.width * pixelsPerPoint,
                        height: frame.height * pixelsPerPoint
                    ))
                }
                ink.draw(in: CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
            }
            guard let png = image.pngData(), !png.isEmpty else { return nil }
            if png.count <= budget || pixelWidth <= 960 { return (png, pixelWidth, pixelHeight) }
            pixelWidth = max(960, pixelWidth / 2)
        }
        return nil
    }

    func markSent() {
        sent = SentSketch(
            spaceID: currentSpaceID,
            strokes: canvas.drawing.strokes,
            markIDs: Set(shapeMarks.map(\.id)),
            noteIDs: Set(notes.map(\.id))
        )
        refreshReadingPulse()
    }

    func cancelSent() {
        sent = nil
        refreshReadingPulse()
    }

    func wipeSentInk(onEmptied: @escaping (String) -> Void) {
        guard let sentSketch = sent else { return }
        // A stroke or drag in progress finishes first, so the wipe never cuts it off.
        if sentSketch.spaceID == currentSpaceID,
           penStrokeOpen || eraserOpen || shapeAdjust != nil || strokeAdjust != nil || lassoTransforming {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.wipeSentInk(onEmptied: onEmptied)
            }
            return
        }
        sent = nil
        refreshReadingPulse()
        if let emptied = wipe(sentSketch) {
            onEmptied(emptied)
        }
    }

    /// Returns the page's id when nothing is left on it.
    private func wipe(_ sentSketch: SentSketch) -> String? {
        func wasRead(_ stroke: PKStroke) -> Bool {
            sentSketch.strokes.contains { sameStrokeGeometry([$0], [stroke]) }
        }
        guard sentSketch.spaceID == currentSpaceID else {
            guard let space = sentSketch.spaceID else { return nil }
            let all = drawings[space]?.strokes ?? []
            let marks = shapesBySpace[space] ?? []
            // A shape moved after sending is still one the agent read.
            let movedShapes = Set(marks.filter { sentSketch.markIDs.contains($0.id) }.map(\.strokeIndex))
            let strokes = all.enumerated().filter { !movedShapes.contains($0.offset) && !wasRead($0.element) }.map(\.element)
            drawings[space] = PKDrawing(strokes: strokes)
            var used = Set<Int>()
            shapesBySpace[space] = marks.compactMap { mark in
                guard !sentSketch.markIDs.contains(mark.id),
                      let index = matchingStrokeIndex(for: mark.shape, in: strokes, excluding: used) else { return nil }
                used.insert(index)
                var rebound = mark
                rebound.strokeIndex = index
                return rebound
            }
            let remainingNotes = (notesBySpace[space] ?? []).filter { !sentSketch.noteIDs.contains($0.id) }
            notesBySpace[space] = remainingNotes
            let empty = strokes.isEmpty && remainingNotes.isEmpty && (agentImagesBySpace[space] ?? []).isEmpty
            return empty ? space : nil
        }
        let before = sketchSnapshot()
        let movedShapes = Set(shapeMarks.filter { sentSketch.markIDs.contains($0.id) }.map(\.strokeIndex))
        let strokes = canvas.drawing.strokes.enumerated()
            .filter { !movedShapes.contains($0.offset) && !wasRead($0.element) }
            .map(\.element)
        let remainingNotes = notes.filter { !sentSketch.noteIDs.contains($0.id) }
        guard strokes.count != before.drawing.strokes.count || remainingNotes.count != notes.count else {
            return nil
        }
        registerSketchUndo(before)
        shapeMarks.removeAll { sentSketch.markIDs.contains($0.id) }
        notes = remainingNotes
        if let openNoteID, !notes.contains(where: { $0.id == openNoteID }) {
            self.openNoteID = nil
        }
        selectedShapeID = nil
        selectedStroke = nil
        holdLockedStrokes = nil
        isApplyingSmoothedStroke = true
        canvas.drawing = PKDrawing(strokes: strokes)
        isApplyingSmoothedStroke = false
        rebindShapes()
        if let currentSpaceID {
            drawings[currentSpaceID] = canvas.drawing
            shapesBySpace[currentSpaceID] = shapeMarks
            notesBySpace[currentSpaceID] = notes
        }
        noteLayer.setSaved(notes: notes, openID: openNoteID)
        canvasViewDrawingDidChange(canvas)
        publishInk(immediate: true)
        let empty = strokes.isEmpty && notes.isEmpty && agentImages.isEmpty
        return empty ? (currentSpaceID ?? "") : nil
    }

    /// A blue glow under the ink the agent is reading, breathing until it answers.
    /// It shows only on the page that ink was sent from.
    private func refreshReadingPulse() {
        readingPulse.layer.removeAnimation(forKey: "pulse")
        guard let sent, sent.spaceID == currentSpaceID, !sent.strokes.isEmpty else {
            readingPulse.isHidden = true
            readingPulse.image = nil
            return
        }
        let drawing = PKDrawing(strokes: sent.strokes)
        let strokeBounds = drawing.bounds
        guard !strokeBounds.isNull, !strokeBounds.isInfinite, strokeBounds.width > 0, strokeBounds.height > 0 else {
            readingPulse.isHidden = true
            return
        }
        let rect = strokeBounds.insetBy(dx: -24, dy: -24)
        let scale = max(window?.screen.scale ?? traitCollection.displayScale, 1)
        let glow = UIColor(named: "AgentBlue") ?? .systemBlue
        let tinted = UIGraphicsImageRenderer(size: rect.size).image { context in
            let ink = drawing.literalImage(from: rect, scale: scale)
            ink.draw(at: .zero)
            glow.setFill()
            context.fill(CGRect(origin: .zero, size: rect.size), blendMode: .sourceIn)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        readingPulse.image = tinted
        readingPulse.frame = rect
        readingPulse.isHidden = false
        CATransaction.commit()
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.15
        pulse.toValue = 0.9
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.isRemovedOnCompletion = false
        readingPulse.layer.add(pulse, forKey: "pulse")
    }

    /// Renders the agent's code at its frame size and places the image under the ink, centered
    /// on the page it targets even when another one is showing. One undo removes it.
    func showAgentRender(_ render: AgentRender, placement: AgentPlacement, onPlaced: @escaping () -> Void) {
        let useScreen = render.space == "screen"
        let origin = (useScreen ? placement.screenOrigin : nil) ?? placement.sketchOrigin
        let perPoint = max((useScreen ? placement.screenPixelsPerPoint : nil) ?? placement.sketchPixelsPerPoint, 0.01)
        let frame = CGRect(
            x: origin.x + CGFloat(render.x) / perPoint,
            y: origin.y + CGFloat(render.y) / perPoint,
            width: CGFloat(render.width) / perPoint,
            height: CGFloat(render.height) / perPoint
        )
        guard frame.width >= 1, frame.height >= 1, frame.width <= 4096, frame.height <= 4096 else { return }
        let shown = centeredFrame(for: frame.size)
        let target = placement.spaceID ?? currentSpaceID
        let renderer = AgentHTMLRenderer()
        agentRenderers.insert(renderer)
        renderer.render(html: render.html, size: frame.size, in: self) { [weak self] image in
            guard let self else { return }
            self.agentRenderers.remove(renderer)
            guard let image else { return }
            self.placeAgentImage(AgentImage(id: UUID(), frame: shown, image: image), spaceID: target)
            onPlaced()
        }
    }

    /// The middle of the page, scaled down to fit inside its margin. It renders at full size first.
    private func centeredFrame(for size: CGSize) -> CGRect {
        let room = bounds.insetBy(dx: Self.agentImageMargin, dy: Self.agentImageMargin)
        guard room.width > 1, room.height > 1 else { return CGRect(origin: .zero, size: size) }
        let fit = min(1, room.width / size.width, room.height / size.height)
        let width = size.width * fit
        let height = size.height * fit
        return CGRect(x: room.midX - width / 2, y: room.midY - height / 2, width: width, height: height)
    }

    private func placeAgentImage(_ image: AgentImage, spaceID target: String?) {
        guard target == currentSpaceID else {
            if let target {
                agentImagesBySpace[target, default: []].append(image)
            }
            return
        }
        registerSketchUndo(sketchSnapshot())
        setAgentImages(agentImages + [image])
    }

    private func setAgentImages(_ images: [AgentImage]) {
        agentImages = images
        if let currentSpaceID {
            agentImagesBySpace[currentSpaceID] = images
        }
        agentImageLayer.show(images)
        reportInk()
    }

    /// Drops the pen ink and fitted shapes on the desktop that is showing.
    func clearCurrentSketch() {
        let undoSnapshot = sketchSnapshot()
        shapeAdjust = nil
        penStrokeOpen = false
        eraserOpen = false
        haloFramePending = false
        inkWork?.cancel()
        inkWork = nil
        adjustingInk = nil
        shapePreviewScheduled = false
        lassoDrag = nil
        lassoLifted = []
        lassoTransforming = false
        lassoBaseBox = nil
        lassoLiveTransform = .identity
        clearLassoSelection()
        shapeHandles.clearInkPreview()
        holdLockedStrokes = nil
        selectedShapeID = nil
        selectedStroke = nil
        strokeAdjust = nil
        adjustingStroke = nil
        pendingStrokeTap = nil
        tapDotCleanup = nil
        dictationInkBaseline = nil
        dictationInkToken = nil
        stationaryInkBaseline = nil
        stationaryCanvasAnchor = nil
        shapeMarks = []
        if let currentSpaceID {
            shapesBySpace[currentSpaceID] = []
            drawings[currentSpaceID] = PKDrawing()
        }
        setAgentImages([])
        gestureUndoSnapshot = nil
        pendingUndoSnapshot = nil
        shapeDragUndo = nil
        if !undoSnapshot.drawing.strokes.isEmpty || !undoSnapshot.marks.isEmpty || !undoSnapshot.images.isEmpty {
            registerSketchUndo(undoSnapshot)
        }
        isApplyingSmoothedStroke = true
        canvas.drawing = PKDrawing()
        isApplyingSmoothedStroke = false
        canvasViewDrawingDidChange(canvas)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        halo.isOpaque = false
        halo.backgroundColor = .clear
        halo.isUserInteractionEnabled = false
        // Top-left keeps a new bounds rect from stretching the previous bitmap.
        // scaleToFill was shearing the halo whenever the stroke bounds changed.
        halo.contentMode = .topLeft
        halo.layer.shadowColor = UIColor.white.cgColor
        halo.layer.shadowOpacity = 1
        halo.layer.shadowRadius = 2.5
        halo.layer.shadowOffset = .zero
        halo.layer.masksToBounds = false
        halo.isHidden = true
        clipsToBounds = true
        agentImageLayer.isUserInteractionEnabled = false
        addSubview(agentImageLayer)
        addSubview(halo)
        readingPulse.isUserInteractionEnabled = false
        readingPulse.isHidden = true
        readingPulse.contentMode = .topLeft
        readingPulse.layer.shadowColor = (UIColor(named: "AgentBlue") ?? .systemBlue).cgColor
        readingPulse.layer.shadowOpacity = 1
        readingPulse.layer.shadowRadius = 8
        readingPulse.layer.shadowOffset = .zero
        addSubview(readingPulse)

        canvas.frame = bounds
        canvas.autoresizingMask = []
        canvas.delegate = self
        // Ink keeps its literal color. PencilKit would otherwise invert black and white in dark mode.
        canvas.overrideUserInterfaceStyle = .light
        canvas.layer.shadowColor = UIColor.white.cgColor
        canvas.layer.shadowOffset = .zero
        canvas.layer.shadowRadius = 1.2
        canvas.layer.shadowOpacity = 0
        addSubview(canvas)
        shapeHandles.frame = bounds
        shapeHandles.autoresizingMask = []
        shapeHandles.isUserInteractionEnabled = false
        addSubview(shapeHandles)
        noteLayer.frame = bounds
        noteLayer.autoresizingMask = []
        noteLayer.isUserInteractionEnabled = false
        addSubview(noteLayer)
        installPinchGesture()
        installPagePan()
        canvas.onFingerPointer = { [weak self] phase, point in
            guard let self else { return }
            self.handleFinger(phase: phase, at: point)
        }
        canvas.onFingerCancel = { [weak self] in
            self?.abortFingerPointer()
        }
        canvas.onPencilErase = { [weak self] phase, samples in
            self?.eraseStrokes(phase: phase, samples: samples)
        }
        canvas.onPencilLasso = { [weak self] phase, samples in
            self?.trackLasso(phase: phase, samples: samples)
        }
        let penHold = PenHoldRecognizer()
        penHold.cancelsTouchesInView = false
        penHold.delaysTouchesBegan = false
        penHold.delaysTouchesEnded = false
        penHold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        penHold.delegate = canvas
        penHold.onSample = { [weak self] phase, touches in
            self?.trackPenHold(phase: phase, touches: touches)
        }
        canvas.addGestureRecognizer(penHold)
        canvas.onPencilVoice = { [weak self] phase, samples in
            guard let self else { return }
            let points = samples
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
        sketchUndo.removeAllActions()
        haloLink?.invalidate()
        haloBox?.owner = nil
        penHoldItem?.cancel()
        inkWork?.cancel()
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

        let doubleTap = FingerTapRecognizer(target: target, action: #selector(PencilOverlay.Coordinator.fingerDoubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.numberOfTouchesRequired = 1
        doubleTap.allowedTouchTypes = finger
        doubleTap.delegate = target
        doubleTap.cancelsTouchesInView = false
        doubleTap.delaysTouchesBegan = false
        doubleTap.delaysTouchesEnded = false

        let tap = FingerTapRecognizer(target: target, action: #selector(PencilOverlay.Coordinator.tapped(_:)))
        tap.numberOfTouchesRequired = 1
        tap.allowedTouchTypes = finger
        tap.delegate = target
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        // The badge toggle waits for this double-tap to fail. The finger's pointer
        // packets follow the touch itself, so the recognizers leave that stream alone.
        tap.require(toFail: doubleTap)
        canvas.addGestureRecognizer(doubleTap)
        canvas.addGestureRecognizer(tap)

        let desktopPan = ThreeFingerDesktopPan(target: target, action: #selector(PencilOverlay.Coordinator.desktopPanned(_:)))
        desktopPan.minimumNumberOfTouches = 3
        desktopPan.maximumNumberOfTouches = 3
        desktopPan.allowedTouchTypes = finger
        desktopPan.delegate = target
        canvas.addGestureRecognizer(desktopPan)
        self.desktopPan = desktopPan

        // UIKit's undo taps live on UIUndoGestureInteraction, which
        // `editingInteractionConfiguration == .none` removes so the three-finger
        // desktop swipe is not also a system undo swipe. These two recognizers
        // are that interaction's tap pair: two fingers undo, three fingers redo.
        // One-finger double-tap stays the trackpad. The Pencil barrel is a
        // UIPencilInteraction, not one of these.
        let undoTap = FingerTapRecognizer(target: self, action: #selector(sketchUndoTapped(_:)))
        undoTap.numberOfTapsRequired = 1
        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = finger
        undoTap.cancelsTouchesInView = false
        undoTap.delaysTouchesBegan = false
        undoTap.delaysTouchesEnded = false
        undoTap.require(toFail: fingerPinch)
        let redoTap = FingerTapRecognizer(target: self, action: #selector(sketchRedoTapped(_:)))
        redoTap.numberOfTapsRequired = 1
        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = finger
        redoTap.cancelsTouchesInView = false
        redoTap.delaysTouchesBegan = false
        redoTap.delaysTouchesEnded = false
        canvas.panGestureRecognizer.require(toFail: undoTap)
        desktopPan.require(toFail: redoTap)
        canvas.addGestureRecognizer(undoTap)
        canvas.addGestureRecognizer(redoTap)
        sketchUndoTap = undoTap
        sketchRedoTap = redoTap

        canvas.restrictDrawingToPencil()
        canvas.keepScrollPanOffDesktopSwipe()
    }

    /// Two-finger tap. This is the undo gesture UIUndoGestureInteraction would
    /// have delivered. A one-finger double-tap never arrives here.
    @objc private func sketchUndoTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        performSketchUndo()
    }

    /// Three-finger tap. Redo follows the system finger-count convention.
    @objc private func sketchRedoTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, sketchUndo.canRedo else { return }
        sketchUndo.redo()
    }

    private func performSketchUndo() {
        guard sketchUndo.canUndo else { return }
        sketchUndo.undo()
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
        if pagePanOpen {
            finishPagePan()
        }
        sketchUndo.removeAllActions()
        pageShift = .zero
        gestureUndoSnapshot = nil
        pendingUndoSnapshot = nil
        shapeDragUndo = nil
        if voiceHold?.recording == true {
            endVoiceHold(commit: true)
        } else if voiceHold != nil {
            endVoiceHold(commit: false)
        }
        if shapeAdjust != nil {
            finishShapeAdjust()
        }
        if strokeAdjust != nil {
            finishStrokeAdjust()
        }
        if eraserOpen {
            finishEraser()
        }
        endLassoInteraction(commitLoop: false)
        clearLassoSelection()
        lastEraserPoint = nil
        penStrokeOpen = false
        haloFramePending = false
        holdLockedStrokes = nil
        clearPenHoldTracking()
        inkWork?.cancel()
        inkWork = nil
        if let currentSpaceID {
            drawings[currentSpaceID] = canvas.drawing
            notesBySpace[currentSpaceID] = notes
            shapesBySpace[currentSpaceID] = shapeMarks
            agentImagesBySpace[currentSpaceID] = agentImages
        }
        let adoptingImages = currentSpaceID == nil && !agentImages.isEmpty
        let adoptingExistingInk = currentSpaceID == nil && !canvas.drawing.strokes.isEmpty
        let adoptingNotes = currentSpaceID == nil && !notes.isEmpty
        let adoptingShapes = currentSpaceID == nil && !shapeMarks.isEmpty
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
        if adoptingShapes {
            shapesBySpace[id] = shapeMarks
        } else {
            shapeMarks = shapesBySpace[id] ?? []
        }
        if adoptingImages {
            agentImagesBySpace[id] = agentImages
        } else {
            agentImages = agentImagesBySpace[id] ?? []
            agentImageLayer.show(agentImages)
        }
        shapeAdjust = nil
        selectedShapeID = nil
        selectedStroke = nil
        pendingStrokeTap = nil
        tapDotCleanup = nil
        dictationInkBaseline = nil
        dictationInkToken = nil
        stationaryInkBaseline = nil
        stationaryCanvasAnchor = nil
        refreshShapeHandles()
        openNoteID = nil
        noticeToken += 1
        noteLayer.setLive(anchor: nil, text: "")
        noteLayer.setNotice(anchor: nil, text: "")
        noteLayer.setSaved(notes: notes, openID: nil)
        publishInk(immediate: true)
        refreshReadingPulse()
    }

    private func placeLayers() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.frame = bounds
        agentImageLayer.frame = bounds
        shapeHandles.frame = bounds
        noteLayer.frame = bounds
        CATransaction.commit()
        noteLayer.relayout()
    }

    private func installPinchGesture() {
        let finger: [NSNumber] = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
        fingerPinch.addTarget(self, action: #selector(handlePinch(_:)))
        fingerPinch.allowedTouchTypes = finger
        fingerPinch.cancelsTouchesInView = false
        fingerPinch.delaysTouchesBegan = false
        fingerPinch.delaysTouchesEnded = false
        addGestureRecognizer(fingerPinch)
    }

    /// The picture does not zoom on the iPad. The pinch is sent to the Mac.
    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            lastPinchScale = pinch.scale
            pinchSendsToMac = sendsFingerPointer
            if pinchSendsToMac {
                onFingerPinch(pinch.scale, .began)
            }
        case .changed:
            let factor = lastPinchScale > 0 ? pinch.scale / lastPinchScale : 1
            lastPinchScale = pinch.scale
            if pinchSendsToMac, abs(factor - 1) > 0.0001 {
                onFingerPinch(factor, .changed)
            }
        case .ended, .cancelled, .failed:
            if pinchSendsToMac {
                onFingerPinch(1, pinch.state == .ended ? .ended : .cancelled)
            }
            pinchSendsToMac = false
        default:
            break
        }
    }

    private func installPagePan() {
        pagePan.addTarget(self, action: #selector(handlePagePan(_:)))
        pagePan.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
        pagePan.minimumNumberOfTouches = 1
        pagePan.maximumNumberOfTouches = 2
        pagePan.cancelsTouchesInView = false
        pagePan.delaysTouchesBegan = false
        pagePan.delaysTouchesEnded = false
        pagePan.isEnabled = false
        pagePanGate.canBegin = { [weak self] in
            guard let self else { return false }
            return !self.inkGestureOpen && self.strokeAdjust == nil && self.voiceHold == nil
        }
        pagePan.delegate = pagePanGate
        addGestureRecognizer(pagePan)
    }

    /// Turning it off mid-drag cancels the drag, which settles the page where it is.
    func setPansPage(_ pans: Bool) {
        guard pagePan.isEnabled != pans else { return }
        pagePan.isEnabled = pans
    }

    /// A finger drag on the Canvas page moves everything on it: ink, shapes, voice notes,
    /// and the agent's images. They keep page coordinates, so they move by the drag.
    @objc private func handlePagePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            endLassoInteraction(commitLoop: false)
            clearLassoSelection()
            selectedStroke = nil
            pendingStrokeTap = nil
            tapDotCleanup = nil
            holdLockedStrokes = nil
            pagePanOpen = true
            pan.setTranslation(.zero, in: self)
        case .changed:
            guard pagePanOpen else { return }
            shiftPage(by: pan.translation(in: self))
            pan.setTranslation(.zero, in: self)
        case .ended, .cancelled, .failed:
            if pagePanOpen {
                finishPagePan()
            }
        default:
            break
        }
    }

    private func shiftPage(by delta: CGPoint) {
        guard delta.x != 0 || delta.y != 0 else { return }
        let move = CGAffineTransform(translationX: delta.x, y: delta.y)
        pageShift.x += delta.x
        pageShift.y += delta.y
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isApplyingSmoothedStroke = true
        canvas.drawing = canvas.drawing.transformed(using: move)
        isApplyingSmoothedStroke = false
        shapeMarks = shapeMarks.map { mark in
            var mark = mark
            mark.shape = mark.shape.applying(move)
            return mark
        }
        notes = notes.map { note in
            var note = note
            note.anchor = note.anchor.applying(move)
            return note
        }
        agentImages = agentImages.map { image in
            var image = image
            image.frame = image.frame.applying(move)
            return image
        }
        if var sentSketch = sent, sentSketch.spaceID == currentSpaceID {
            sentSketch.strokes = PKDrawing(strokes: sentSketch.strokes).transformed(using: move).strokes
            sent = sentSketch
            readingPulse.frame = readingPulse.frame.offsetBy(dx: delta.x, dy: delta.y)
        }
        if let currentSpaceID {
            drawings[currentSpaceID] = canvas.drawing
            shapesBySpace[currentSpaceID] = shapeMarks
            notesBySpace[currentSpaceID] = notes
            agentImagesBySpace[currentSpaceID] = agentImages
        }
        agentImageLayer.show(agentImages)
        noteLayer.setSaved(notes: notes, openID: openNoteID)
        refreshShapeHandles()
        CATransaction.commit()
    }

    private func finishPagePan() {
        pagePanOpen = false
        reportInk()
        publishInk(immediate: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeLayers()
        if bounds.width > 1, bounds.height > 1, bounds.size != inkLayoutSize {
            inkLayoutSize = bounds.size
            if !inkGestureOpen {
                publishInk(immediate: true)
            }
        }
    }

    /// A finger tap on a transcript or its dot stays on the note. Transcripts stay visible.
    func handleCanvasTap(at point: CGPoint) -> Bool {
        switch noteLayer.hit(at: convert(point, to: noteLayer)) {
        case .bubble, .dot:
            return true
        case .none:
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
        let readingNoteID = noteLayer.noteID(at: convert(anchor, to: noteLayer))
        voiceHold = VoiceHold(token: token, anchor: anchor, readingNoteID: readingNoteID)
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
        if hold.placesNote || hold.targetNoteID != nil {
            suppressPenInkForDictation()
        } else if let readingNoteID = hold.readingNoteID {
            openSavedNote(readingNoteID)
            return
        }
        let anchor = hold.anchor
        voicePermissions.authorize { [weak self] result in
            guard let self, self.voiceHold?.token == token else { return }
            switch result {
            case .failure(let reason):
                self.endVoiceHold(commit: false)
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
        voiceTranscriber.onFailure = { [weak self] message in
            guard let self, self.voiceHold?.token == token else { return }
            let point = self.voiceHold?.anchor ?? anchor
            self.endVoiceHold(commit: false)
            self.showVoiceNotice(message, at: point)
        }
        do {
            try voiceTranscriber.start()
        } catch let reason as VoiceCaptureBlock {
            endVoiceHold(commit: false)
            showVoiceNotice(reason.message, at: anchor)
            return
        } catch {
            endVoiceHold(commit: false)
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
        let baseline = dictationInkBaseline
        let anchor = stationaryCanvasAnchor ?? .zero
        let dot = dotDictation
        dotDictation = nil
        stationaryInkBaseline = nil
        if let baseline {
            // Keep the watch until PencilKit commits the speck on lift. Clearing it
            // here lets that dot land after the finger is already up. Capture the
            // token first: dropping the speck can end the tool and clear it.
            let token = dictationInkToken
            tapDotCleanup = (anchor, baseline)
            removeTapDotIfPresent()
            dictationInkBaseline = baseline
            dictationInkToken = token
            stationaryCanvasAnchor = anchor
            tapDotCleanup = (anchor, baseline)
            if !pencilStillDown {
                DispatchQueue.main.async { [weak self] in
                    self?.finishDictationInkWatch(token: token)
                }
            }
        } else if let dot {
            tapDotCleanup = (dot.anchor, dot.strokeCount)
            removeTapDotIfPresent()
            if drawingGestureOpen {
                tapDotCleanup = (dot.anchor, dot.strokeCount)
            }
        }
        resumePenDrawing()
        guard commit, hold.recording, !text.isEmpty else { return }
        if let id = hold.targetNoteID {
            writeVoiceNote(id: id, text: text, anchor: hold.anchor)
        } else {
            addVoiceNote(VoiceNote(id: UUID(), anchor: hold.anchor, text: text))
        }
    }

    /// Saved note under a canvas point, using the dot's 44pt target.
    private func voiceNoteID(at canvasPoint: CGPoint) -> UUID? {
        noteLayer.noteID(at: canvas.convert(canvasPoint, to: noteLayer))
    }

    /// Drops the speck from a Pencil that stayed still, without cancelling that touch.
    /// Disabling PencilKit's drawing gesture here ends the touch, and the cancelled
    /// hold never reaches `startVoiceRecording`.
    private func suppressPenInkForDictation() {
        penHoldItem?.cancel()
        penHoldItem = nil
        pendingStrokeTap = nil
        pendingTranscriptDismiss = nil
        penHoldSuspended = true
        let baseline = stationaryInkBaseline ?? tapDotCleanup?.strokeCount ?? canvas.drawing.strokes.count
        dictationInkToken = UUID()
        dictationInkBaseline = baseline
        tapDotCleanup = (stationaryCanvasAnchor ?? .zero, baseline)
        removeTapDotIfPresent()
        if dictationInkBaseline != nil {
            tapDotCleanup = (stationaryCanvasAnchor ?? .zero, baseline)
        }
    }

    /// True while the Pencil contact that started this hold is still down.
    private var pencilStillDown: Bool {
        switch penHoldTouch?.phase {
        case .began, .moved, .stationary:
            return true
        default:
            return false
        }
    }

    /// True while PencilKit may still commit the stroke for the open touch.
    private var drawingGestureOpen: Bool {
        switch canvas.drawingGestureRecognizer.state {
        case .began, .changed:
            return true
        default:
            return false
        }
    }

    /// Removes a speck PencilKit commits after the finger is up, then stops watching.
    private func finishDictationInkWatch(token: UUID?) {
        guard let token, dictationInkToken == token, voiceHold == nil, !pencilStillDown else { return }
        let anchor = stationaryCanvasAnchor ?? .zero
        let baseline = dictationInkBaseline
        dictationInkBaseline = nil
        dictationInkToken = nil
        stationaryCanvasAnchor = nil
        stationaryInkBaseline = nil
        if let baseline {
            tapDotCleanup = (anchor, baseline)
            removeTapDotIfPresent()
        }
    }

    /// Opens a saved note in the same bubble a finger tap uses. The note stays up after lift.
    private func openSavedNote(_ id: UUID) {
        guard notes.contains(where: { $0.id == id }) else { return }
        openNoteID = id
        noteLayer.setSaved(notes: notes, openID: id)
    }

    private func addVoiceNote(_ note: VoiceNote) {
        notes.append(note)
        if let currentSpaceID {
            notesBySpace[currentSpaceID] = notes
        }
        openNoteID = nil
        noteLayer.setSaved(notes: notes, openID: nil)
    }

    /// Replaces the transcript on an existing dot. An empty recording leaves the saved text alone.
    private func writeVoiceNote(id: UUID, text: String, anchor: CGPoint) {
        if let index = notes.firstIndex(where: { $0.id == id }) {
            notes[index].text = text
        } else {
            notes.append(VoiceNote(id: id, anchor: anchor, text: text))
        }
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

    /// One finger on the picture. A tap clicks, a drag scrolls, and a hold right-clicks.
    /// A point in the letterbox is ignored. Touches on the virtual trackpad never arrive here.
    /// Pencil touches never reach this path.
    private func handleFinger(phase: UITouch.Phase, at point: CGPoint) {
        guard sendsFingerPointer else { return }
        switch phase {
        case .began:
            guard let pixel = pixel(at: point) else { return }
            fingerDown = true
            fingerPixel = pixel
            onFingerPointer(.down, pixel.x, pixel.y)
        case .moved:
            guard fingerDown, let pixel = pixel(at: point) else { return }
            guard fingerPixel?.x != pixel.x || fingerPixel?.y != pixel.y else { return }
            fingerPixel = pixel
            onFingerPointer(.move, pixel.x, pixel.y)
        case .ended, .cancelled:
            if let pixel = pixel(at: point) {
                fingerPixel = pixel
            }
            endFingerPointer()
        default:
            break
        }
    }

    /// Lifts the finger contact, including when finger control turns off
    /// while the finger is still down. Uses the last point that was on the picture.
    private func endFingerPointer() {
        guard fingerDown else { return }
        fingerDown = false
        let pixel = fingerPixel
        fingerPixel = nil
        if let pixel {
            onFingerPointer(.up, pixel.x, pixel.y)
        }
    }

    /// A second finger took over. Button-up cancels the open finger contact on the Mac.
    private func abortFingerPointer() {
        guard fingerDown, let pixel = fingerPixel else {
            fingerDown = false
            fingerPixel = nil
            return
        }
        fingerDown = false
        fingerPixel = nil
        onFingerCancel(pixel.x, pixel.y)
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
        guard !isApplyingSmoothedStroke, shapeAdjust == nil, strokeAdjust == nil, !lassoTransforming else { return }
        let startingSketch = canvasView.drawing.strokes.isEmpty
        holdLockedStrokes = nil
        penStrokeOpen = true
        liveGlowBaseline = canvasView.drawing.strokes.count
        if gestureUndoSnapshot == nil, !applyingSketchUndo {
            gestureUndoSnapshot = sketchSnapshot()
        }
        if startingSketch {
            onSketchBegan()
        }
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard !isApplyingSmoothedStroke else { return }
        let holdActive = voiceHold?.armed == true || voiceHold?.recording == true
        if !holdActive, let baseline = dictationInkBaseline {
            tapDotCleanup = (stationaryCanvasAnchor ?? .zero, baseline)
            dictationInkBaseline = nil
            dictationInkToken = nil
            stationaryCanvasAnchor = nil
            stationaryInkBaseline = nil
        }
        removeTapDotIfPresent()
        if holdActive, let baseline = dictationInkBaseline {
            tapDotCleanup = (stationaryCanvasAnchor ?? .zero, baseline)
        }
        if shapeAdjust != nil || lassoTransforming || strokeAdjust != nil {
            if shapeAdjust != nil || strokeAdjust != nil {
                gestureUndoSnapshot = nil
            }
            penStrokeOpen = false
            return
        }
        penStrokeOpen = false
        halo.isHidden = true
        canvasViewDrawingDidChange(canvasView)
        closeOpenStrokeUndo()
        guard canvasView.drawing.strokes.isEmpty else { return }
        let space = currentSpaceID ?? ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.penStrokeOpen, self.canvas.drawing.strokes.isEmpty else { return }
            guard (self.currentSpaceID ?? "") == space else { return }
            self.onSketchAbandoned(space)
        }
    }

    /// Records the pen stroke under the Pencil. Resting at the end of a moving stroke corrects it.
    /// Transcripts stay visible. Dictation itself is the mic tool.
    /// A drag that starts on empty canvas still draws a new stroke.
    private func trackPenHold(phase: UITouch.Phase, touches: [UITouch]) {
        guard penToolIsDrawing, let touch = touches.last else { return }
        switch phase {
        case .began:
            tapDotCleanup = nil
            pendingTranscriptDismiss = nil
            if voiceHold == nil {
                dictationInkBaseline = nil
                dictationInkToken = nil
            }
            let point = touch.preciseLocation(in: canvas)
            if let adjust = shapeAdjustHit(at: point) {
                penHoldItem?.cancel()
                penHoldSamples = []
                pendingStrokeTap = nil
                pendingTranscriptDismiss = nil
                beginShapeAdjust(adjust, touch: touch)
                return
            }
            pendingStrokeTap = nil
            selectedShapeID = nil
            selectedStroke = nil
            refreshShapeHandles()
            clearPenHoldTracking()
            if openNoteID != nil {
                pendingTranscriptDismiss = PendingTranscriptDismiss(point: point, time: touch.timestamp)
            }
            penHoldTouch = touch
            penHoldStart = touch.timestamp
            penHoldSamples = touches.map { penPoint(from: $0) }
            penHoldAnchor = point
            penHoldAnchorIndex = max(penHoldSamples.count - 1, 0)
            schedulePenHold()
        case .moved:
            if lassoDrag != nil {
                updateLassoTransform(to: touch.preciseLocation(in: canvas))
                return
            }
            if shapeAdjust != nil {
                updateShapeAdjust(to: touch.preciseLocation(in: canvas))
                return
            }
            if strokeAdjust != nil {
                updateStrokeAdjust(to: touch.preciseLocation(in: canvas))
                return
            }
            let point = touch.preciseLocation(in: canvas)
            if let pending = pendingStrokeTap,
               hypot(point.x - pending.point.x, point.y - pending.point.y) > Self.strokeTapSlop {
                pendingStrokeTap = nil
                tapDotCleanup = nil
                selectedStroke = nil
                refreshShapeHandles()
                schedulePenHold()
            }
            if let dismiss = pendingTranscriptDismiss,
               hypot(point.x - dismiss.point.x, point.y - dismiss.point.y) > Self.strokeTapSlop {
                pendingTranscriptDismiss = nil
                tapDotCleanup = nil
            }
            guard !penHoldSuspended else { return }
            penHoldTouch = touch
            penHoldSamples.append(contentsOf: touches.map { penPoint(from: $0) })
            if let anchor = penHoldAnchor, hypot(point.x - anchor.x, point.y - anchor.y) > Self.penHoldSlop {
                penHoldAnchor = point
                penHoldAnchorIndex = max(penHoldSamples.count - 1, 0)
                schedulePenHold()
            }
        case .ended:
            if lassoDrag != nil {
                endLassoInteraction(commitLoop: true)
                clearPenHoldTracking()
                return
            }
            if shapeAdjust != nil {
                let baseline = shapeTapBaseline
                finishShapeAdjust()
                clearPenHoldTracking()
                if let baseline {
                    dropStrokesAdded(after: baseline)
                }
                shapeTapBaseline = nil
                return
            }
            if strokeAdjust != nil {
                finishStrokeAdjust()
                clearPenHoldTracking()
                return
            }
            let point = touch.preciseLocation(in: canvas)
            let down = penHoldAnchor ?? point
            if hypot(point.x - down.x, point.y - down.y) <= Self.strokeTapSlop,
               let noteID = voiceNoteID(at: point) {
                pendingTranscriptDismiss = nil
                openSavedNote(noteID)
                clearPenHoldTracking()
                return
            }
            if let dismiss = pendingTranscriptDismiss {
                pendingTranscriptDismiss = nil
                let moved = hypot(point.x - dismiss.point.x, point.y - dismiss.point.y)
                if moved <= Self.strokeTapSlop {
                    removeTapDotIfPresent()
                } else {
                    tapDotCleanup = nil
                }
            }
            if let pending = pendingStrokeTap {
                pendingStrokeTap = nil
                let moved = hypot(point.x - pending.point.x, point.y - pending.point.y)
                let duration = touch.timestamp - pending.time
                if moved <= Self.strokeTapSlop, duration >= 0, duration <= Self.strokeTapDuration {
                    clearPenHoldTracking()
                    selectFreehandStroke(pending)
                    return
                }
            }
            clearPenHoldTracking()
        case .cancelled:
            if committingPenHold { return }
            if lassoDrag != nil {
                endLassoInteraction(commitLoop: false)
                clearPenHoldTracking()
                return
            }
            pendingTranscriptDismiss = nil
            if shapeAdjust != nil {
                let baseline = shapeTapBaseline
                finishShapeAdjust()
                clearPenHoldTracking()
                if let baseline {
                    dropStrokesAdded(after: baseline)
                }
                shapeTapBaseline = nil
                return
            }
            if strokeAdjust != nil {
                finishStrokeAdjust()
                clearPenHoldTracking()
                return
            }
            pendingStrokeTap = nil
            clearPenHoldTracking()
        default:
            break
        }
    }

    private func schedulePenHold() {
        penHoldItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.commitPenHold()
        }
        penHoldItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.penHoldDelay, execute: work)
    }

    /// Replaces the stroke under a resting Pencil. Lifting later does not correct it again.
    private func commitPenHold() {
        guard !penHoldSuspended, !committingPenHold else { return }
        let prefix = penHoldSamples.prefix(penHoldAnchorIndex + 1)
        let samples = prefix.count >= 3 ? Array(prefix) : penHoldSamples
        guard samples.count >= 3 else { return }
        pendingStrokeTap = nil
        pendingTranscriptDismiss = nil
        tapDotCleanup = nil
        committingPenHold = true
        let countBefore = canvas.drawing.strokes.count
        penHoldSuspended = true
        canvas.drawingGestureRecognizer.isEnabled = false
        committingPenHold = false
        let preSnap = sketchSnapshot()

        var strokes = canvas.drawing.strokes
        let source: [CGPoint]
        if strokes.count > countBefore {
            let stroke = strokes[strokes.count - 1]
            source = (0..<stroke.path.count).map { stroke.path[$0].location }
        } else {
            source = samples.map(\.location)
        }
        if let shape = ShapeFit.fit(source) {
            let corrected = stroke(for: shape, pointSize: StrokeSmoothing.pointSize(forToolWidth: strokeWidth), color: inkColor)
            if strokes.count > countBefore {
                strokes[strokes.count - 1] = corrected
            } else {
                strokes.append(corrected)
            }
            let index = strokes.count - 1
            shapeMarks.removeAll { $0.strokeIndex == index }
            let mark = ShapeMark(
                id: UUID(),
                shape: shape,
                strokeIndex: index,
                width: StrokeSmoothing.pointSize(forToolWidth: strokeWidth),
                color: inkColor,
                opacity: 1,
                force: 1
            )
            shapeMarks.append(mark)
            selectedShapeID = mark.id
        } else if strokes.count > countBefore, let smoothed = StrokeSmoothing.smoothedPenStroke(from: strokes[strokes.count - 1], toolWidth: strokeWidth) {
            strokes[strokes.count - 1] = smoothed
        } else if let smoothed = StrokeSmoothing.smoothedStroke(from: samples, toolWidth: strokeWidth, color: inkColor) {
            strokes.append(smoothed)
        } else {
            resumePenDrawing()
            return
        }
        noteSnapUndo(preSnap)
        holdLockedStrokes = strokes
        penStrokeOpen = false
        isApplyingSmoothedStroke = true
        canvas.drawing = PKDrawing(strokes: strokes)
        isApplyingSmoothedStroke = false
        canvasViewDrawingDidChange(canvas)
        refreshShapeHandles()
        if penHoldTouch?.phase == .ended || penHoldTouch?.phase == .cancelled {
            resumePenDrawing()
        }
    }

    private func clearPenHoldTracking() {
        penHoldItem?.cancel()
        penHoldItem = nil
        penHoldSamples = []
        penHoldAnchor = nil
        penHoldAnchorIndex = 0
        penHoldTouch = nil
        resumePenDrawing()
    }

    private func resumePenDrawing() {
        guard penHoldSuspended else { return }
        penHoldSuspended = false
        let drawing = !canvas.erasesWholeStrokes && !canvas.capturesVoiceHold && !lassoArmed
        // Setting the same value again can still reset PencilKit's recognizer and
        // cancel the Pencil touch that a still hold is waiting on.
        if canvas.drawingGestureRecognizer.isEnabled != drawing {
            canvas.drawingGestureRecognizer.isEnabled = drawing
        }
        canvas.restrictDrawingToPencil()
    }

    /// Keeps the hold correction when PencilKit writes the raw stroke as the sketch finishes.
    private func sketchSnapshot() -> SketchUndoSnapshot {
        SketchUndoSnapshot(
            drawing: canvas.drawing,
            marks: shapeMarks,
            selectedShapeID: selectedShapeID,
            images: agentImages,
            shift: pageShift
        )
    }

    /// The snapshot moved by however far the page has panned since it was taken.
    private func shifted(_ snapshot: SketchUndoSnapshot, to shift: CGPoint) -> SketchUndoSnapshot {
        let dx = shift.x - snapshot.shift.x
        let dy = shift.y - snapshot.shift.y
        guard dx != 0 || dy != 0 else { return snapshot }
        let move = CGAffineTransform(translationX: dx, y: dy)
        var moved = snapshot
        moved.drawing = snapshot.drawing.transformed(using: move)
        moved.marks = snapshot.marks.map { mark in
            var mark = mark
            mark.shape = mark.shape.applying(move)
            return mark
        }
        moved.images = snapshot.images.map { image in
            var image = image
            image.frame = image.frame.applying(move)
            return image
        }
        moved.shift = shift
        return moved
    }

    private func sketchContentDiffers(_ lhs: SketchUndoSnapshot, _ rhs: SketchUndoSnapshot) -> Bool {
        if lhs.marks.count != rhs.marks.count { return true }
        for (old, new) in zip(lhs.marks, rhs.marks) {
            if old.id != new.id || old.shape != new.shape || old.strokeIndex != new.strokeIndex {
                return true
            }
        }
        let before = lhs.drawing.strokes
        let after = rhs.drawing.strokes
        if before.count != after.count { return true }
        return !sameStrokeGeometry(before, after)
    }

    /// Records `snapshot` as the state undo should restore. Each call is its own step.
    /// `registerUndo` throws unless a group is already open. Automatic grouping only
    /// stays open for the current event, and this stack turns that off, so a group is
    /// opened here when none is open. Nothing is registered while undo or redo is
    /// applying a snapshot, and a group is never opened from inside undo or redo.
    private func registerSketchUndo(_ snapshot: SketchUndoSnapshot) {
        guard !applyingSketchUndo, !sketchUndo.isUndoing, !sketchUndo.isRedoing else { return }
        let openedGroup = beginSketchUndoGroupIfNeeded()
        guard sketchUndo.groupingLevel > 0 else { return }
        let proxy = SketchUndoProxy(owner: self, snapshot: snapshot)
        sketchUndo.registerUndo(withTarget: proxy, selector: #selector(SketchUndoProxy.apply(_:)), object: nil)
        sketchUndo.setActionName("Sketch")
        if openedGroup, sketchUndo.groupingLevel > 0 {
            sketchUndo.endUndoGrouping()
        }
    }

    /// Opens a group only when none is open and this call is outside undo/redo.
    /// Returns whether the caller must close it. With `groupsByEvent` on, a level of
    /// zero means the event is already over; the explicit pair keeps that registration
    /// from throwing. If a group still cannot be opened, the caller skips registration.
    private func beginSketchUndoGroupIfNeeded() -> Bool {
        if sketchUndo.groupingLevel > 0 { return false }
        if sketchUndo.isUndoing || sketchUndo.isRedoing { return false }
        sketchUndo.beginUndoGrouping()
        return sketchUndo.groupingLevel > 0
    }

    /// Inverse action recorded while undo or redo applies a snapshot.
    /// That pass already has a group open. Starting another one unbalances it.
    /// When no group is open, skip so `registerUndo` cannot throw.
    private func registerSketchInverse(_ snapshot: SketchUndoSnapshot) {
        guard sketchUndo.groupingLevel > 0 else { return }
        let proxy = SketchUndoProxy(owner: self, snapshot: snapshot)
        sketchUndo.registerUndo(withTarget: proxy, selector: #selector(SketchUndoProxy.apply(_:)), object: nil)
    }

    private func applySketchSnapshot(_ saved: SketchUndoSnapshot) {
        let redo = sketchSnapshot()
        let snapshot = shifted(saved, to: pageShift)
        applyingSketchUndo = true
        gestureUndoSnapshot = nil
        pendingUndoSnapshot = nil
        shapeDragUndo = nil
        shapeTapBaseline = nil
        shapeAdjust = nil
        shapeAdjustLifted = false
        strokeAdjust = nil
        adjustingStroke = nil
        adjustingInk = nil
        tapDotCleanup = nil
        shapeMarks = snapshot.marks
        selectedShapeID = snapshot.selectedShapeID
        selectedStroke = nil
        holdLockedStrokes = snapshot.drawing.strokes
        isApplyingSmoothedStroke = true
        canvas.drawing = snapshot.drawing
        isApplyingSmoothedStroke = false
        applyingSketchUndo = false
        if let currentSpaceID {
            drawings[currentSpaceID] = snapshot.drawing
            shapesBySpace[currentSpaceID] = snapshot.marks
        }
        setAgentImages(snapshot.images)
        registerSketchInverse(redo)
        refreshShapeHandles()
        refreshLassoChrome()
        reportInk()
        applyHaloNow()
        publishInk(immediate: true)
    }

    /// A new pen stroke, once PencilKit has committed it and this overlay has not replaced it.
    private func closeOpenStrokeUndo() {
        guard let snapshot = gestureUndoSnapshot else { return }
        gestureUndoSnapshot = nil
        guard !applyingSketchUndo else { return }
        if sketchContentDiffers(snapshot, sketchSnapshot()) {
            registerSketchUndo(snapshot)
        }
    }

    /// Undo for a hold correction. The open-stroke snapshot, when it differs, is the step before this one.
    private func noteSnapUndo(_ preSnap: SketchUndoSnapshot) {
        if let gesture = gestureUndoSnapshot {
            gestureUndoSnapshot = nil
            if sketchContentDiffers(gesture, preSnap) {
                registerSketchUndo(gesture)
            }
        }
        registerSketchUndo(preSnap)
    }

    private func restoreHoldLockIfNeeded(on canvasView: PKCanvasView) {
        if applyingSketchUndo || sketchUndo.isUndoing || sketchUndo.isRedoing {
            holdLockedStrokes = canvasView.drawing.strokes
            return
        }
        guard let locked = holdLockedStrokes, !isApplyingSmoothedStroke else { return }
        let current = canvasView.drawing.strokes
        if current.count < locked.count {
            holdLockedStrokes = nil
            return
        }
        if sameStrokeGeometry(locked, current) { return }
        isApplyingSmoothedStroke = true
        canvasView.drawing = PKDrawing(strokes: locked)
        isApplyingSmoothedStroke = false
    }

    private func sameStrokeGeometry(_ locked: [PKStroke], _ current: [PKStroke]) -> Bool {
        guard locked.count == current.count else { return false }
        for (left, right) in zip(locked, current) {
            guard left.path.count == right.path.count, left.path.count > 0 else { return false }
            if left.transform != right.transform { return false }
            let indexes = [0, left.path.count / 2, left.path.count - 1]
            for index in indexes {
                let a = left.path[index].location
                let b = right.path[index].location
                if hypot(a.x - b.x, a.y - b.y) > 0.5 { return false }
            }
        }
        return true
    }

    private func penPoint(from touch: UITouch) -> PKStrokePoint {
        let size = StrokeSmoothing.pointSize(forToolWidth: strokeWidth)
        return StrokeSmoothing.point(
            location: touch.preciseLocation(in: canvas),
            timeOffset: max(0, touch.timestamp - penHoldStart),
            size: CGSize(width: size, height: size),
            opacity: 1,
            force: 1,
            azimuth: 0,
            altitude: .pi / 2
        )
    }

    private var penToolIsDrawing: Bool {
        !canvas.erasesWholeStrokes && !canvas.capturesVoiceHold && !lassoArmed
    }

    private func selectedShapeIndex() -> Int? {
        guard let selectedShapeID else { return nil }
        return shapeMarks.firstIndex(where: { $0.id == selectedShapeID })
    }

    private func shapeMarkIndex(for adjust: ShapeAdjust?) -> Int? {
        switch adjust {
        case let .move(index, _):
            return index
        case let .handle(index, _):
            return index
        case let .rotate(index, _, _, _):
            return index
        case nil:
            return nil
        }
    }

    /// Only the selected shape answers, so a stroke drawn near another shape still draws.
    private func shapeAdjustHit(at point: CGPoint) -> ShapeAdjust? {
        guard let selected = selectedShapeIndex(), shapeMarks.indices.contains(selected) else { return nil }
        let mark = shapeMarks[selected]
        let rotateCandidate: (distance: CGFloat, index: Int)? = {
            guard mark.shape.showsRotateHandle else { return nil }
            let handle = mark.shape.rotateHandle
            let distance = hypot(point.x - handle.x, point.y - handle.y)
            return distance <= Self.rotateHandleRadius ? (distance, selected) : nil
        }()
        var handleCandidate: (distance: CGFloat, index: Int, handle: Int)?
        for (handle, location) in mark.shape.handles.enumerated() {
            let distance = hypot(point.x - location.x, point.y - location.y)
            if distance <= Self.shapeHandleRadius, handleCandidate == nil || distance < handleCandidate!.distance {
                handleCandidate = (distance, selected, handle)
            }
        }
        switch (rotateCandidate, handleCandidate) {
        case let (.some(rotate), .some(handle)):
            if rotate.distance <= handle.distance {
                return .rotate(
                    index: rotate.index,
                    lastAngle: 0,
                    accumulated: 0,
                    original: shapeMarks[rotate.index].shape
                )
            }
            return .handle(handle.index, handle.handle)
        case let (.some(rotate), nil):
            return .rotate(
                index: rotate.index,
                lastAngle: 0,
                accumulated: 0,
                original: shapeMarks[rotate.index].shape
            )
        case let (nil, .some(handle)):
            return .handle(handle.index, handle.handle)
        case (nil, nil):
            break
        }
        let allowance = max(0, mark.width) / 2 + Self.inkHitPadding
        if mark.shape.distance(to: point) <= allowance {
            return .move(selected, point)
        }
        return nil
    }

    private func beginShapeAdjust(_ adjust: ShapeAdjust, touch: UITouch) {
        selectedStroke = nil
        pendingStrokeTap = nil
        pendingTranscriptDismiss = nil
        penStrokeOpen = false
        inkWork?.cancel()
        inkWork = nil
        let point = touch.preciseLocation(in: canvas)
        let count = canvas.drawing.strokes.count
        // The baseline still includes this shape. A tap dot is the only stroke past it.
        tapDotCleanup = (point, count)
        shapeTapBaseline = count
        shapeAdjustAnchor = point
        shapeAdjustLifted = false
        shapeDragUndo = nil
        switch adjust {
        case let .rotate(index, _, _, original):
            let center = original.center
            let angle = atan2(point.y - center.y, point.x - center.x)
            shapeAdjust = .rotate(index: index, lastAngle: angle, accumulated: 0, original: original)
        default:
            shapeAdjust = adjust
        }
        let index = shapeMarkIndex(for: shapeAdjust) ?? 0
        if shapeMarks.indices.contains(index) {
            selectedShapeID = shapeMarks[index].id
        }
        refreshShapeHandles()
        penHoldTouch = touch
        committingPenHold = true
        penHoldSuspended = true
        canvas.drawingGestureRecognizer.isEnabled = false
        committingPenHold = false
        guard shapeAdjust != nil else { return }
        dropStrokesAdded(after: count)
    }

    /// Takes the shape's stroke out of PencilKit for the drag. The preview follows the Pencil
    /// without rebuilding the drawing on every move.
    private func liftShapeStroke(at index: Int) {
        guard shapeMarks.indices.contains(index) else { return }
        let strokeIndex = shapeMarks[index].strokeIndex
        var strokes = canvas.drawing.strokes
        guard strokes.indices.contains(strokeIndex) else { return }
        adjustingInk = strokes[strokeIndex].ink
        strokes.remove(at: strokeIndex)
        for other in shapeMarks.indices where other != index && shapeMarks[other].strokeIndex > strokeIndex {
            shapeMarks[other].strokeIndex -= 1
        }
        shapeMarks[index].strokeIndex = -1
        holdLockedStrokes = strokes
        isApplyingSmoothedStroke = true
        canvas.drawing = PKDrawing(strokes: strokes)
        isApplyingSmoothedStroke = false
        reportInk()
        applyHaloNow()
    }

    private func showShapePreview(at index: Int) {
        guard shapeMarks.indices.contains(index) else { return }
        let mark = shapeMarks[index]
        shapeHandles.pendingStrokes = []
        shapeHandles.pendingStroke = stroke(for: mark.shape, pointSize: mark.width, color: mark.color)
        refreshShapeHandles()
        guard !shapePreviewScheduled else { return }
        shapePreviewScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.shapePreviewScheduled = false
            guard self.shapeAdjust != nil else { return }
            self.shapeHandles.renderPendingStroke()
        }
    }

    private func updateShapeAdjust(to point: CGPoint) {
        if !shapeAdjustLifted {
            guard hypot(point.x - shapeAdjustAnchor.x, point.y - shapeAdjustAnchor.y) > Self.strokeTapSlop else { return }
            let index = shapeMarkIndex(for: shapeAdjust) ?? -1
            guard shapeMarks.indices.contains(index), shapeMarks[index].strokeIndex >= 0 else { return }
            shapeDragUndo = sketchSnapshot()
            liftShapeStroke(at: index)
            shapeAdjustLifted = true
        }
        switch shapeAdjust {
        case let .move(index, last):
            guard shapeMarks.indices.contains(index) else { return }
            shapeMarks[index].shape = shapeMarks[index].shape.moved(
                by: CGPoint(x: point.x - last.x, y: point.y - last.y)
            )
            shapeAdjust = .move(index, point)
            showShapePreview(at: index)
        case let .handle(index, handle):
            guard shapeMarks.indices.contains(index) else { return }
            shapeMarks[index].shape = shapeMarks[index].shape.replacingHandle(handle, with: point)
            showShapePreview(at: index)
        case let .rotate(index, lastAngle, accumulated, original):
            guard shapeMarks.indices.contains(index) else { return }
            let center = original.center
            let angle = atan2(point.y - center.y, point.x - center.x)
            var step = angle - lastAngle
            while step > .pi { step -= 2 * .pi }
            while step < -.pi { step += 2 * .pi }
            let turned = accumulated + step
            shapeMarks[index].shape = original.rotated(by: turned)
            shapeAdjust = .rotate(index: index, lastAngle: angle, accumulated: turned, original: original)
            showShapePreview(at: index)
        case nil:
            break
        }
    }

    /// Writes the dragged shape back once. A short tap never lifts the stroke, so the
    /// geometry stays on the canvas and the dashed box comes up around it.
    private func finishShapeAdjust() {
        let lifted = shapeAdjustLifted
        let dragUndo = shapeDragUndo
        tapDotCleanup = nil
        shapeAdjustLifted = false
        shapeDragUndo = nil
        guard let adjust = shapeAdjust else { return }
        let index = shapeMarkIndex(for: adjust) ?? -1
        shapeAdjust = nil
        shapePreviewScheduled = false
        shapeHandles.clearInkPreview()
        guard lifted else {
            adjustingInk = nil
            refreshShapeHandles()
            return
        }
        guard shapeMarks.indices.contains(index) else {
            adjustingInk = nil
            refreshShapeHandles()
            return
        }
        if let dragUndo {
            registerSketchUndo(dragUndo)
        }
        let mark = shapeMarks[index]
        var strokes = canvas.drawing.strokes
        adjustingInk = nil
        strokes.append(stroke(for: mark.shape, pointSize: mark.width, color: mark.color))
        shapeMarks[index].strokeIndex = strokes.count - 1
        holdLockedStrokes = strokes
        isApplyingSmoothedStroke = true
        canvas.drawing = PKDrawing(strokes: strokes)
        isApplyingSmoothedStroke = false
        canvasViewDrawingDidChange(canvas)
        refreshShapeHandles()
    }

    private func rewriteShape(at index: Int) {
        guard shapeMarks.indices.contains(index) else { return }
        let mark = shapeMarks[index]
        var strokes = canvas.drawing.strokes
        guard strokes.indices.contains(mark.strokeIndex) else { return }
        strokes[mark.strokeIndex] = stroke(for: mark.shape, pointSize: mark.width, color: mark.color)
        holdLockedStrokes = strokes
        isApplyingSmoothedStroke = true
        canvas.drawing = PKDrawing(strokes: strokes)
        isApplyingSmoothedStroke = false
        canvasViewDrawingDidChange(canvas)
        refreshShapeHandles()
    }

    /// Fitted line, circle, square, rectangle, and curve. Same monoline the pen draws.
    /// PencilKit stores tool width `W` as point size `W + 2` and paints `2 * (size - 2)`,
    /// so a point size of 4 is half as thick as the freehand stroke.
    private func stroke(for shape: FittedShape, pointSize: CGFloat, color: UIColor) -> PKStroke {
        let size = pointSize
        let points = shape.outline().enumerated().map { index, location in
            StrokeSmoothing.point(
                location: location,
                timeOffset: Double(index) * 0.008,
                size: CGSize(width: size, height: size),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        return PKStroke(
            ink: StrokeSmoothing.ink(pointSize: size, color: color),
            path: PKStrokePath(controlPoints: points, creationDate: Date()),
            transform: .identity,
            mask: nil
        )
    }

    private func rebindShapes() {
        let strokes = canvas.drawing.strokes
        var used = Set<Int>()
        var kept: [ShapeMark] = []
        for var mark in shapeMarks {
            guard let index = matchingStrokeIndex(for: mark.shape, in: strokes, excluding: used) else { continue }
            mark.strokeIndex = index
            used.insert(index)
            kept.append(mark)
        }
        shapeMarks = kept
        if let selectedShapeID, !shapeMarks.contains(where: { $0.id == selectedShapeID }) {
            self.selectedShapeID = nil
        }
        refreshShapeHandles()
    }

    private func matchingStrokeIndex(for shape: FittedShape, in strokes: [PKStroke], excluding used: Set<Int>) -> Int? {
        let outline = shape.outline()
        guard outline.count >= 2 else { return nil }
        let probes = [outline[0], outline[outline.count / 2], outline[outline.count - 1]]
        for index in strokes.indices where !used.contains(index) {
            let samples = renderedSamples(strokes[index], spacing: 6)
            guard samples.count >= 2 else { continue }
            let matched = probes.allSatisfy { probe in
                distance(probe, toPolyline: samples) < 4
            }
            if matched { return index }
        }
        return nil
    }


    /// Corner and rotate chrome for one selected freehand stroke. Empty space inside the box is not a hit.
    private struct SelectionChrome {
        var corners: [CGPoint]
        var rotate: CGPoint
        var anchor: CGPoint
    }

    private func chrome(for bounds: CGRect) -> SelectionChrome {
        SelectionChrome(
            corners: [
                CGPoint(x: bounds.minX, y: bounds.minY),
                CGPoint(x: bounds.maxX, y: bounds.minY),
                CGPoint(x: bounds.maxX, y: bounds.maxY),
                CGPoint(x: bounds.minX, y: bounds.maxY)
            ],
            rotate: CGPoint(x: bounds.midX, y: bounds.minY - Self.rotateHandleGap),
            anchor: CGPoint(x: bounds.midX, y: bounds.minY)
        )
    }

    private func shapeStrokeIndexes() -> Set<Int> {
        Set(shapeMarks.map(\.strokeIndex).filter { $0 >= 0 })
    }

    /// Handles of an already selected freehand stroke. The body is optional so a handle can win.
    private func strokeAdjustHit(at point: CGPoint, body: Bool) -> StrokeAdjust? {
        guard let selectedStroke, strokeAdjust == nil else { return nil }
        let strokes = canvas.drawing.strokes
        guard strokes.indices.contains(selectedStroke.index) else { return nil }
        let stroke = strokes[selectedStroke.index]
        let bounds = stroke.renderBounds
        guard !bounds.isNull, !bounds.isInfinite else { return nil }
        if let hit = chromeHit(in: bounds, at: point) {
            switch hit {
            case .rotate:
                return .rotate(selectedStroke.index, point)
            case .corner:
                return .resize(selectedStroke.index, point)
            }
        }
        if body, strokeContains(stroke, point: point) {
            return .move(selectedStroke.index, point)
        }
        return nil
    }

    private enum StrokeChromeHit {
        case corner
        case rotate
    }

    private func chromeHit(in bounds: CGRect, at point: CGPoint) -> StrokeChromeHit? {
        guard bounds.width < 100_000, bounds.height < 100_000 else { return nil }
        let marks = chrome(for: bounds)
        var best: (CGFloat, StrokeChromeHit)?
        let rotateDistance = hypot(point.x - marks.rotate.x, point.y - marks.rotate.y)
        if rotateDistance <= Self.rotateHandleRadius {
            best = (rotateDistance, .rotate)
        }
        for corner in marks.corners {
            let distance = hypot(point.x - corner.x, point.y - corner.y)
            if distance <= Self.shapeHandleRadius, best == nil || distance < best!.0 {
                best = (distance, .corner)
            }
        }
        return best?.1
    }

    /// Topmost freehand stroke whose ink, not its bounding box, contains `point`.
    private func freehandStrokeIndex(at point: CGPoint) -> Int? {
        let shapes = shapeStrokeIndexes()
        let strokes = canvas.drawing.strokes
        for index in strokes.indices.reversed() where !shapes.contains(index) {
            if strokeContains(strokes[index], point: point) {
                return index
            }
        }
        return nil
    }

    /// Distance to the rendered centerline. The allowance is half the ink width plus a few points.
    private func strokeContains(_ stroke: PKStroke, point: CGPoint) -> Bool {
        let path = stroke.path
        let count = path.count
        guard count > 0 else { return false }
        let bounds = stroke.renderBounds
        guard !bounds.isNull, !bounds.isInfinite else { return false }
        let padding = Self.inkHitPadding
        guard bounds.insetBy(dx: -(padding + 32), dy: -(padding + 32)).contains(point) else { return false }
        let transform = stroke.transform
        let scale = max(hypot(transform.a, transform.c), hypot(transform.b, transform.d))
        let safeScale: CGFloat = scale > 0.001 ? scale : 1
        var best = CGFloat.greatestFiniteMagnitude
        var bestRadius: CGFloat = 0
        var previous: (CGPoint, CGFloat)?

        func consider(_ sample: PKStrokePoint) {
            let location = sample.location.applying(transform)
            let radius = max(sample.size.width, sample.size.height) * safeScale / 2
            if let previous {
                let span = distance(point, toSegmentFrom: previous.0, to: location)
                if span < best {
                    best = span
                    bestRadius = max(previous.1, radius)
                }
            } else {
                best = hypot(point.x - location.x, point.y - location.y)
                bestRadius = radius
            }
            previous = (location, radius)
        }

        if count > 500 {
            for sample in path.interpolatedPoints(by: .distance(4)) {
                consider(sample)
            }
        } else {
            for index in 0..<count {
                consider(path[index])
            }
        }
        return best <= bestRadius + padding
    }

    private func beginStrokeAdjust(_ adjust: StrokeAdjust, touch: UITouch) {
        selectedShapeID = nil
        pendingStrokeTap = nil
        penStrokeOpen = false
        inkWork?.cancel()
        inkWork = nil
        strokeAdjust = adjust
        strokeAdjustPoint = touch.preciseLocation(in: canvas)
        penHoldTouch = touch
        penHoldItem?.cancel()
        penHoldSamples = []
        committingPenHold = true
        penHoldSuspended = true
        let count = canvas.drawing.strokes.count
        tapDotCleanup = (strokeAdjustPoint, count)
        canvas.drawingGestureRecognizer.isEnabled = false
        committingPenHold = false
        if canvas.drawing.strokes.count > count {
            let strokes = Array(canvas.drawing.strokes.prefix(count))
            holdLockedStrokes = strokes
            isApplyingSmoothedStroke = true
            canvas.drawing = PKDrawing(strokes: strokes)
            isApplyingSmoothedStroke = false
        }
        guard liftFreehandStroke(at: strokeIndex(of: adjust)) else {
            strokeAdjust = nil
            penHoldSuspended = false
            removeTapDotIfPresent()
            tapDotCleanup = nil
            canvas.drawingGestureRecognizer.isEnabled = penToolIsDrawing
            canvas.restrictDrawingToPencil()
            refreshShapeHandles()
            return
        }
        showStrokePreview()
        tapDotCleanup = (strokeAdjustPoint, canvas.drawing.strokes.count)
        removeTapDotIfPresent()
    }

    private func strokeIndex(of adjust: StrokeAdjust) -> Int {
        switch adjust {
        case let .move(index, _), let .resize(index, _), let .rotate(index, _):
            return index
        }
    }

    private func liftFreehandStroke(at index: Int) -> Bool {
        var strokes = canvas.drawing.strokes
        guard strokes.indices.contains(index) else { return false }
        let stroke = strokes[index]
        guard stroke.path.count > 0 else { return false }
        adjustingStroke = stroke
        adjustingStrokeIndex = index
        adjustingTransform = stroke.transform
        let bounds = stroke.renderBounds
        if bounds.isNull || bounds.isInfinite {
            adjustingCenter = stroke.path[0].location.applying(stroke.transform)
        } else {
            adjustingCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        strokes.remove(at: index)
        for mark in shapeMarks.indices where shapeMarks[mark].strokeIndex > index {
            shapeMarks[mark].strokeIndex -= 1
        }
        if var pick = selectedStroke {
            pick.index = -1
            selectedStroke = pick
        }
        holdLockedStrokes = strokes
        isApplyingSmoothedStroke = true
        canvas.drawing = PKDrawing(strokes: strokes)
        isApplyingSmoothedStroke = false
        reportInk()
        applyHaloNow()
        return true
    }

    private func showStrokePreview() {
        guard let adjustingStroke, let strokeAdjust else { return }
        let preview = strokeByTransforming(adjustingStroke, adjustedTransform(strokeAdjust, to: strokeAdjustPoint))
        shapeHandles.pendingStrokes = []
        shapeHandles.pendingStroke = preview
        let bounds = preview.renderBounds
        if !bounds.isNull, !bounds.isInfinite {
            applyChrome(chrome(for: bounds))
        }
        guard !shapePreviewScheduled else { return }
        shapePreviewScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.shapePreviewScheduled = false
            guard self.strokeAdjust != nil else { return }
            self.shapeHandles.renderPendingStroke()
        }
    }

    private func updateStrokeAdjust(to point: CGPoint) {
        guard strokeAdjust != nil else { return }
        strokeAdjustPoint = point
        showStrokePreview()
    }

    /// Delta applied on top of the stroke's transform. `strokeByTransforming` concatenates it.
    private func adjustedTransform(_ adjust: StrokeAdjust, to point: CGPoint) -> CGAffineTransform {
        switch adjust {
        case let .move(_, start):
            return CGAffineTransform(translationX: point.x - start.x, y: point.y - start.y)
        case let .resize(_, start):
            let base = max(hypot(start.x - adjustingCenter.x, start.y - adjustingCenter.y), 1)
            let span = hypot(point.x - adjustingCenter.x, point.y - adjustingCenter.y)
            let scale = min(20, max(0.05, span / base))
            return transform(around: adjustingCenter, CGAffineTransform(scaleX: scale, y: scale))
        case let .rotate(_, start):
            let startAngle = atan2(start.y - adjustingCenter.y, start.x - adjustingCenter.x)
            let angle = atan2(point.y - adjustingCenter.y, point.x - adjustingCenter.x)
            return transform(around: adjustingCenter, CGAffineTransform(rotationAngle: angle - startAngle))
        }
    }

    /// Writes the transformed stroke back once. The path's control points stay as they were.
    private func finishStrokeAdjust() {
        guard let adjust = strokeAdjust, let source = adjustingStroke, adjustingStrokeIndex >= 0, source.path.count > 0 else {
            strokeAdjust = nil
            adjustingStroke = nil
            adjustingStrokeIndex = -1
            shapePreviewScheduled = false
            shapeHandles.clearInkPreview()
            refreshShapeHandles()
            return
        }
        let updated = strokeByTransforming(source, adjustedTransform(adjust, to: strokeAdjustPoint))
        let index = adjustingStrokeIndex
        strokeAdjust = nil
        adjustingStroke = nil
        adjustingStrokeIndex = -1
        shapePreviewScheduled = false
        shapeHandles.clearInkPreview()
        var strokes = canvas.drawing.strokes
        let insertAt = min(max(0, index), strokes.count)
        strokes.insert(updated, at: insertAt)
        for mark in shapeMarks.indices where shapeMarks[mark].strokeIndex >= insertAt {
            shapeMarks[mark].strokeIndex += 1
        }
        selectedStroke = StrokePick(
            index: insertAt,
            created: updated.path.creationDate,
            count: updated.path.count,
            anchor: updated.path[0].location
        )
        holdLockedStrokes = strokes
        penStrokeOpen = false
        isApplyingSmoothedStroke = true
        canvas.drawing = PKDrawing(strokes: strokes)
        isApplyingSmoothedStroke = false
        canvasViewDrawingDidChange(canvas)
        refreshShapeHandles()
    }

    private func selectFreehandStroke(_ pending: PendingStrokeTap) {
        tapDotCleanup = (pending.point, pending.strokeCount)
        removeTapDotIfPresent()
        let strokes = canvas.drawing.strokes
        guard strokes.indices.contains(pending.index),
              strokes[pending.index].path.count > 0,
              !shapeStrokeIndexes().contains(pending.index) else {
            selectedStroke = nil
            refreshShapeHandles()
            return
        }
        let stroke = strokes[pending.index]
        selectedShapeID = nil
        selectedStroke = StrokePick(
            index: pending.index,
            created: stroke.path.creationDate,
            count: stroke.path.count,
            anchor: stroke.path[0].location
        )
        refreshShapeHandles()
    }

    /// Drops strokes PencilKit appended after a selection tap. A snapped shape that
    /// was already on the canvas is kept, including when its mark still points at it.
    private func removeTapDotIfPresent() {
        guard let cleanup = tapDotCleanup else { return }
        let point = cleanup.point
        tapDotCleanup = nil
        dropStrokesAdded(after: cleanup.strokeCount)
        // PencilKit can append another dot after recording has already started.
        if let baseline = dictationInkBaseline {
            tapDotCleanup = (stationaryCanvasAnchor ?? point, baseline)
        }
    }

    /// Removes strokes appended after `baseline` without removing a shape's own stroke.
    private func dropStrokesAdded(after baseline: Int) {
        let strokes = canvas.drawing.strokes
        guard strokes.count > baseline else { return }
        let protected = Set(shapeMarks.map(\.strokeIndex).filter { $0 >= 0 })
        var kept: [PKStroke] = []
        var indexMap: [Int: Int] = [:]
        kept.reserveCapacity(strokes.count)
        for index in strokes.indices {
            if index < baseline || protected.contains(index) {
                indexMap[index] = kept.count
                kept.append(strokes[index])
            }
        }
        guard kept.count < strokes.count else { return }
        for mark in shapeMarks.indices {
            let old = shapeMarks[mark].strokeIndex
            if let mapped = indexMap[old] {
                shapeMarks[mark].strokeIndex = mapped
            }
        }
        holdLockedStrokes = kept
        penStrokeOpen = false
        isApplyingSmoothedStroke = true
        canvas.drawing = PKDrawing(strokes: kept)
        isApplyingSmoothedStroke = false
        canvasViewDrawingDidChange(canvas)
    }

    private func resolveStrokeSelection() {
        guard var pick = selectedStroke, strokeAdjust == nil else { return }
        let strokes = canvas.drawing.strokes
        let shapes = shapeStrokeIndexes()
        if strokes.indices.contains(pick.index),
           !shapes.contains(pick.index),
           stroke(strokes[pick.index], matches: pick) {
            return
        }
        if let index = strokes.indices.first(where: { candidate in
            !shapes.contains(candidate) && stroke(strokes[candidate], matches: pick)
        }) {
            pick.index = index
            selectedStroke = pick
            return
        }
        selectedStroke = nil
    }

    private func stroke(_ stroke: PKStroke, matches pick: StrokePick) -> Bool {
        let path = stroke.path
        guard path.count == pick.count, path.count > 0, path.creationDate == pick.created else { return false }
        let location = path[0].location
        return hypot(location.x - pick.anchor.x, location.y - pick.anchor.y) < 0.5
    }

    private func clearFreehandChrome() {
        shapeHandles.selectionCorners = []
        shapeHandles.selectionEdges = []
        shapeHandles.selectionRotate = nil
        shapeHandles.selectionRotateAnchor = nil
    }

    private func applyChrome(_ marks: SelectionChrome) {
        shapeHandles.handles = []
        shapeHandles.rotateHandle = nil
        shapeHandles.rotateAnchor = nil
        shapeHandles.selectionCorners = marks.corners
        shapeHandles.selectionEdges = []
        shapeHandles.selectionRotate = marks.rotate
        shapeHandles.selectionRotateAnchor = marks.anchor
    }

    /// A dashed box around a snapped shape. Squares and rectangles use their own corners
    /// so the border turns with them. Other shapes use the outline's bounds.
    private func dashedBox(for shape: FittedShape) -> [CGPoint] {
        switch shape {
        case .square, .rectangle:
            let corners = shape.handles
            if corners.count == 4 { return corners }
        default:
            break
        }
        var bounds = polygonBounds(shape.outline())
        guard !bounds.isNull, !bounds.isInfinite else { return [] }
        if bounds.width < 12 {
            bounds = bounds.insetBy(dx: -6, dy: 0)
        }
        if bounds.height < 12 {
            bounds = bounds.insetBy(dx: 0, dy: -6)
        }
        bounds = bounds.insetBy(dx: -8, dy: -8)
        return chrome(for: bounds).corners
    }

    private func refreshFreehandChrome() {
        guard strokeAdjust == nil,
              let selectedStroke,
              canvas.drawing.strokes.indices.contains(selectedStroke.index) else {
            if strokeAdjust == nil {
                clearFreehandChrome()
            }
            return
        }
        let bounds = canvas.drawing.strokes[selectedStroke.index].renderBounds
        guard !bounds.isNull, !bounds.isInfinite else {
            clearFreehandChrome()
            return
        }
        applyChrome(chrome(for: bounds))
    }

    private func refreshShapeHandles() {
        if lassoDrag != nil { return }
        guard penToolIsDrawing, strokeAdjust == nil, let selectedShapeID, let mark = shapeMarks.first(where: { $0.id == selectedShapeID }) else {
            if strokeAdjust == nil {
                shapeHandles.handles = []
                shapeHandles.rotateHandle = nil
                shapeHandles.rotateAnchor = nil
            }
            if penToolIsDrawing {
                refreshFreehandChrome()
            } else if !lassoArmed, strokeAdjust == nil {
                clearFreehandChrome()
            }
            return
        }
        // A corrected shape shows its own nodes, not a transform box.
        shapeHandles.selectionCorners = []
        shapeHandles.selectionEdges = []
        shapeHandles.selectionRotate = nil
        shapeHandles.selectionRotateAnchor = nil
        shapeHandles.handles = mark.shape.handles
        shapeHandles.rotateHandle = mark.shape.showsRotateHandle ? mark.shape.rotateHandle : nil
        shapeHandles.rotateAnchor = mark.shape.showsRotateHandle ? mark.shape.rotateAnchor : nil
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        if isApplyingSmoothedStroke {
            return
        }
        if let baseline = dictationInkBaseline {
            tapDotCleanup = (stationaryCanvasAnchor ?? .zero, baseline)
        }
        if tapDotCleanup != nil {
            removeTapDotIfPresent()
        }
        restoreHoldLockIfNeeded(on: canvasView)
        if isApplyingSmoothedStroke {
            return
        }
        if shapeAdjust != nil || lassoTransforming {
            reportInk()
            return
        }
        if penStrokeOpen {
            reportInk()
            scheduleHaloFrame()
            return
        }
        if eraserOpen {
            reportInk()
            if !hasInk {
                applyHaloNow()
                publishInk(immediate: true)
            } else {
                scheduleHaloFrame()
            }
            return
        }
        if strokeAdjust == nil {
            resolveStrokeSelection()
        }
        rebindShapes()
        if let currentSpaceID {
            drawings[currentSpaceID] = canvasView.drawing
        }
        reportInk()
        applyHaloNow()
        publishInk(immediate: true)
    }

    /// White glow under the stroke that is still being drawn. At most one raster per display frame.
    private func scheduleHaloFrame() {
        guard penStrokeOpen else {
            applyHaloNow()
            return
        }
        haloFramePending = true
        if haloLink == nil {
            let box = HaloFrameLink()
            box.owner = self
            haloBox = box
            let link = CADisplayLink(target: box, selector: #selector(HaloFrameLink.tick))
            link.add(to: .main, forMode: .common)
            haloLink = link
        } else {
            haloLink?.isPaused = false
        }
    }

    fileprivate func rasterScheduledHalo() {
        guard haloFramePending else {
            haloLink?.isPaused = true
            return
        }
        haloFramePending = false
        guard penStrokeOpen else {
            haloLink?.isPaused = true
            applyHaloNow()
            return
        }
        showLiveGlow()
        if !haloFramePending {
            haloLink?.isPaused = true
        }
    }

    /// Drops the glow once the stroke has settled.
    private func applyHaloNow() {
        haloFramePending = false
        haloLink?.isPaused = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.isHidden = true
        halo.image = nil
        CATransaction.commit()
    }

    /// Raster of the open stroke, sitting under PencilKit so the white shadow shows around it.
    private func showLiveGlow() {
        let strokes = canvas.drawing.strokes
        guard penStrokeOpen, strokes.count > liveGlowBaseline, let stroke = strokes.last else {
            applyHaloNow()
            return
        }
        let drawing = PKDrawing(strokes: [stroke])
        let strokeBounds = drawing.bounds
        guard !strokeBounds.isNull, !strokeBounds.isInfinite, strokeBounds.width > 0, strokeBounds.height > 0 else {
            applyHaloNow()
            return
        }
        let rect = strokeBounds.insetBy(dx: -12, dy: -12)
        let scale = max(window?.screen.scale ?? traitCollection.displayScale, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.isHidden = false
        halo.image = drawing.literalImage(from: rect, scale: scale)
        halo.frame = rect
        CATransaction.commit()
    }

    private func reportInk() {
        let editing = shapeAdjust != nil || lassoTransforming || !lassoLifted.isEmpty
        onInkChange?(hasInk || editing || !agentImages.isEmpty)
    }

    /// Sends this desktop's pen ink on stroke end, erase end, shape or lasso commit, and clear.
    /// An open pen stroke does not send a full-canvas PNG. A live request, if one is made,
    /// waits a quarter second and does not start while a raster is already running.
    private func publishInk(immediate: Bool) {
        guard frameWidth > 1, frameHeight > 1 else { return }
        if !immediate && penStrokeOpen {
            scheduleThrottledLiveInk()
            return
        }
        inkWork?.cancel()
        inkWork = nil
        renderAndSend(live: false)
    }

    private func scheduleThrottledLiveInk() {
        guard inkWork == nil, !inkRenderBusy else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.inkWork = nil
            guard self.penStrokeOpen, !self.inkRenderBusy else { return }
            self.renderAndSend(live: true)
        }
        inkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func renderAndSend(live: Bool) {
        if live, inkRenderBusy { return }
        inkRenderBusy = true
        defer { inkRenderBusy = false }
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

    /// Draws the frozen Mac frame into the cropped sketch. The frame fills the same
    /// letterboxed rect the ink was drawn on, so a note lands on the screen content under it.
    private func drawScreen(_ screen: UIImage?, into crop: CGRect) {
        guard let screen, let picture = pictureDrawingRect(), picture.width > 1, picture.height > 1 else { return }
        screen.draw(in: CGRect(
            x: picture.minX - crop.minX,
            y: picture.minY - crop.minY,
            width: picture.width,
            height: picture.height
        ))
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

    /// Frame-sized PNG of the ink inside the picture.
    private func rasterize(drawingRect: CGRect, maxPixelWidth: Int) -> (png: Data, width: Int, height: Int)? {
        let pixelWidth = min(frameWidth, max(2, maxPixelWidth))
        let pixelHeight = max(2, Int((Double(frameHeight) * Double(pixelWidth) / Double(frameWidth)).rounded()))
        let renderScale = max(CGFloat(pixelWidth) / drawingRect.width, 0.5)
        let ink = canvas.drawing.literalImage(from: drawingRect, scale: renderScale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: pixelWidth, height: pixelHeight),
            format: format
        )
        let image = renderer.image { _ in
            ink.draw(in: CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
        }
        guard let png = image.pngData(), !png.isEmpty else { return nil }
        return (png, pixelWidth, pixelHeight)
    }

    /// Deletes every stroke and voice note the eraser touches on the way down and while it moves.
    /// A lift is not required.
    private func eraseStrokes(phase: UITouch.Phase, samples: [CGPoint]) {
        guard canvas.erasesWholeStrokes else { return }
        holdLockedStrokes = nil
        let points = samples.map { drawingPoint($0) }
        switch phase {
        case .began:
            guard !points.isEmpty else { return }
            eraserOpen = true
            if pendingUndoSnapshot == nil {
                pendingUndoSnapshot = sketchSnapshot()
            }
            removeTouchedStrokes(along: points)
            eraseAnnotations(at: samples)
            lastEraserPoint = points.last
        case .moved, .ended:
            if points.isEmpty {
                if phase == .ended { finishEraser() }
                return
            }
            eraserOpen = true
            if pendingUndoSnapshot == nil {
                pendingUndoSnapshot = sketchSnapshot()
            }
            var polyline = points
            if let lastEraserPoint {
                polyline.insert(lastEraserPoint, at: 0)
            }
            removeTouchedStrokes(along: polyline)
            var annotationPoints = samples
            if let lastEraserPoint {
                annotationPoints.insert(viewPoint(lastEraserPoint), at: 0)
            }
            eraseAnnotations(at: annotationPoints)
            lastEraserPoint = phase == .ended ? nil : points.last
            if phase == .ended { finishEraser() }
        case .cancelled:
            if eraserOpen {
                finishEraser()
            } else {
                lastEraserPoint = nil
            }
        default:
            break
        }
    }

    /// One halo and one PNG after the eraser lifts, matching the drawing the Pencil left.
    private func finishEraser() {
        eraserOpen = false
        lastEraserPoint = nil
        if let snapshot = pendingUndoSnapshot {
            pendingUndoSnapshot = nil
            if sketchContentDiffers(snapshot, sketchSnapshot()) {
                registerSketchUndo(snapshot)
            }
        }
        haloLink?.isPaused = true
        if let currentSpaceID {
            drawings[currentSpaceID] = canvas.drawing
        }
        if shapeAdjust == nil, !lassoTransforming {
            rebindShapes()
        }
        applyHaloNow()
        publishInk(immediate: true)
        reportInk()
    }

    /// A voice note goes away when the eraser meets its dot or the open transcript.
    /// Samples between touch callbacks are filled in so a fast drag still hits the dot.
    private func eraseAnnotations(at canvasPoints: [CGPoint]) {
        guard !notes.isEmpty, canvasPoints.count > 0 else { return }
        var removed = Set<UUID>()
        var previous = canvasPoints[0]
        for point in canvasPoints {
            let start = canvas.convert(previous, to: noteLayer)
            let end = canvas.convert(point, to: noteLayer)
            let span = hypot(end.x - start.x, end.y - start.y)
            let steps = max(1, Int((span / 12).rounded(.up)))
            for step in 0...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let sample = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                switch noteLayer.hit(at: sample) {
                case .dot(let id):
                    removed.insert(id)
                case .bubble:
                    if let openNoteID {
                        removed.insert(openNoteID)
                    }
                case .none:
                    break
                }
            }
            previous = point
        }
        guard !removed.isEmpty else { return }
        notes.removeAll { removed.contains($0.id) }
        if let openNoteID, removed.contains(openNoteID) {
            self.openNoteID = nil
        }
        if let currentSpaceID {
            notesBySpace[currentSpaceID] = notes
        }
        noteLayer.setSaved(notes: notes, openID: openNoteID)
    }

    private func viewPoint(_ drawingPoint: CGPoint) -> CGPoint {
        let scale = canvas.zoomScale > 0 ? canvas.zoomScale : 1
        return CGPoint(
            x: drawingPoint.x * scale - canvas.contentOffset.x,
            y: drawingPoint.y * scale - canvas.contentOffset.y
        )
    }

    private func removeTouchedStrokes(along polyline: [CGPoint]) {
        let strokes = canvas.drawing.strokes
        guard !strokes.isEmpty else { return }
        var kept: [PKStroke] = []
        var keptIndexes: [Int] = []
        kept.reserveCapacity(strokes.count)
        for (index, stroke) in strokes.enumerated() where !self.stroke(stroke, touches: polyline) {
            kept.append(stroke)
            keptIndexes.append(index)
        }
        guard kept.count != strokes.count else { return }
        if !lassoSelection.isEmpty {
            var mapped: [Int] = []
            for (newIndex, oldIndex) in keptIndexes.enumerated() where lassoSelection.contains(oldIndex) {
                mapped.append(newIndex)
            }
            lassoSelection = mapped
        }
        if var pick = selectedStroke, pick.index >= 0 {
            if let newIndex = keptIndexes.firstIndex(of: pick.index) {
                pick.index = newIndex
                selectedStroke = pick
            } else {
                selectedStroke = nil
            }
        }
        canvas.drawing = PKDrawing(strokes: kept)
        halo.isHidden = true
        canvasViewDrawingDidChange(canvas)
        if !lassoTransforming {
            lassoBox = boxEnclosing(indexes: lassoSelection)
            refreshLassoChrome()
        }
    }

    /// The part of the drawing on screen, in PencilKit drawing coordinates.
    private func visibleDrawingRect() -> CGRect {
        let origin = drawingPoint(.zero)
        let end = drawingPoint(CGPoint(x: bounds.maxX, y: bounds.maxY))
        return CGRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y)
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

private struct LassoBox: Equatable {
    var center: CGPoint
    var halfWidth: CGFloat
    var halfHeight: CGFloat
    var rotation: CGFloat

    enum Edge: CaseIterable {
        case top, right, bottom, left

        var opposite: Edge {
            switch self {
            case .top: return .bottom
            case .right: return .left
            case .bottom: return .top
            case .left: return .right
            }
        }

        /// True when dragging this edge changes the box's width.
        var stretchesWidth: Bool {
            self == .left || self == .right
        }
    }

    var corners: [CGPoint] {
        [
            CGPoint(x: -halfWidth, y: -halfHeight),
            CGPoint(x: halfWidth, y: -halfHeight),
            CGPoint(x: halfWidth, y: halfHeight),
            CGPoint(x: -halfWidth, y: halfHeight)
        ].map { canvasPoint($0) }
    }

    /// Midpoints of the four sides. Dragging one stretches that axis.
    var edgePoints: [CGPoint] {
        Edge.allCases.map { edgePoint($0) }
    }

    func edgePoint(_ edge: Edge) -> CGPoint {
        let local: CGPoint
        switch edge {
        case .top: local = CGPoint(x: 0, y: -halfHeight)
        case .right: local = CGPoint(x: halfWidth, y: 0)
        case .bottom: local = CGPoint(x: 0, y: halfHeight)
        case .left: local = CGPoint(x: -halfWidth, y: 0)
        }
        return canvasPoint(local)
    }

    /// Unit direction from the opposite edge toward `edge`.
    func axis(toward edge: Edge) -> CGPoint {
        switch edge {
        case .right: return ShapeFit.rotate(CGPoint(x: 1, y: 0), by: rotation)
        case .left: return ShapeFit.rotate(CGPoint(x: -1, y: 0), by: rotation)
        case .bottom: return ShapeFit.rotate(CGPoint(x: 0, y: 1), by: rotation)
        case .top: return ShapeFit.rotate(CGPoint(x: 0, y: -1), by: rotation)
        }
    }

    func span(for edge: Edge) -> CGFloat {
        edge.stretchesWidth ? halfWidth * 2 : halfHeight * 2
    }

    private func canvasPoint(_ local: CGPoint) -> CGPoint {
        let turned = ShapeFit.rotate(local, by: rotation)
        return CGPoint(x: center.x + turned.x, y: center.y + turned.y)
    }

    /// Oriented box around a corrected shape, padded so the handles sit just outside the ink.
    static func fitting(_ shape: FittedShape) -> LassoBox {
        let pad: CGFloat = 10
        switch shape {
        case let .square(center, side, rotation):
            let half = side / 2 + pad
            return LassoBox(center: center, halfWidth: half, halfHeight: half, rotation: rotation)
        case let .rectangle(center, width, height, rotation):
            return LassoBox(
                center: center,
                halfWidth: width / 2 + pad,
                halfHeight: height / 2 + pad,
                rotation: rotation
            )
        case let .circle(center, radius, _):
            let half = radius + pad
            return LassoBox(center: center, halfWidth: half, halfHeight: half, rotation: 0)
        case let .line(start, end):
            let center = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let length = hypot(end.x - start.x, end.y - start.y)
            let angle = atan2(end.y - start.y, end.x - start.x)
            return LassoBox(center: center, halfWidth: length / 2 + pad, halfHeight: pad + 8, rotation: angle)
        case .curve:
            let bounds = shape.outline().reduce(CGRect.null) { rect, point in
                rect.union(CGRect(origin: point, size: .zero))
            }
            return enclosing(bounds) ?? LassoBox(center: shape.center, halfWidth: 18, halfHeight: 18, rotation: 0)
        }
    }

    var topAnchor: CGPoint {
        let turned = ShapeFit.rotate(CGPoint(x: 0, y: -halfHeight), by: rotation)
        return CGPoint(x: center.x + turned.x, y: center.y + turned.y)
    }

    var rotateHandle: CGPoint {
        let turned = ShapeFit.rotate(CGPoint(x: 0, y: -halfHeight - 44), by: rotation)
        return CGPoint(x: center.x + turned.x, y: center.y + turned.y)
    }

    func contains(_ point: CGPoint) -> Bool {
        let local = ShapeFit.rotate(
            CGPoint(x: point.x - center.x, y: point.y - center.y),
            by: -rotation
        )
        return abs(local.x) <= halfWidth && abs(local.y) <= halfHeight
    }

    static func enclosing(_ rect: CGRect) -> LassoBox? {
        guard !rect.isNull, !rect.isInfinite, rect.width > 0, rect.height > 0 else { return nil }
        var padded = rect.insetBy(dx: -10, dy: -10)
        if padded.width < 36 {
            let grow = (36 - padded.width) / 2
            padded.origin.x -= grow
            padded.size.width = 36
        }
        if padded.height < 36 {
            let grow = (36 - padded.height) / 2
            padded.origin.y -= grow
            padded.size.height = 36
        }
        return LassoBox(
            center: CGPoint(x: padded.midX, y: padded.midY),
            halfWidth: padded.width / 2,
            halfHeight: padded.height / 2,
            rotation: 0
        )
    }
}

private struct LiftedInk {
    var index: Int
    var stroke: PKStroke
    var shapeID: UUID?
}

private enum LassoDrag {
    case loop
    case move(start: CGPoint)
    case resize(center: CGPoint, startDistance: CGFloat)
    case stretch(LassoBox.Edge)
    case rotate(center: CGPoint, lastAngle: CGFloat, accumulated: CGFloat)
}

private enum LassoBoxHit {
    case body
    case corner
    case edge(LassoBox.Edge)
    case rotate
}

private extension PencilOverlayView {
    func trackLasso(phase: UITouch.Phase, samples: [CGPoint]) {
        guard lassoArmed, let point = samples.last else { return }
        switch phase {
        case .began:
            beginLasso(at: point)
        case .moved:
            updateLasso(to: point, samples: samples)
        case .ended:
            endLassoInteraction(commitLoop: true)
        case .cancelled:
            endLassoInteraction(commitLoop: false)
        default:
            break
        }
    }

    func endLassoInteraction(commitLoop: Bool) {
        switch lassoDrag {
        case .loop:
            let points = lassoLoop
            lassoDrag = nil
            lassoLoop = []
            if commitLoop {
                resolveLassoLoop(points)
            } else {
                refreshLassoChrome()
            }
        case .move, .resize, .stretch, .rotate:
            finishLassoTransform()
        case nil:
            break
        }
    }

    func clearLassoSelection() {
        guard lassoLifted.isEmpty else { return }
        let hadChrome = !lassoSelection.isEmpty || lassoBox != nil || !lassoLoop.isEmpty || lassoDrag != nil
        lassoSelection = []
        lassoBox = nil
        lassoLoop = []
        if case .loop = lassoDrag {
            lassoDrag = nil
        }
        if hadChrome {
            refreshLassoChrome()
        }
    }

    func refreshLassoChrome() {
        guard lassoArmed || lassoDrag != nil else {
            shapeHandles.lassoLoop = []
            if selectedShapeID == nil {
                shapeHandles.selectionCorners = []
                shapeHandles.selectionEdges = []
                shapeHandles.selectionRotate = nil
                shapeHandles.selectionRotateAnchor = nil
            }
            return
        }
        if !lassoTransforming {
            let valid = lassoSelection.filter { canvas.drawing.strokes.indices.contains($0) }
            if valid.count != lassoSelection.count {
                lassoSelection = valid
                lassoBox = boxEnclosing(indexes: valid)
            }
        }
        let drawingLoop: Bool
        if case .loop = lassoDrag {
            drawingLoop = true
        } else {
            drawingLoop = false
        }
        shapeHandles.lassoLoop = drawingLoop ? lassoLoop : []
        if let lassoBox, !drawingLoop {
            shapeHandles.handles = []
            shapeHandles.selectionCorners = lassoBox.corners
            shapeHandles.selectionEdges = lassoBox.edgePoints
            shapeHandles.selectionRotate = lassoBox.rotateHandle
            shapeHandles.selectionRotateAnchor = lassoBox.topAnchor
        } else {
            shapeHandles.selectionCorners = []
            shapeHandles.selectionEdges = []
            shapeHandles.selectionRotate = nil
            shapeHandles.selectionRotateAnchor = nil
        }
    }

    func beginLasso(at point: CGPoint) {
        if let box = lassoBox, !lassoSelection.isEmpty, let hit = lassoBoxHit(at: point, box: box) {
            beginLassoTransform(hit, at: point, box: box)
            return
        }
        lassoDrag = .loop
        lassoLoop = [point]
        refreshLassoChrome()
    }

    func updateLasso(to point: CGPoint, samples: [CGPoint]) {
        switch lassoDrag {
        case .loop:
            for sample in samples {
                if let last = lassoLoop.last, hypot(sample.x - last.x, sample.y - last.y) < 1.5 { continue }
                lassoLoop.append(sample)
            }
            refreshLassoChrome()
        case .move, .resize, .stretch, .rotate:
            updateLassoTransform(to: point)
        case nil:
            break
        }
    }

    func beginLassoTransform(_ hit: LassoBoxHit, at point: CGPoint, box: LassoBox) {
        let snapshot = sketchSnapshot()
        let lifted = liftStrokes(at: lassoSelection)
        guard !lifted.isEmpty else {
            lassoDrag = nil
            return
        }
        pendingUndoSnapshot = snapshot
        lassoLifted = lifted
        lassoBaseBox = box
        lassoLiveTransform = .identity
        lassoBox = box
        switch hit {
        case .body:
            lassoDrag = .move(start: point)
        case .corner:
            let distance = max(hypot(point.x - box.center.x, point.y - box.center.y), 1)
            lassoDrag = .resize(center: box.center, startDistance: distance)
        case let .edge(edge):
            lassoDrag = .stretch(edge)
        case .rotate:
            let angle = atan2(point.y - box.center.y, point.x - box.center.x)
            lassoDrag = .rotate(center: box.center, lastAngle: angle, accumulated: 0)
        }
        showLassoPreview(immediate: true)
        refreshLassoChrome()
    }

    func updateLassoTransform(to point: CGPoint) {
        guard let base = lassoBaseBox else { return }
        switch lassoDrag {
        case let .move(start):
            let dx = point.x - start.x
            let dy = point.y - start.y
            lassoLiveTransform = CGAffineTransform(translationX: dx, y: dy)
            var box = base
            box.center = CGPoint(x: base.center.x + dx, y: base.center.y + dy)
            lassoBox = box
        case let .resize(center, startDistance):
            let distance = hypot(point.x - center.x, point.y - center.y)
            let scale = min(8, max(0.05, distance / max(startDistance, 1)))
            lassoLiveTransform = transform(around: center, CGAffineTransform(scaleX: scale, y: scale))
            var box = base
            box.halfWidth = base.halfWidth * scale
            box.halfHeight = base.halfHeight * scale
            lassoBox = box
        case let .stretch(edge):
            let anchor = base.edgePoint(edge.opposite)
            let axis = base.axis(toward: edge)
            let span = max(base.span(for: edge), 1)
            let projected = (point.x - anchor.x) * axis.x + (point.y - anchor.y) * axis.y
            let scale = min(8, max(0.05, projected / span))
            lassoLiveTransform = scaleAlong(anchor: anchor, axis: axis, factor: scale)
            var box = base
            if edge.stretchesWidth {
                box.halfWidth = span * scale / 2
            } else {
                box.halfHeight = span * scale / 2
            }
            box.center = CGPoint(
                x: anchor.x + axis.x * span * scale / 2,
                y: anchor.y + axis.y * span * scale / 2
            )
            lassoBox = box
        case let .rotate(center, lastAngle, accumulated):
            let angle = atan2(point.y - center.y, point.x - center.x)
            var step = angle - lastAngle
            while step > .pi { step -= 2 * .pi }
            while step < -.pi { step += 2 * .pi }
            let turned = accumulated + step
            lassoDrag = .rotate(center: center, lastAngle: angle, accumulated: turned)
            lassoLiveTransform = transform(around: center, CGAffineTransform(rotationAngle: turned))
            var box = base
            box.rotation = base.rotation + turned
            lassoBox = box
        case .loop, nil:
            return
        }
        showLassoPreview(immediate: false)
        refreshLassoChrome()
    }

    func finishLassoTransform() {
        let lifted = lassoLifted
        let transform = lassoLiveTransform
        lassoDrag = nil
        lassoLifted = []
        lassoBaseBox = nil
        lassoLiveTransform = .identity
        shapePreviewScheduled = false
        shapeHandles.clearInkPreview()
        guard !lifted.isEmpty else {
            lassoTransforming = false
            refreshLassoChrome()
            return
        }
        commitLiftedStrokes(lifted, transform: transform)
        dropStrayBoxInk()
        if !lassoArmed, lassoSelection.count == 1,
           let index = lassoSelection.first,
           let mark = shapeMarks.first(where: { $0.strokeIndex == index }) {
            selectedShapeID = mark.id
        }
        refreshLassoChrome()
        refreshShapeHandles()
    }

    /// Drops a pen speck laid down while a transform box was dragged.
    private func dropStrayBoxInk() {
        guard let started = boxDragStarted else { return }
        boxDragStarted = nil
        let keep = Set(lassoSelection)
        let strokes = canvas.drawing.strokes
        var kept: [PKStroke] = []
        var map: [Int: Int] = [:]
        for (index, stroke) in strokes.enumerated() {
            let stray = !keep.contains(index) && stroke.path.creationDate >= started.addingTimeInterval(-0.05)
            if stray { continue }
            map[index] = kept.count
            kept.append(stroke)
        }
        guard kept.count != strokes.count else { return }
        for mark in shapeMarks.indices {
            shapeMarks[mark].strokeIndex = map[shapeMarks[mark].strokeIndex] ?? -1
        }
        lassoSelection = lassoSelection.compactMap { map[$0] }
        holdLockedStrokes = nil
        isApplyingSmoothedStroke = true
        canvas.drawing = PKDrawing(strokes: kept)
        isApplyingSmoothedStroke = false
    }

    func showLassoPreview(immediate: Bool) {
        if immediate {
            shapeHandles.pendingStroke = nil
            shapeHandles.pendingStrokes = lassoLifted.map { strokeByTransforming($0.stroke, lassoLiveTransform) }
            shapeHandles.renderPendingStroke()
            return
        }
        guard !shapePreviewScheduled else { return }
        shapePreviewScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.shapePreviewScheduled = false
            guard !self.lassoLifted.isEmpty else { return }
            self.shapeHandles.pendingStroke = nil
            self.shapeHandles.pendingStrokes = self.lassoLifted.map {
                self.strokeByTransforming($0.stroke, self.lassoLiveTransform)
            }
            self.shapeHandles.renderPendingStroke()
        }
    }

    func resolveLassoLoop(_ points: [CGPoint]) {
        defer { refreshLassoChrome() }
        guard let point = points.last else {
            lassoSelection = []
            lassoBox = nil
            return
        }
        if points.count < 3 || lassoLoopIsTap(points) {
            selectStroke(at: point)
            return
        }
        var selected: [Int] = []
        let strokes = canvas.drawing.strokes
        for index in strokes.indices where stroke(strokes[index], isCaughtBy: points) {
            selected.append(index)
        }
        lassoSelection = selected
        lassoBox = boxEnclosing(indexes: selected)
    }

    /// A tap with the lasso selects one freehand stroke or snapped shape. The box then moves, resizes, and rotates it.
    func selectStroke(at point: CGPoint) {
        let strokes = canvas.drawing.strokes
        for index in strokes.indices.reversed() where stroke(strokes[index], containsTap: point) {
            lassoSelection = [index]
            lassoBox = boxEnclosing(indexes: [index])
            return
        }
        lassoSelection = []
        lassoBox = nil
    }

    func liftStrokes(at indexes: [Int]) -> [LiftedInk] {
        let ordered = Array(Set(indexes)).sorted()
        var strokes = canvas.drawing.strokes
        var lifted: [LiftedInk] = []
        lassoTransforming = true
        for index in ordered.reversed() {
            guard strokes.indices.contains(index) else { continue }
            let stroke = strokes.remove(at: index)
            let shapeID = shapeMarks.first(where: { $0.strokeIndex == index })?.id
            lifted.append(LiftedInk(index: index, stroke: stroke, shapeID: shapeID))
            for mark in shapeMarks.indices {
                if shapeMarks[mark].strokeIndex == index {
                    shapeMarks[mark].strokeIndex = -1
                } else if shapeMarks[mark].strokeIndex > index {
                    shapeMarks[mark].strokeIndex -= 1
                }
            }
        }
        lifted.reverse()
        guard !lifted.isEmpty else {
            lassoTransforming = false
            return []
        }
        holdLockedStrokes = nil
        isApplyingSmoothedStroke = true
        canvas.drawing = PKDrawing(strokes: strokes)
        isApplyingSmoothedStroke = false
        reportInk()
        applyHaloNow()
        return lifted
    }

    func commitLiftedStrokes(_ lifted: [LiftedInk], transform: CGAffineTransform) {
        if let snapshot = pendingUndoSnapshot {
            pendingUndoSnapshot = nil
            registerSketchUndo(snapshot)
        }
        var strokes = canvas.drawing.strokes
        var selection: [Int] = []
        let scale = max(hypot(transform.a, transform.c), 0.001)
        for item in lifted {
            let index = min(max(item.index, 0), strokes.count)
            strokes.insert(strokeByTransforming(item.stroke, transform), at: index)
            selection.append(index)
            for mark in shapeMarks.indices where shapeMarks[mark].strokeIndex >= index {
                shapeMarks[mark].strokeIndex += 1
            }
            if let shapeID = item.shapeID, let markIndex = shapeMarks.firstIndex(where: { $0.id == shapeID }) {
                shapeMarks[markIndex].shape = shapeMarks[markIndex].shape.applying(transform)
                shapeMarks[markIndex].width = max(1, shapeMarks[markIndex].width * scale)
                shapeMarks[markIndex].strokeIndex = index
            }
        }
        lassoSelection = selection
        lassoTransforming = false
        holdLockedStrokes = nil
        isApplyingSmoothedStroke = true
        canvas.drawing = PKDrawing(strokes: strokes)
        isApplyingSmoothedStroke = false
        canvasViewDrawingDidChange(canvas)
        lassoBox = boxEnclosing(indexes: lassoSelection)
    }

    func boxEnclosing(indexes: [Int]) -> LassoBox? {
        var rect = CGRect.null
        let strokes = canvas.drawing.strokes
        for index in indexes where strokes.indices.contains(index) {
            let bounds = strokes[index].renderBounds
            guard !bounds.isNull, !bounds.isInfinite, bounds.width > 0 || bounds.height > 0 else { continue }
            rect = rect.union(bounds)
        }
        return LassoBox.enclosing(rect)
    }

    func lassoBoxHit(at point: CGPoint, box: LassoBox) -> LassoBoxHit? {
        let rotateDistance = hypot(point.x - box.rotateHandle.x, point.y - box.rotateHandle.y)
        var cornerDistance = CGFloat.greatestFiniteMagnitude
        for corner in box.corners {
            cornerDistance = min(cornerDistance, hypot(point.x - corner.x, point.y - corner.y))
        }
        var edgeDistance = CGFloat.greatestFiniteMagnitude
        var edge: LassoBox.Edge?
        for candidate in LassoBox.Edge.allCases {
            let distance = hypot(point.x - box.edgePoint(candidate).x, point.y - box.edgePoint(candidate).y)
            if distance < edgeDistance {
                edgeDistance = distance
                edge = candidate
            }
        }
        let rotateHit = rotateDistance <= 26
        let cornerHit = cornerDistance <= 24
        let edgeHit = edgeDistance <= 24
        if rotateHit, !cornerHit || rotateDistance <= cornerDistance, !edgeHit || rotateDistance <= edgeDistance {
            return .rotate
        }
        if cornerHit, !edgeHit || cornerDistance <= edgeDistance {
            return .corner
        }
        if edgeHit, let edge {
            return .edge(edge)
        }
        if box.contains(point) { return .body }
        return nil
    }

    func lassoLoopIsTap(_ points: [CGPoint]) -> Bool {
        guard let first = points.first else { return true }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        var length: CGFloat = 0
        for index in 1..<points.count {
            let point = points[index]
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
            let previous = points[index - 1]
            length += hypot(point.x - previous.x, point.y - previous.y)
        }
        return (maxX - minX < 14 && maxY - minY < 14) || length < 18
    }

    func stroke(_ stroke: PKStroke, containsTap point: CGPoint) -> Bool {
        let samples = renderedSamples(stroke, spacing: 8)
        guard !samples.isEmpty else { return false }
        let centerline = distance(point, toPolyline: samples)
        let scale = max(hypot(stroke.transform.a, stroke.transform.c), 1)
        let width = stroke.path.count > 0 ? stroke.path[0].size.width * scale : 4
        return centerline <= width / 2 + 14
    }

    func stroke(_ stroke: PKStroke, isCaughtBy polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        let bounds = stroke.renderBounds
        guard bounds.intersects(polygonBounds(polygon).insetBy(dx: -24, dy: -24)) else { return false }
        if rectIsInside(bounds, polygon: polygon) { return true }
        let samples = renderedSamples(stroke, spacing: 8)
        if samples.contains(where: { pointInPolygon($0, polygon: polygon) }) { return true }
        guard samples.count >= 2 else { return false }
        for index in 1..<samples.count where segmentCrossesPolygon(samples[index - 1], samples[index], polygon: polygon) {
            return true
        }
        return false
    }

    func renderedSamples(_ stroke: PKStroke, spacing: CGFloat) -> [CGPoint] {
        let path = stroke.path
        guard path.count > 0 else { return [] }
        let transform = stroke.transform
        var points = [path.interpolatedPoint(at: 0).location.applying(transform)]
        let end = CGFloat(path.count - 1)
        guard end > 0 else { return points }
        for sample in path.interpolatedPoints(by: .distance(max(spacing, 0.5))) {
            points.append(sample.location.applying(transform))
        }
        points.append(path.interpolatedPoint(at: end).location.applying(transform))
        return points
    }

    /// `extra` is in canvas space. `concatenating` applies the receiver first, so the
    /// stroke's own transform runs before the move, scale, or turn.
    func strokeByTransforming(_ stroke: PKStroke, _ extra: CGAffineTransform) -> PKStroke {
        PKStroke(
            ink: stroke.ink,
            path: stroke.path,
            transform: stroke.transform.concatenating(extra),
            mask: stroke.mask,
            randomSeed: stroke.randomSeed
        )
    }

    /// Scales or turns around `center` in canvas space. `concatenating` applies the
    /// receiver first, so the center is moved to the origin, changed, then moved back.
    /// `translatedBy` applies its offset first and would cancel this back to the canvas origin.
    func transform(around center: CGPoint, _ change: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(change)
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }

    /// Scales along `axis` around `anchor` and leaves the perpendicular axis alone.
    /// `concatenating` applies the receiver first.
    func scaleAlong(anchor: CGPoint, axis: CGPoint, factor: CGFloat) -> CGAffineTransform {
        let angle = atan2(axis.y, axis.x)
        return CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            .concatenating(CGAffineTransform(rotationAngle: -angle))
            .concatenating(CGAffineTransform(scaleX: factor, y: 1))
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
    }

    func polygonBounds(_ polygon: [CGPoint]) -> CGRect {
        guard let first = polygon.first else { return .null }
        var rect = CGRect(origin: first, size: .zero)
        for point in polygon.dropFirst() {
            rect = rect.union(CGRect(origin: point, size: .zero))
        }
        return rect
    }

    func rectIsInside(_ rect: CGRect, polygon: [CGPoint]) -> Bool {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
        return corners.allSatisfy { pointInPolygon($0, polygon: polygon) }
    }

    func pointInPolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            let crosses = (current.y > point.y) != (previous.y > point.y)
            if crosses, previous.y != current.y {
                let x = (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x
                if point.x < x { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    func segmentCrossesPolygon(_ start: CGPoint, _ end: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 2 else { return false }
        for index in polygon.indices {
            let edgeStart = polygon[index]
            let edgeEnd = polygon[(index + 1) % polygon.count]
            if segmentsIntersect(start, end, edgeStart, edgeEnd) { return true }
        }
        return false
    }

    func segmentsIntersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func cross(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        let ab = cross(a, b, c) * cross(a, b, d)
        let cd = cross(c, d, a) * cross(c, d, b)
        return ab <= 0 && cd <= 0
    }
}

/// Follows the Pencil for the whole stroke, including while PencilKit is drawing it.
private final class PenHoldRecognizer: UIGestureRecognizer {
    var onSample: ((UITouch.Phase, [UITouch]) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let pencil = touches.first(where: { $0.type == .pencil }) else { return }
        state = .began
        onSample?(.began, event.coalescedTouches(for: pencil) ?? [pencil])
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed else { return }
        guard let pencil = touches.first(where: { $0.type == .pencil }) else { return }
        state = .changed
        onSample?(.moved, event.coalescedTouches(for: pencil) ?? [pencil])
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let pencil = touches.first(where: { $0.type == .pencil }) else {
            state = .failed
            return
        }
        onSample?(.ended, event.coalescedTouches(for: pencil) ?? [pencil])
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        let pencil = touches.first(where: { $0.type == .pencil })
        let samples = pencil.flatMap { event.coalescedTouches(for: $0) } ?? pencil.map { [$0] } ?? []
        onSample?(.cancelled, samples)
        state = .cancelled
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// PencilKit canvas. Finger gestures are attached here. The Pencil draws.
/// A finger on the picture is reported so it can drive the Mac. A Pencil touch is not.
final class InkCanvasView: PKCanvasView, UIGestureRecognizerDelegate {
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
        tool = PKInkingTool(.monoline, color: .black, width: StrokeSettings.defaultWidth)
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        keepScrollPanOffDesktopSwipe()
    }

    /// When set, a Pencil touch deletes each stroke it meets. A finger is reported on its own path.
    var erasesWholeStrokes = false
    var onPencilErase: ((UITouch.Phase, [CGPoint]) -> Void)?
    /// When set, a Pencil hold can record a voice note. A finger is reported on its own path.
    var capturesVoiceHold = false
    var onPencilVoice: ((UITouch.Phase, [CGPoint]) -> Void)?
    /// When set, a Pencil drag selects ink instead of drawing. A finger is reported on its own path.
    var capturesLasso = false
    var onPencilLasso: ((UITouch.Phase, [CGPoint]) -> Void)?
    /// One finger on the picture. A second finger cancels that contact so a desktop swipe can proceed.
    var onFingerPointer: ((UITouch.Phase, CGPoint) -> Void)?
    var onFingerCancel: (() -> Void)?
    /// The system three-finger swipe reaches PencilKit only while a frozen sketch is up.
    var acceptsSystemFingerSwipe = false
    private var fingerTouch: UITouch?

    override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
        acceptsSystemFingerSwipe ? .default : .none
    }

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
        restrictDrawingToPencil()
        forwardFinger(touches, phase: phase)
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
        if capturesLasso {
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
                onPencilLasso?(phase, history.map { $0.preciseLocation(in: self) })
            }
            if !others.isEmpty {
                pass(others, phase: phase, event: event)
            }
            return
        }
        pass(touches, phase: phase, event: event)
    }

    /// The first finger drives the Mac. Two or more fingers in one touch, or a finger
    /// that arrives while one is already down, leave that path so the three-finger
    /// swipe can switch desktops. The trackpad keeps the touches that hit it.
    private func forwardFinger(_ touches: Set<UITouch>, phase: UITouch.Phase) {
        let fingers = touches.filter(Self.isFinger)
        guard !fingers.isEmpty else { return }
        switch phase {
        case .began:
            if fingerTouch != nil {
                fingerTouch = nil
                onFingerCancel?()
                return
            }
            guard fingers.count == 1, let touch = fingers.first else { return }
            fingerTouch = touch
            onFingerPointer?(.began, touch.location(in: self))
        case .moved:
            guard let fingerTouch, fingers.contains(where: { $0 === fingerTouch }) else { return }
            onFingerPointer?(.moved, fingerTouch.location(in: self))
        case .ended, .cancelled:
            guard let fingerTouch, fingers.contains(where: { $0 === fingerTouch }) else { return }
            onFingerPointer?(phase, fingerTouch.location(in: self))
            self.fingerTouch = nil
        default:
            break
        }
    }

    private static func isFinger(_ touch: UITouch) -> Bool {
        switch touch.type {
        case .direct, .indirect, .indirectPointer:
            return true
        default:
            return false
        }
    }

    private func pass(_ touches: Set<UITouch>, phase: UITouch.Phase, event: UIEvent?) {
        if !acceptsSystemFingerSwipe, activeFingerCount(in: event) >= 3 {
            return
        }
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

    private func activeFingerCount(in event: UIEvent?) -> Int {
        guard let touches = event?.allTouches else { return 0 }
        return touches.reduce(into: 0) { count, touch in
            guard Self.isFinger(touch) else { return }
            switch touch.phase {
            case .ended, .cancelled:
                break
            default:
                count += 1
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        keepScrollPanOffDesktopSwipe()
    }

    /// The pen tool's setter clears `allowedTouchTypes`. A finger then belongs to
    /// the drawing gesture, which prevents the double tap before it can end.
    func restrictDrawingToPencil() {
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let current = drawingGestureRecognizer.allowedTouchTypes
        if current.count != 1 || current.first?.uintValue != pencil.uintValue {
            drawingGestureRecognizer.allowedTouchTypes = [pencil]
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer is PenHoldRecognizer || otherGestureRecognizer is PenHoldRecognizer
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is FingerTapRecognizer { return true }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    /// PKCanvasView is a scroll view. Its own pan and pinch stay off so a
    /// one-finger double tap, a two-finger undo tap, and a three-finger swipe
    /// are not cancelled. A finger pinch is the overlay's, sent to the Mac.
    func keepScrollPanOffDesktopSwipe() {
        isScrollEnabled = false
        panGestureRecognizer.isEnabled = false
        panGestureRecognizer.minimumNumberOfTouches = 2
        panGestureRecognizer.maximumNumberOfTouches = 2
        panGestureRecognizer.cancelsTouchesInView = false
        panGestureRecognizer.delaysTouchesBegan = false
        panGestureRecognizer.delaysTouchesEnded = false
        pinchGestureRecognizer?.isEnabled = false
    }

    /// PencilKit repaints a solid background over the stream. Keep the page clear
    /// so the stroke, not a white sheet, is what shows.
    override var backgroundColor: UIColor? {
        get { .clear }
        set { super.backgroundColor = .clear }
    }
}

/// Handles and a PencilKit preview of the ink being dragged. Touches pass through to the canvas.
private final class ShapeHandleView: UIView {
    var handles: [CGPoint] = [] {
        didSet { redrawChrome() }
    }
    var rotateHandle: CGPoint? {
        didSet { redrawChrome() }
    }
    var rotateAnchor: CGPoint? {
        didSet { redrawChrome() }
    }
    var lassoLoop: [CGPoint] = [] {
        didSet { redrawChrome() }
    }
    var selectionCorners: [CGPoint] = [] {
        didSet { redrawChrome() }
    }
    var selectionEdges: [CGPoint] = [] {
        didSet { redrawChrome() }
    }
    var selectionRotate: CGPoint? {
        didSet { redrawChrome() }
    }
    var selectionRotateAnchor: CGPoint? {
        didSet { redrawChrome() }
    }
    var pendingStroke: PKStroke?
    var pendingStrokes: [PKStroke] = []
    private let inkView = UIImageView()
    private let chrome = Chrome()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false

        inkView.isOpaque = false
        inkView.backgroundColor = .clear
        inkView.isUserInteractionEnabled = false
        inkView.contentMode = .topLeft
        addSubview(inkView)

        chrome.host = self
        chrome.isOpaque = false
        chrome.backgroundColor = .clear
        chrome.isUserInteractionEnabled = false
        chrome.frame = bounds
        chrome.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(chrome)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func redrawChrome() {
        chrome.setNeedsDisplay()
    }

    /// Renders the dragged ink.
    /// Selection chrome redraws on its own, so a handle move does not blur this image again.
    func renderPendingStroke() {
        let strokes: [PKStroke]
        if !pendingStrokes.isEmpty {
            strokes = pendingStrokes
        } else if let pendingStroke {
            strokes = [pendingStroke]
        } else {
            clearInkPreview()
            return
        }
        let drawing = PKDrawing(strokes: strokes)
        let strokeBounds = drawing.bounds.insetBy(dx: -16, dy: -16)
        guard !strokeBounds.isNull, !strokeBounds.isInfinite, strokeBounds.width > 1, strokeBounds.height > 1 else {
            clearInkPreview()
            return
        }
        let scale = max(window?.screen.scale ?? traitCollection.displayScale, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkView.image = drawing.literalImage(from: strokeBounds, scale: scale)
        inkView.frame = strokeBounds
        CATransaction.commit()
    }

    func clearInkPreview() {
        pendingStroke = nil
        pendingStrokes = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkView.image = nil
        inkView.frame = .zero
        CATransaction.commit()
    }

    fileprivate func drawChrome(in context: CGContext) {
        drawLoop(in: context)
        drawSelection(in: context)
        if let rotateAnchor, let rotateHandle {
            drawStem(from: rotateAnchor, to: rotateHandle, in: context)
            drawKnob(at: rotateHandle, in: context)
        }
        for handle in handles {
            drawKnob(at: handle, in: context)
        }
    }

    private final class Chrome: UIView {
        weak var host: ShapeHandleView?
        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            host?.drawChrome(in: context)
        }
    }

    private func drawLoop(in context: CGContext) {
        guard lassoLoop.count >= 2 else { return }
        context.saveGState()
        context.setLineDash(phase: 0, lengths: [7, 5])
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(1.5)
        context.setShadow(offset: .zero, blur: 1.5, color: UIColor.black.withAlphaComponent(0.35).cgColor)
        context.beginPath()
        context.move(to: lassoLoop[0])
        for point in lassoLoop.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawSelection(in context: CGContext) {
        guard selectionCorners.count == 4 else { return }
        context.saveGState()
        context.setLineDash(phase: 0, lengths: [6, 4])
        context.setLineCap(.butt)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(1.5)
        context.setShadow(offset: .zero, blur: 1.5, color: UIColor.black.withAlphaComponent(0.35).cgColor)
        context.beginPath()
        context.move(to: selectionCorners[0])
        for corner in selectionCorners.dropFirst() {
            context.addLine(to: corner)
        }
        context.closePath()
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        if let selectionRotate, let selectionRotateAnchor {
            context.beginPath()
            context.move(to: selectionRotateAnchor)
            context.addLine(to: selectionRotate)
            context.strokePath()
        }
        context.restoreGState()
        guard handles.isEmpty else { return }
        for corner in selectionCorners {
            drawKnob(at: corner, in: context)
        }
        for edge in selectionEdges {
            drawKnob(at: edge, in: context)
        }
        if let selectionRotate {
            drawKnob(at: selectionRotate, in: context)
        }
    }

    private func drawStem(from start: CGPoint, to end: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(1.5)
        context.setShadow(offset: .zero, blur: 1.5, color: UIColor.black.withAlphaComponent(0.35).cgColor)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.restoreGState()
    }

    private func drawKnob(at handle: CGPoint, in context: CGContext) {
        let mark = CGRect(x: handle.x - 7, y: handle.y - 7, width: 14, height: 14)
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: mark)
        context.setStrokeColor(UIColor.black.cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: mark.insetBy(dx: 0.75, dy: 0.75))
    }
}

/// Pen strokes of at least three samples. Endpoints stay put. The blend radius is `StrokeCenterline.windowRadius`.
private enum StrokeSmoothing {
    /// Live monoline ink of tool width `W` is stored as point size `W + 2`.
    static func pointSize(forToolWidth width: CGFloat) -> CGFloat {
        width + 2
    }

    /// Ink whose painted weight matches a stored monoline point size.
    static func ink(pointSize: CGFloat, color: UIColor) -> PKInk {
        PKInkingTool(.monoline, color: color, width: max(pointSize - 2, 1)).ink
    }

    /// Nil when the stroke should be kept as PencilKit produced it.
    static func smoothedPenStroke(from stroke: PKStroke, toolWidth: CGFloat) -> PKStroke? {
        let path = stroke.path
        guard path.count >= 3, stroke.ink.inkType == .pen || stroke.ink.inkType == .monoline else { return nil }
        let controls = (0..<path.count).map { path[$0] }
        let smoothed = StrokeCenterline.smoothed(controls.map { point in
            StrokeSample(
                location: point.location,
                size: point.size,
                opacity: point.opacity,
                force: point.force
            )
        })
        let size = pointSize(forToolWidth: toolWidth)
        let uniform = CGSize(width: size, height: size)
        let points = zip(controls, smoothed).map { original, sample in
            point(
                location: sample.location,
                timeOffset: original.timeOffset,
                size: uniform,
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let smoothedPath = PKStrokePath(
            controlPoints: points,
            creationDate: path.creationDate
        )
        return PKStroke(
            ink: ink(pointSize: size, color: stroke.ink.color),
            path: smoothedPath,
            transform: stroke.transform,
            mask: stroke.mask,
            randomSeed: stroke.randomSeed
        )
    }

    /// A pen stroke built from samples taken while the Pencil is still down.
    static func smoothedStroke(from samples: [PKStrokePoint], toolWidth: CGFloat, color: UIColor) -> PKStroke? {
        let ink = ink(pointSize: pointSize(forToolWidth: toolWidth), color: color)
        guard samples.count >= 3, ink.inkType == .pen || ink.inkType == .monoline else { return nil }
        let raw = PKStroke(
            ink: ink,
            path: PKStrokePath(controlPoints: samples, creationDate: Date()),
            transform: .identity,
            mask: nil
        )
        return smoothedPenStroke(from: raw, toolWidth: toolWidth)
    }

    static func point(
        location: CGPoint,
        timeOffset: TimeInterval,
        size: CGSize,
        opacity: CGFloat,
        force: CGFloat,
        azimuth: CGFloat,
        altitude: CGFloat
    ) -> PKStrokePoint {
        if #available(iOS 27, *) {
            return PKStrokePoint(
                location: location,
                timeOffset: timeOffset,
                size: size,
                opacity: opacity,
                force: force,
                azimuth: azimuth,
                altitude: altitude,
                secondaryScale: 0,
                threshold: 0,
                lateralJitter: 0
            )
        }
        if #available(iOS 26, *) {
            return PKStrokePoint(
                location: location,
                timeOffset: timeOffset,
                size: size,
                opacity: opacity,
                force: force,
                azimuth: azimuth,
                altitude: altitude,
                secondaryScale: 0,
                threshold: 0
            )
        }
        return PKStrokePoint(
            location: location,
            timeOffset: timeOffset,
            size: size,
            opacity: opacity,
            force: force,
            azimuth: azimuth,
            altitude: altitude,
            secondaryScale: 0
        )
    }
}

/// One rendered guess from the agent, in canvas points.
struct AgentImage {
    let id: UUID
    var frame: CGRect
    var image: UIImage
}

/// The agent's images, under the halo and the ink. Touches pass through to the canvas.
final class AgentImageLayer: UIView {
    private var views: [UUID: UIImageView] = [:]

    func show(_ images: [AgentImage]) {
        let ids = Set(images.map(\.id))
        for (id, view) in views where !ids.contains(id) {
            view.removeFromSuperview()
            views[id] = nil
        }
        for image in images {
            let view = views[image.id] ?? {
                let view = UIImageView()
                view.contentMode = .scaleToFill
                view.layer.borderColor = (UIColor(named: "CanvasLine") ?? .gray).cgColor
                view.layer.borderWidth = 1
                view.isAccessibilityElement = true
                view.accessibilityLabel = "The agent's rendering"
                addSubview(view)
                views[image.id] = view
                return view
            }()
            view.image = image.image
            view.frame = image.frame
        }
    }
}

/// Renders the agent's HTML in an off-screen web view the size of its image, then
/// snapshots it. The view sits outside the overlay's clipped bounds while it loads.
final class AgentHTMLRenderer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var completion: ((UIImage?) -> Void)?
    private var size: CGSize = .zero
    /// Scripts and fonts get this long after the page loads before the snapshot.
    private static let settleDelay: TimeInterval = 0.4
    private static let timeout: TimeInterval = 12

    func render(html: String, size: CGSize, in host: UIView, completion: @escaping (UIImage?) -> Void) {
        self.size = size
        self.completion = completion
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        let webView = WKWebView(
            frame: CGRect(x: -size.width - 64, y: 0, width: size.width, height: size.height),
            configuration: configuration
        )
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isUserInteractionEnabled = false
        webView.navigationDelegate = self
        host.addSubview(webView)
        self.webView = webView
        webView.loadHTMLString(html, baseURL: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            self?.finish(nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self, let webView = self.webView else { return }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(origin: .zero, size: self.size)
            configuration.afterScreenUpdates = true
            webView.takeSnapshot(with: configuration) { [weak self] image, _ in
                self?.finish(image)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    private func finish(_ image: UIImage?) {
        guard let completion else { return }
        self.completion = nil
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        completion(image)
    }
}
