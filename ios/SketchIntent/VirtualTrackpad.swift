import SwiftUI
import UIKit

/// Figma frame "virt trackpad" (55:1077) size 712.904×509, corner radius 16,
/// scaled to the iPad, centered, and flush with the bottom edge. A near-black
/// plate with a 1pt grey rim. The lighter block in the bottom-right corner is
/// the secondary-click corner. The whole surface is the trackpad.
enum VirtualTrackpadMetrics {
    static let artboard = CGSize(width: 1366, height: 1024)
    static let designSize = CGSize(width: 712.904, height: 509)
    static let cornerRadius: CGFloat = 16
    static let rimWidth: CGFloat = 1
    /// `UITouch.majorRadius` above this is a resting palm. A fingertip stays at or under it.
    static let fingertipMajorRadius: CGFloat = 32
    /// Bottom corners occupy this much of the pad, the size of the drawn corner
    /// block (Figma 55:1082, 357×163.49). A one-finger tap in the bottom-right is
    /// always a right click. The bottom-left, the same size, follows the Mac setting.
    static let cornerWidthFraction: CGFloat = 357 / 712.904
    static let cornerHeightFraction: CGFloat = 163.49 / 509
    /// Extra hit area around the pad. A fingertip aimed at the rim often reports
    /// its center just outside the plate, and that touch would otherwise miss.
    static let edgeHitOutset: CGFloat = 32

    /// Uniform artboard scale. The pad is centered horizontally and rests on the bottom edge.
    static func frame(in bounds: CGSize) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / artboard.width, bounds.height / artboard.height)
        let width = designSize.width * scale
        let height = designSize.height * scale
        return CGRect(
            x: (bounds.width - width) / 2,
            y: max(0, bounds.height - height),
            width: width,
            height: height
        )
    }

    /// A direct contact whose radius is already a palm. Pencil is not a palm.
    /// Call this at touch-down; a later change in radius does not reclassify.
    static func beginsAsPalm(_ touch: UITouch) -> Bool {
        switch touch.type {
        case .direct, .indirect, .indirectPointer:
            return touch.majorRadius > fingertipMajorRadius
        default:
            return false
        }
    }
}

/// Full-screen host. A finger tap outside the pad falls through, so it can
/// dismiss the pad and click the picture. A fingertip that starts in the margin
/// around the plate still belongs to the pad. A palm outside is kept here and
/// does neither. The pad itself keeps a fingertip.
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
        let local = convert(point, to: pad)
        if pad.point(inside: local, with: event) {
            return pad
        }
        let reach = pad.bounds.insetBy(
            dx: -VirtualTrackpadMetrics.edgeHitOutset,
            dy: -VirtualTrackpadMetrics.edgeHitOutset
        )
        if pointIsOnClosedEdge(local, of: reach) {
            if isPencil(at: point, event: event) {
                return nil
            }
            return pad
        }
        if let touch = touch(at: point, event: event), VirtualTrackpadMetrics.beginsAsPalm(touch) {
            return self
        }
        return nil
    }

    /// `CGRect.contains` leaves out the max edges, so a contact on the right or
    /// bottom rim of the plate was falling through.
    private func pointIsOnClosedEdge(_ point: CGPoint, of rect: CGRect) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    private func isPencil(at point: CGPoint, event: UIEvent?) -> Bool {
        guard let touches = event?.allTouches else { return false }
        return touches.contains { touch in
            guard touch.type == .pencil else { return false }
            let location = touch.location(in: self)
            return hypot(location.x - point.x, location.y - point.y) < 44
        }
    }

    /// The host claims a palm so the picture never sees it. These touches are not gestures.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}

    /// The hit-test point belongs to the touch that is landing there.
    private func touch(at point: CGPoint, event: UIEvent?) -> UITouch? {
        guard let touches = event?.allTouches, !touches.isEmpty else { return nil }
        var best: UITouch?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for touch in touches {
            let location = touch.location(in: self)
            let distance = hypot(location.x - point.x, location.y - point.y)
            if distance < bestDistance {
                bestDistance = distance
                best = touch
            }
        }
        guard bestDistance <= 10 else { return nil }
        return best
    }
}

/// Translucent rounded pad. One finger moves the pointer. Two fingers scroll.
/// Two fingers spreading or pinching zoom on the Mac. Three fingers swiping
/// horizontally switch desktops and do not move, scroll, or click.
/// A tap is reported with its finger count and corner so the Mac can apply
/// tap-to-click and secondary click. A palm is not a finger. Pencil strokes
/// pass through to the canvas.
final class TrackpadSurfaceView: UIView {
    var onMove: (Int16, Int16) -> Void = { _, _ in }
    var onScroll: (Int16, Int16, TrackpadScrollPhase) -> Void = { _, _, _ in }
    var onTap: (UInt8, TrackpadTapZone) -> Void = { _, _ in }
    var onDrag: (Int16, Int16, PointerPhase, UInt8) -> Void = { _, _, _, _ in }
    /// Change in finger separation since the previous sample. Greater than 1 zooms in.
    /// The closing sample is 1 with phase ended or cancelled.
    var onMagnify: (CGFloat, TrackpadScrollPhase) -> Void = { _, _ in }
    /// Finger direction, before the Natural swiping setting. `.left` means the fingers moved left.
    var onSwipe: (FingerSwipe) -> Void = { _ in }

    private final class Contact {
        let touch: UITouch
        var start: CGPoint
        var last: CGPoint

        init(_ touch: UITouch, at point: CGPoint) {
            self.touch = touch
            start = point
            last = point
        }
    }

    private var contacts: [Contact] = []
    private enum Mode {
        case pending
        case moving
        case scrolling
        case zooming
        case dragging
        case suppressed
    }

    private var mode: Mode = .pending
    /// True once the gesture has moved the pointer or scrolled, so the lift is not also a tap.
    private var traveled = false
    private var anchor: CGPoint = .zero
    private var peakFingers = 0
    private var residualX: CGFloat = 0
    private var residualY: CGFloat = 0
    /// Finger separation when the two-finger gesture started, and at the last zoom sample.
    private var pinchStart: CGFloat = 0
    private var pinchLast: CGFloat = 0

    /// Travel past this, in points, leaves the tap and becomes a move or a scroll.
    private static let slop: CGFloat = 8
    /// Same horizontal travel the canvas uses before a three-finger pan switches desktops.
    private static let desktopSwipeTravel: CGFloat = 36
    /// Classification is fixed at touch-down. A palm that shrinks stays a palm,
    /// and a fingertip that later widens stays a finger.
    private var fingerTouches: Set<ObjectIdentifier> = []
    private var rejectedTouches: Set<ObjectIdentifier> = []
    private let plate = UIView()
    private let cornerBlock = UIView()

    private var centroid: CGPoint {
        guard !contacts.isEmpty else { return anchor }
        let count = CGFloat(contacts.count)
        let x = contacts.reduce(CGFloat(0)) { $0 + $1.last.x } / count
        let y = contacts.reduce(CGFloat(0)) { $0 + $1.last.y } / count
        return CGPoint(x: x, y: y)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        let rim = (UIColor(named: "CanvasLine") ?? .gray).cgColor
        plate.isUserInteractionEnabled = false
        plate.backgroundColor = UIColor(named: "TrackpadFill")
        plate.layer.borderColor = rim
        plate.layer.borderWidth = VirtualTrackpadMetrics.rimWidth
        plate.layer.cornerCurve = .continuous
        plate.clipsToBounds = true
        cornerBlock.isUserInteractionEnabled = false
        cornerBlock.backgroundColor = UIColor(named: "TrackpadCorner")
        cornerBlock.layer.borderColor = rim
        cornerBlock.layer.borderWidth = VirtualTrackpadMetrics.rimWidth
        cornerBlock.layer.cornerCurve = .continuous
        cornerBlock.layer.maskedCorners = [.layerMinXMinYCorner]
        addSubview(plate)
        plate.addSubview(cornerBlock)
        isAccessibilityElement = true
        accessibilityLabel = "Trackpad"
        accessibilityHint = "One finger moves the pointer. Two fingers scroll. Pinch to zoom on the Mac. Three fingers swipe left or right to switch desktops. A tap clicks when the Mac trackpad is set to tap to click."
        accessibilityTraits = [.allowsDirectInteraction]
        accessibilityIdentifier = "virtual-trackpad"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = bounds.width > 0 ? bounds.width / VirtualTrackpadMetrics.designSize.width : 1
        plate.frame = bounds
        plate.layer.cornerRadius = VirtualTrackpadMetrics.cornerRadius * scale
        let cornerWidth = bounds.width * VirtualTrackpadMetrics.cornerWidthFraction
        let cornerHeight = bounds.height * VirtualTrackpadMetrics.cornerHeightFraction
        cornerBlock.frame = CGRect(
            x: bounds.width - cornerWidth,
            y: bounds.height - cornerHeight,
            width: cornerWidth,
            height: cornerHeight
        )
        cornerBlock.layer.cornerRadius = VirtualTrackpadMetrics.cornerRadius * scale
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
        let added = touches.filter { touch in
            isFinger(touch) && !contacts.contains { $0.touch === touch }
        }
        guard !added.isEmpty else { return }
        defer {
            if contacts.count == 2 {
                let separation = fingerSeparation()
                pinchStart = separation
                pinchLast = separation
            }
        }
        for touch in added {
            contacts.append(Contact(touch, at: clampToPad(touch.location(in: self))))
        }
        peakFingers = max(peakFingers, contacts.count)
        if contacts.count > 3 {
            suppress()
            return
        }
        if contacts.count == 3 {
            if mode == .scrolling || mode == .dragging || mode == .zooming {
                suppress()
                return
            }
            mode = .pending
            anchor = centroid
            residualX = 0
            residualY = 0
            return
        }
        guard mode != .suppressed, mode != .scrolling, mode != .dragging, mode != .zooming else { return }
        if contacts.count == 2, mode == .moving {
            mode = .pending
            anchor = centroid
            residualX = 0
            residualY = 0
            return
        }
        if mode == .pending {
            anchor = centroid
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var changed = false
        for touch in touches where isFinger(touch) {
            guard let contact = contacts.first(where: { $0.touch === touch }) else { continue }
            contact.last = clampToPad(touch.location(in: self))
            changed = true
        }
        guard changed, mode != .suppressed else { return }
        let point = centroid
        switch (contacts.count, mode) {
        case (1, .pending):
            guard distance(point, anchor) >= Self.slop else { return }
            mode = .moving
            traveled = true
            emitMove(from: anchor, to: point)
            anchor = point
        case (1, .moving):
            emitMove(from: anchor, to: point)
            anchor = point
        case (2, .pending):
            let separation = fingerSeparation()
            let pinch = abs(separation - pinchStart)
            let travel = distance(point, anchor)
            if pinch >= Self.slop, pinch > travel {
                mode = .zooming
                traveled = true
                let factor = pinchStart > 0.5 && separation > 0.5 ? separation / pinchStart : 1
                onMagnify(factor, .began)
                pinchLast = separation
            } else if travel >= Self.slop, travel >= pinch {
                mode = .scrolling
                traveled = true
                emitScroll(from: anchor, to: point, phase: .began)
                anchor = point
            }
        case (2, .scrolling):
            emitScroll(from: anchor, to: point, phase: .changed)
            anchor = point
        case (2, .zooming):
            let separation = fingerSeparation()
            guard pinchLast > 0.5, separation > 0.5 else { return }
            let factor = separation / pinchLast
            pinchLast = separation
            if abs(factor - 1) > 0.0001 {
                onMagnify(factor, .changed)
            }
        case (3, .pending):
            resolveThreeFingerTravel(to: point)
        case (3, .dragging):
            emitDrag(from: anchor, to: point, phase: .move)
            anchor = point
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        close(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        close(touches, cancelled: true)
    }

    private func close(_ touches: Set<UITouch>, cancelled: Bool) {
        defer { release(touches) }
        for touch in touches where isFinger(touch) {
            if let contact = contacts.first(where: { $0.touch === touch }) {
                contact.last = clampToPad(touch.location(in: self))
            }
        }
        let lifting = contacts.filter { contact in touches.contains { $0 === contact.touch } }
        guard !lifting.isEmpty else { return }
        if !cancelled {
            resolveThreeFingerTravel(to: centroid)
        }
        if mode == .scrolling {
            finishScroll(at: centroid, cancelled: cancelled)
            mode = .suppressed
        } else if mode == .zooming {
            onMagnify(1, cancelled ? .cancelled : .ended)
            mode = .suppressed
        } else if mode == .dragging {
            finishDrag(at: centroid)
            mode = .suppressed
        }
        contacts.removeAll { contact in lifting.contains { $0 === contact } }
        if contacts.isEmpty {
            if !cancelled, !traveled, mode != .suppressed {
                if peakFingers == 1, let start = lifting.first?.start {
                    onTap(1, zone(at: start))
                } else if peakFingers == 2 {
                    onTap(2, .other)
                }
            }
            reset()
            return
        }
        if mode == .pending {
            anchor = centroid
        }
    }

    /// Three fingers moving horizontally switch desktops, once, and send nothing else.
    /// A vertical three-finger drag still drags, but only after it can no longer be that swipe,
    /// so the swipe never also moves the pointer or clicks. A palm is already excluded.
    private func resolveThreeFingerTravel(to point: CGPoint) {
        guard mode == .pending, contacts.count == 3 else { return }
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        if abs(dx) >= Self.desktopSwipeTravel, abs(dx) > abs(dy) {
            traveled = true
            mode = .suppressed
            onSwipe(dx < 0 ? .left : .right)
            return
        }
        guard abs(dy) >= Self.desktopSwipeTravel, abs(dy) >= abs(dx) else { return }
        mode = .dragging
        traveled = true
        emitDrag(from: anchor, to: point, phase: .down)
        anchor = point
    }

    private func suppress() {
        if mode == .scrolling {
            finishScroll(at: centroid, cancelled: true)
        } else if mode == .zooming {
            onMagnify(1, .cancelled)
        } else if mode == .dragging {
            finishDrag(at: centroid)
        }
        mode = .suppressed
        traveled = true
    }

    private func finishScroll(at point: CGPoint, cancelled: Bool) {
        emitScroll(from: anchor, to: point, phase: .changed)
        onScroll(0, 0, cancelled ? .cancelled : .ended)
        residualX = 0
        residualY = 0
        anchor = point
    }

    private func finishDrag(at point: CGPoint) {
        emitDrag(from: anchor, to: point, phase: .up)
        residualX = 0
        residualY = 0
        anchor = point
    }

    private func emitMove(from start: CGPoint, to end: CGPoint) {
        let (dx, dy) = takeResidual(dx: end.x - start.x, dy: end.y - start.y)
        if dx != 0 || dy != 0 {
            onMove(dx, dy)
        }
    }

    private func emitScroll(from start: CGPoint, to end: CGPoint, phase: TrackpadScrollPhase) {
        let (dx, dy) = takeResidual(dx: end.x - start.x, dy: end.y - start.y)
        if phase == .changed, dx == 0, dy == 0 { return }
        onScroll(dx, dy, phase)
    }

    private func emitDrag(from start: CGPoint, to end: CGPoint, phase: PointerPhase) {
        let (dx, dy) = takeResidual(dx: end.x - start.x, dy: end.y - start.y)
        if phase == .move, dx == 0, dy == 0 { return }
        onDrag(dx, dy, phase, 3)
    }

    /// Keeps the fractional point so a slow finger still reaches the next pixel.
    private func takeResidual(dx: CGFloat, dy: CGFloat) -> (Int16, Int16) {
        residualX += dx
        residualY += dy
        let ix = Int(residualX.rounded(.towardZero))
        let iy = Int(residualY.rounded(.towardZero))
        residualX -= CGFloat(ix)
        residualY -= CGFloat(iy)
        return (Int16(clamping: ix), Int16(clamping: iy))
    }

    private func zone(at point: CGPoint) -> TrackpadTapZone {
        let width = bounds.width * VirtualTrackpadMetrics.cornerWidthFraction
        let height = bounds.height * VirtualTrackpadMetrics.cornerHeightFraction
        guard width > 0, height > 0, point.y >= bounds.height - height else { return .other }
        if point.x <= width { return .bottomLeft }
        if point.x >= bounds.width - width { return .bottomRight }
        return .other
    }

    private func reset() {
        contacts.removeAll()
        mode = .pending
        traveled = false
        peakFingers = 0
        residualX = 0
        residualY = 0
        pinchStart = 0
        pinchLast = 0
        anchor = .zero
    }

    private func fingerSeparation() -> CGFloat {
        guard contacts.count >= 2 else { return 0 }
        return hypot(
            contacts[0].last.x - contacts[1].last.x,
            contacts[0].last.y - contacts[1].last.y
        )
    }

    /// Samples outside the plate sit on its rim, so travel before the finger
    /// enters, or after it leaves, does not move, scroll, or swipe.
    private func clampToPad(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// The first sample decides. A palm stays out of `contacts` for the rest of
    /// the touch, so it cannot change `peakFingers`, start a scroll, or fire a tap.
    private func isFinger(_ touch: UITouch) -> Bool {
        let id = ObjectIdentifier(touch)
        if fingerTouches.contains(id) { return true }
        if rejectedTouches.contains(id) { return false }
        let finger: Bool
        switch touch.type {
        case .direct, .indirect, .indirectPointer:
            finger = touch.majorRadius <= VirtualTrackpadMetrics.fingertipMajorRadius
        default:
            finger = false
        }
        if finger {
            fingerTouches.insert(id)
        } else {
            rejectedTouches.insert(id)
        }
        return finger
    }

    private func release(_ touches: Set<UITouch>) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            fingerTouches.remove(id)
            rejectedTouches.remove(id)
        }
    }
}

struct VirtualTrackpad: UIViewRepresentable {
    var onMove: (Int16, Int16) -> Void
    var onScroll: (Int16, Int16, TrackpadScrollPhase) -> Void
    var onTap: (UInt8, TrackpadTapZone) -> Void
    var onDrag: (Int16, Int16, PointerPhase, UInt8) -> Void
    var onSwipe: (FingerSwipe) -> Void
    var onMagnify: (CGFloat, TrackpadScrollPhase) -> Void

    func makeUIView(context: Context) -> TrackpadHostView {
        let host = TrackpadHostView()
        host.pad.onMove = onMove
        host.pad.onScroll = onScroll
        host.pad.onTap = onTap
        host.pad.onDrag = onDrag
        host.pad.onSwipe = onSwipe
        host.pad.onMagnify = onMagnify
        return host
    }

    func updateUIView(_ uiView: TrackpadHostView, context: Context) {
        uiView.pad.onMove = onMove
        uiView.pad.onScroll = onScroll
        uiView.pad.onTap = onTap
        uiView.pad.onDrag = onDrag
        uiView.pad.onSwipe = onSwipe
        uiView.pad.onMagnify = onMagnify
    }
}
