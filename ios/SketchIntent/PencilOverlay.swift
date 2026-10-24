import PencilKit
import SwiftUI
import UIKit

/// White pen strokes over the Mac picture. A thin dark shadow keeps each stroke
/// visible on light and dark desktops. Nothing here is sent to the Mac.
struct PencilOverlay: UIViewRepresentable {
    func makeUIView(context: Context) -> PencilOverlayView {
        PencilOverlayView()
    }

    func updateUIView(_ uiView: PencilOverlayView, context: Context) {}
}

final class PencilOverlayView: UIView, PKCanvasViewDelegate {
    private let shadowInk = UIImageView()
    private let canvas = InkCanvasView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false

        shadowInk.isOpaque = false
        shadowInk.backgroundColor = .clear
        shadowInk.isUserInteractionEnabled = false
        shadowInk.clipsToBounds = false
        shadowInk.layer.shadowColor = UIColor.black.cgColor
        shadowInk.layer.shadowOpacity = 1
        shadowInk.layer.shadowRadius = 1.25
        shadowInk.layer.shadowOffset = CGSize(width: 0, height: 0.5)
        shadowInk.layer.masksToBounds = false
        addSubview(shadowInk)

        canvas.frame = bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.delegate = self
        addSubview(canvas)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point) else { return nil }
        guard event?.allTouches?.contains(where: { $0.type == .pencil }) == true else { return nil }
        let local = convert(point, to: canvas)
        return canvas.hitTest(local, with: event) ?? canvas
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let strokeBounds = canvasView.drawing.bounds
        guard !strokeBounds.isNull, !strokeBounds.isInfinite, !strokeBounds.isEmpty else {
            shadowInk.image = nil
            return
        }
        let rect = strokeBounds.insetBy(dx: -8, dy: -8)
        let scale = max(window?.windowScene?.screen.scale ?? traitCollection.displayScale, 1)
        shadowInk.image = canvasView.drawing.image(from: rect, scale: scale)
        shadowInk.frame = rect
    }
}

/// PencilKit canvas. Fingers are not hits, so the gesture layer keeps the tap and three-finger swipe.
final class InkCanvasView: PKCanvasView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
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
        overrideUserInterfaceStyle = .light
        tool = PKInkingTool(.pen, color: .white, width: 3)
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = false
        if contentOffset != .zero {
            contentOffset = .zero
        }
        clearBackgrounds(self)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point) else { return nil }
        guard event?.allTouches?.contains(where: { $0.type == .pencil }) == true else { return nil }
        return self
    }

    private func clearBackgrounds(_ view: UIView) {
        view.backgroundColor = .clear
        view.isOpaque = false
        view.subviews.forEach(clearBackgrounds)
    }
}

/// Hosts the one-finger tap and three-finger desktop swipe. Apple Pencil falls through to the canvas behind.
final class FingerTouchView: UIView {
    static let fingerTouchTypes: [NSNumber] = [
        NSNumber(value: UITouch.TouchType.direct.rawValue),
        NSNumber(value: UITouch.TouchType.indirect.rawValue),
        NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.allTouches?.contains(where: { $0.type == .pencil }) == true {
            return nil
        }
        return super.hitTest(point, with: event)
    }
}
