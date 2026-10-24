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

    /// Clockwise detent. Pen sits on the right, the pointer below it, the eraser above it.
    var nextOnDial: SketchTool {
        switch self {
        case .pen: return .pointer
        case .pointer: return .eraser
        case .eraser: return .pen
        }
    }

    var symbolName: String {
        switch self {
        case .pen: return "pencil.and.outline"
        case .pointer: return "hand.point.up.fill"
        case .eraser: return "eraser.fill"
        }
    }

    var accessibilityName: String {
        switch self {
        case .pen: return "Pencil"
        case .pointer: return "Pointer"
        case .eraser: return "Eraser"
        }
    }

    /// Radians from the right side of the dial. Positive angles run clockwise.
    var dialAngle: CGFloat {
        switch self {
        case .pen: return 0
        case .pointer: return 2 * .pi / 3
        case .eraser: return -2 * .pi / 3
        }
    }

    var rawTag: Int {
        switch self {
        case .pen: return 1
        case .pointer: return 2
        case .eraser: return 3
        }
    }

    init?(rawTag: Int) {
        switch rawTag {
        case 1: self = .pen
        case 2: self = .pointer
        case 3: self = .eraser
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
/// lightly, and the halo is redrawn from that smoothed ink. Strokes stay on the
/// iPad. When Control the Mac with Pencil is on, the Pencil clicks and drags
/// on the Mac instead of drawing.
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
    var onTap: () -> Void
    var onFingerSwipe: (FingerSwipe) -> Void
    var onToggleTool: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            acceptsTap: acceptsTap,
            onTap: onTap,
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
        context.coordinator.onFingerSwipe = onFingerSwipe
        context.coordinator.onToggleTool = onToggleTool
        uiView.onInkChange = { [weak canvas] hasInk in
            canvas?.noteInk(hasInk)
        }
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
        var onFingerSwipe: (FingerSwipe) -> Void
        var onToggleTool: () -> Void
        private var reportedDesktopSwipe = false

        init(
            acceptsTap: Bool,
            onTap: @escaping () -> Void,
            onFingerSwipe: @escaping (FingerSwipe) -> Void,
            onToggleTool: @escaping () -> Void
        ) {
            self.acceptsTap = acceptsTap
            self.onTap = onTap
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

        @objc func tapped() {
            guard acceptsTap else { return }
            onTap()
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

        /// Barrel double-tap. A finger tap never arrives here; that gesture shows the status badge.
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
    /// How many strokes were already stored when the current pen stroke began. Earlier strokes are left as they are.
    private var strokeCountAtPenDown = 0
    /// Set while a smoothed stroke is written back, so that write is not smoothed again.
    private var isApplyingSmoothedStroke = false

    /// Half of the old 32-point bitmap tip. Touching ink deletes that whole stroke.
    private static let eraserRadius: CGFloat = 16
    /// Distance between path samples, in stroke space. Shorter than the tip, so a graze between samples still hits.
    private static let eraserSampleDistance: CGFloat = 2

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
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        if sendsPointer && !sends {
            endPointer()
        }
        sendsPointer = sends
    }

    /// Pen and eraser take effect only while the Pencil is drawing. Pointer mode,
    /// and Control the Mac with Pencil, leave the page alone and send clicks instead.
    func apply(tool: SketchTool, drawsWithPencil: Bool) {
        let sendsPencilAsPointer = !drawsWithPencil || tool == .pointer
        let erasing = drawsWithPencil && tool == .eraser
        canvas.forwardsPencilAsPointer = sendsPencilAsPointer
        canvas.erasesWholeStrokes = erasing
        if !erasing {
            lastEraserPoint = nil
        }
        // The stroke eraser handles Pencil touches itself. PencilKit's vector eraser
        // waits until lift, and its bitmap eraser only clears the pixels underneath.
        canvas.drawingGestureRecognizer.isEnabled = drawsWithPencil && !erasing && !sendsPencilAsPointer
        canvas.drawingGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.pencil.rawValue)
        ]
        canvas.keepScrollPanOffDesktopSwipe()
        guard drawsWithPencil, appliedTool != tool else { return }
        appliedTool = tool
        switch tool {
        case .pen:
            canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        case .eraser:
            break
        case .pointer:
            canvas.drawingGestureRecognizer.isEnabled = false
            canvas.forwardsPencilAsPointer = true
            canvas.erasesWholeStrokes = false
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
        canvas.onPencilPointer = { [weak self] phase, point in
            guard let self else { return }
            self.handlePencil(phase: phase, at: self.canvas.convert(point, to: self))
        }
        canvas.onPencilErase = { [weak self] phase, samples in
            self?.eraseStrokes(phase: phase, samples: samples)
        }
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

        let tap = UITapGestureRecognizer(target: target, action: #selector(PencilOverlay.Coordinator.tapped))
        tap.numberOfTouchesRequired = 1
        tap.allowedTouchTypes = finger
        tap.delegate = target
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

    /// Keeps each desktop's strokes with that desktop. The first id adopts whatever
    /// is already on the page, so a stroke started before the Mac checks in is not dropped.
    func showSpace(_ id: String) {
        guard id != currentSpaceID else { return }
        lastEraserPoint = nil
        penStrokeOpen = false
        if let currentSpaceID {
            drawings[currentSpaceID] = canvas.drawing
        }
        let adoptingExistingInk = currentSpaceID == nil && !canvas.drawing.strokes.isEmpty
        currentSpaceID = id
        if adoptingExistingInk {
            drawings[id] = canvas.drawing
            return
        }
        canvas.drawing = drawings[id] ?? PKDrawing()
        canvasViewDrawingDidChange(canvas)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
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
            return
        }
        let rect = strokeBounds.insetBy(dx: -12, dy: -12)
        let scale = max(window?.screen.scale ?? traitCollection.displayScale, 1)
        halo.image = canvasView.drawing.image(from: rect, scale: scale)
        halo.frame = rect
        onInkChange?(hasInk)
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
