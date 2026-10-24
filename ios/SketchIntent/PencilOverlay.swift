import PencilKit
import SwiftUI
import UIKit

enum FingerSwipe {
    case left
    case right
}

enum SketchTool: Equatable {
    case pen
    case eraser
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
/// visible on light and dark desktops. Nothing here is sent to the Mac.
struct PencilOverlay: UIViewRepresentable {
    var spaceID: String?
    var canvas: SketchCanvas
    var tool: SketchTool
    var acceptsTap: Bool
    var onTap: () -> Void
    var onFingerSwipe: (FingerSwipe) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(acceptsTap: acceptsTap, onTap: onTap, onFingerSwipe: onFingerSwipe)
    }

    func makeUIView(context: Context) -> PencilOverlayView {
        let view = PencilOverlayView()
        view.installGestures(target: context.coordinator)
        view.onInkChange = { [weak canvas] hasInk in
            canvas?.noteInk(hasInk)
        }
        canvas.attach(view)
        view.apply(tool: tool)
        return view
    }

    func updateUIView(_ uiView: PencilOverlayView, context: Context) {
        context.coordinator.acceptsTap = acceptsTap
        context.coordinator.onTap = onTap
        context.coordinator.onFingerSwipe = onFingerSwipe
        uiView.onInkChange = { [weak canvas] hasInk in
            canvas?.noteInk(hasInk)
        }
        canvas.attach(uiView)
        uiView.apply(tool: tool)
        if let spaceID {
            uiView.showSpace(spaceID)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var acceptsTap: Bool
        var onTap: () -> Void
        var onFingerSwipe: (FingerSwipe) -> Void
        private var reportedDesktopSwipe = false

        init(acceptsTap: Bool, onTap: @escaping () -> Void, onFingerSwipe: @escaping (FingerSwipe) -> Void) {
            self.acceptsTap = acceptsTap
            self.onTap = onTap
            self.onFingerSwipe = onFingerSwipe
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

    var hasInk: Bool {
        !canvas.drawing.strokes.isEmpty
    }

    func apply(tool: SketchTool) {
        guard appliedTool != tool else { return }
        appliedTool = tool
        switch tool {
        case .pen:
            canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        case .eraser:
            canvas.tool = PKEraserTool(.vector)
        }
        canvas.drawingGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.pencil.rawValue)
        ]
        canvas.keepScrollPanOffDesktopSwipe()
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

    /// Keeps each desktop's strokes with that desktop. The first id adopts whatever
    /// is already on the page, so a stroke started before the Mac checks in is not dropped.
    func showSpace(_ id: String) {
        guard id != currentSpaceID else { return }
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
