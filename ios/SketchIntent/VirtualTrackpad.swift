import SwiftUI
import UIKit

/// Frame 19:294 on the 12.9-inch artboard (1366×1024). The pad is 509×285,
/// inset 64 from the left and 428 from the top. The top 70 points are two
/// equal click cells. The rest is the scroll surface.
enum VirtualTrackpadMetrics {
    static let artboard = CGSize(width: 1366, height: 1024)
    static let designOrigin = CGPoint(x: 64, y: 428)
    static let designSize = CGSize(width: 509, height: 285)
    static let buttonBand: CGFloat = 70

    /// Same proportions and the same place on the artboard. A smaller iPad
    /// scales the whole frame uniformly so the cells stay two across.
    static func frame(in bounds: CGSize) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / artboard.width, bounds.height / artboard.height)
        return CGRect(
            x: designOrigin.x * scale,
            y: designOrigin.y * scale,
            width: designSize.width * scale,
            height: designSize.height * scale
        )
    }
}

/// Full-screen host. Empty space falls through to the stream, so a tap there
/// can dismiss the pad. The pad itself keeps the touch.
final class TrackpadHostView: UIView {
    let pad = TrackpadSurfaceView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        addSubview(pad)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pad.frame = VirtualTrackpadMetrics.frame(in: bounds.size)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// Gray pad with a black hairline, matching the Figma frame. The top band is
/// split into left and right click. A drag on the lower surface scrolls.
/// A tap there is a left click. One finger is the only contact.
final class TrackpadSurfaceView: UIView {
    var onScroll: (Int16, Int16, TrackpadScrollPhase) -> Void = { _, _, _ in }
    var onClick: (TrackpadButton, PointerPhase) -> Void = { _, _ in }

    private let rowSplit = UIView()
    private let columnSplit = UIView()
    private var tracked: UITouch?
    private var contact: Contact?
    private var origin: CGPoint = .zero
    private var last: CGPoint = .zero

    /// Shorter than this, a touch on the surface is a click rather than a scroll.
    private static let tapSlop: CGFloat = 8
    private static let fill = UIColor(red: 217.0 / 255, green: 217.0 / 255, blue: 217.0 / 255, alpha: 1)

    private enum Zone {
        case left
        case right
        case surface
    }

    private enum Contact {
        case button(TrackpadButton)
        case deciding
        case scrolling
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = Self.fill
        isMultipleTouchEnabled = true
        layer.borderColor = UIColor.black.cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 0

        rowSplit.backgroundColor = .black
        rowSplit.isUserInteractionEnabled = false
        columnSplit.backgroundColor = .black
        columnSplit.isUserInteractionEnabled = false
        addSubview(rowSplit)
        addSubview(columnSplit)

        isAccessibilityElement = true
        accessibilityLabel = "Trackpad"
        accessibilityHint = "Drag to scroll. Tap to click. The top left and right buttons click the left and right mouse buttons."
        accessibilityTraits = [.allowsDirectInteraction]
        accessibilityIdentifier = "virtual-trackpad"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let band = buttonBandHeight
        rowSplit.frame = CGRect(x: 0, y: band - 0.5, width: bounds.width, height: 1)
        columnSplit.frame = CGRect(x: bounds.midX - 0.5, y: 0, width: 1, height: band)
    }

    /// Pencil drawing continues under the pad. A finger at the same point still hits it.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        guard let touches = event?.allTouches, !touches.isEmpty else { return true }
        let pencils = touches.filter { $0.type == .pencil }
        guard !pencils.isEmpty else { return true }
        if pencils.contains(where: {
            let location = $0.location(in: self)
            return hypot(location.x - point.x, location.y - point.y) < 2
        }) {
            return false
        }
        return pencils.count != touches.count
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracked == nil, let touch = touches.first(where: { $0.type == .direct }) else { return }
        let point = touch.location(in: self)
        tracked = touch
        origin = point
        last = point
        switch zone(at: point) {
        case .left:
            contact = .button(.left)
            onClick(.left, .down)
        case .right:
            contact = .button(.right)
            onClick(.right, .down)
        case .surface:
            contact = .deciding
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let tracked, touches.contains(tracked) else { return }
        let point = tracked.location(in: self)
        switch contact {
        case .button:
            break
        case .deciding:
            guard hypot(point.x - origin.x, point.y - origin.y) >= Self.tapSlop else { return }
            contact = .scrolling
            emitScroll(from: last, to: point, phase: .began)
            last = point
        case .scrolling:
            emitScroll(from: last, to: point, phase: .changed)
            last = point
        case nil:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let tracked, touches.contains(tracked) else { return }
        finish(tracked.location(in: self), cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let tracked, touches.contains(tracked) else { return }
        finish(tracked.location(in: self), cancelled: true)
    }

    private var buttonBandHeight: CGFloat {
        bounds.height * (VirtualTrackpadMetrics.buttonBand / VirtualTrackpadMetrics.designSize.height)
    }

    private func zone(at point: CGPoint) -> Zone {
        guard point.y < buttonBandHeight else { return .surface }
        return point.x < bounds.midX ? .left : .right
    }

    /// Finger travel in points, posted as pixel scroll units. Positive `dx` is
    /// right and positive `dy` is down, matching the y-down display scroll.
    private func emitScroll(from start: CGPoint, to end: CGPoint, phase: TrackpadScrollPhase) {
        let dx = Int16(clamping: Int((end.x - start.x).rounded()))
        let dy = Int16(clamping: Int((end.y - start.y).rounded()))
        if phase == .changed, dx == 0, dy == 0 { return }
        onScroll(dx, dy, phase)
    }

    private func finish(_ point: CGPoint, cancelled: Bool) {
        let ending = contact
        tracked = nil
        contact = nil
        switch ending {
        case .button(let button):
            onClick(button, .up)
        case .scrolling:
            emitScroll(from: last, to: point, phase: .changed)
            onScroll(0, 0, cancelled ? .cancelled : .ended)
        case .deciding where !cancelled:
            onClick(.left, .down)
            onClick(.left, .up)
        default:
            break
        }
    }
}

struct VirtualTrackpad: UIViewRepresentable {
    var onScroll: (Int16, Int16, TrackpadScrollPhase) -> Void
    var onClick: (TrackpadButton, PointerPhase) -> Void

    func makeUIView(context: Context) -> TrackpadHostView {
        let host = TrackpadHostView()
        host.pad.onScroll = onScroll
        host.pad.onClick = onClick
        return host
    }

    func updateUIView(_ uiView: TrackpadHostView, context: Context) {
        uiView.pad.onScroll = onScroll
        uiView.pad.onClick = onClick
    }
}
