import ApplicationServices
import CoreGraphics
import Foundation
import StreamProtocol

/// Turns captured-frame pixels into a point in global display space.
enum PointerGeometry {
    static func globalPoint(
        x: UInt16,
        y: UInt16,
        frameWidth: Int,
        frameHeight: Int,
        bounds: CGRect,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> CGPoint? {
        guard frameWidth > 0, frameHeight > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let pixelsW = pixelWidth > 0 ? Double(pixelWidth) : Double(bounds.width)
        let pixelsH = pixelHeight > 0 ? Double(pixelHeight) : Double(bounds.height)
        let scaleX = pixelsW / Double(bounds.width)
        let scaleY = pixelsH / Double(bounds.height)
        guard scaleX > 0, scaleY > 0 else { return nil }
        let displayPixelX = Double(x) * pixelsW / Double(frameWidth)
        let displayPixelY = Double(y) * pixelsH / Double(frameHeight)
        return CGPoint(
            x: bounds.origin.x + displayPixelX / scaleX,
            y: bounds.origin.y + displayPixelY / scaleY
        )
    }
}

/// Pixel scroll sample posted as `kCGEventScrollWheel`.
///
/// `CGEventType` has no magnify, rotate, or touch case. TN3212's public stand-in for a
/// one-finger pan is a trackpad scroll, so this is the event a finger drag posts.
struct ScrollWheelPayload: Equatable {
    var point: CGPoint
    /// Horizontal pixels. Positive is movement to the right (`wheel2` / axis 2).
    var deltaX: Int32
    /// Vertical pixels. Positive is movement up (`wheel1` / axis 1), matching
    /// `CGEventCreateScrollWheelEvent`.
    var deltaY: Int32
    var phase: CGScrollPhase
    /// Coasting after the fingers lift. `.none` while the fingers are still down.
    var momentum: CGMomentumScrollPhase = .none

    func makeEvent(source: CGEventSource? = nil) -> CGEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else { return nil }
        event.location = point
        // A momentum event carries momentum phase only. The gesture phase stays none
        // so AppKit treats the tail as coasting rather than a second finger drag.
        let gesturePhase: Int64 = momentum == .none ? Int64(phase.rawValue) : 0
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: gesturePhase)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(deltaY))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(deltaX))
        return event
    }
}

/// `NSEventTypeDirectTouch` is 37. `CGEventType` has no case for it, and `NSEvent` refuses
/// to build one (`otherEventWithType` rejects the type). A posted event can still use that
/// raw type at the finger's point. AppKit only attaches `NSTouch` objects for touches the
/// window server creates, so a recognizer that requires those objects may ignore this.
struct DirectTouchEvent: Equatable {
    /// `NX_SUBTYPE_MOUSE_TOUCH` / `NSEventSubtypeTouch`.
    static let touchSubtype: Int64 = 3
    /// `NSEventTypeDirectTouch`.
    static let eventType = CGEventType(rawValue: 37)!

    var point: CGPoint
    var phase: CGScrollPhase

    func makeEvent(source: CGEventSource? = nil) -> CGEvent? {
        guard let event = CGEvent(source: source) else { return nil }
        event.type = Self.eventType
        event.location = point
        event.setIntegerValueField(.mouseEventSubtype, value: Self.touchSubtype)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        return event
    }
}

/// `NSEventTypeMagnify` as a posted event. `CGEventType` has no magnify case, so this is
/// the private gesture layout AppKit reads back: raw type 29 (`NSEventTypeGesture`),
/// field 110 the HID event type (8, `kIOHIDEventTypeZoom`), field 113 the magnification,
/// and field 132 the `IOHIDEventPhaseBits`, whose values match `CGScrollPhase`.
/// The window server delivers it to the window under `point`, like a trackpad pinch.
struct MagnifyGestureEvent: Equatable {
    /// `NSEventTypeGesture`.
    static let eventType = CGEventType(rawValue: 29)!
    /// `kIOHIDEventTypeZoom`.
    static let zoomHIDType: Int64 = 8
    static let hidTypeField = CGEventField(rawValue: 110)!
    static let magnificationField = CGEventField(rawValue: 113)!
    static let phaseField = CGEventField(rawValue: 132)!

    var point: CGPoint
    /// `NSEvent.magnification`: 0.01 is 1% larger.
    var magnification: Double
    var phase: CGScrollPhase

    func makeEvent(source: CGEventSource? = nil) -> CGEvent? {
        guard let event = CGEvent(source: source) else { return nil }
        event.type = Self.eventType
        event.location = point
        event.setIntegerValueField(Self.hidTypeField, value: Self.zoomHIDType)
        event.setIntegerValueField(Self.phaseField, value: Int64(phase.rawValue))
        event.setDoubleValueField(Self.magnificationField, value: magnification)
        return event
    }
}

enum PointerAccessError: Error, CustomStringConvertible {
    case accessibilityDenied

    var description: String {
        """
        Accessibility permission is off, so touch and trackpad input cannot reach this Mac.
        Approve the system prompt, or enable this app in System Settings → Privacy & Security → Accessibility.
        If you launched the server from a terminal or Cursor, enable that host app as well. Then run the server again.
        """
    }
}

enum PointerInjection: Equatable {
    case move(CGPoint)
    /// Left mouse-down immediately followed by mouse-up. TN3212's tap emulation.
    case leftClick(CGPoint)
    case leftDown(CGPoint)
    case leftDrag(CGPoint)
    case leftUp(CGPoint)
    case rightDown(CGPoint)
    case rightDrag(CGPoint)
    case rightUp(CGPoint)
    case scroll(ScrollWheelPayload)
    /// Posted with the finger stand-in, at the Pencil point, so a touch-aware app sees the contact too.
    case directTouch(DirectTouchEvent)
}

/// One Pencil contact, mapped the way TN3212 § "Automatic mouse emulation" describes a Sidecar finger.
///
/// A tap (lift before the finger moves `movementSlop` points) is a left click: mouse-down then mouse-up,
/// not a button held for the whole touch. A drag before `longPressDuration` is a continuous pixel
/// `scrollWheel` with `kCGScrollWheelEventScrollPhase` began, changed, and ended. The event location
/// stays at the touch-down point, because AppKit delivers a gesture scroll to the view under the cursor
/// when the phase began (`NSEvent.phase`). A hold without movement is a right click on lift
/// (`rightMouseDown`, then `rightMouseUp`), while moving after the hold is a left-button drag
/// (`leftMouseDown`, `leftMouseDragged`, then `leftMouseUp`).
///
/// Magnify and rotate are not produced. TN3212 ties those to a two-finger pinch or rotation,
/// and this tracker has one point. Each phase also posts a direct-touch event at the Pencil
/// point. Mouse clicks from this tracker are marked `NSEventSubtypeTouch`.
struct FingerContactTracker {
    static let movementSlop: CGFloat = 6
    /// `NSPressGestureRecognizer.minimumPressDuration` is "appropriate for touch" and not a fixed
    /// public number. Half a second is the hold that unlocks a drag or right-click above.
    static let longPressDuration: TimeInterval = 0.5

    private enum Mode {
        case idle
        case pending
        case scrolling
        case held
        case dragging
    }

    private var mode: Mode = .idle
    private var origin: CGPoint = .zero
    private var current: CGPoint = .zero
    private var lastScroll: CGPoint = .zero
    /// `ProcessInfo.systemUptime` deadline while the contact is still undecided. Nil once it scrolls or holds.
    private(set) var longPressDeadline: TimeInterval?

    mutating func handle(phase: PointerPhase, point: CGPoint, time: TimeInterval) -> [PointerInjection] {
        switch phase {
        case .down:
            var events = cancel()
            mode = .pending
            origin = point
            current = point
            lastScroll = point
            longPressDeadline = time + Self.longPressDuration
            events.append(.move(point))
            events.append(Self.touch(point, .began))
            return events
        case .move:
            guard mode != .idle else { return [] }
            current = point
            switch mode {
            case .pending:
                guard Self.distance(origin, point) >= Self.movementSlop else { return [] }
                mode = .scrolling
                longPressDeadline = nil
                return scrollEvents(phase: .began, from: origin, to: point) + [Self.touch(point, .changed)]
            case .scrolling:
                let events = scrollEvents(phase: .changed, from: lastScroll, to: point)
                guard !events.isEmpty else { return [] }
                return events + [Self.touch(point, .changed)]
            case .held:
                guard Self.distance(origin, point) >= Self.movementSlop else { return [] }
                mode = .dragging
                return [.leftDown(origin), .leftDrag(point), Self.touch(point, .changed)]
            case .dragging:
                return [.leftDrag(point), Self.touch(point, .changed)]
            case .idle:
                return []
            }
        case .up:
            guard mode != .idle else { return [] }
            current = point
            return finish(lifted: true)
        }
    }

    /// Marks the contact as held once `time` has reached `longPressDeadline`.
    /// Lifting from here right-clicks; moving past `movementSlop` starts a left-button drag.
    mutating func fireLongPress(time: TimeInterval) -> [PointerInjection] {
        guard mode == .pending, let deadline = longPressDeadline, time >= deadline else { return [] }
        mode = .held
        longPressDeadline = nil
        return [Self.touch(current, .changed)]
    }

    /// Ends an open scroll or drag without turning an undecided touch into a click.
    mutating func cancel() -> [PointerInjection] {
        finish(lifted: false)
    }

    private mutating func finish(lifted: Bool) -> [PointerInjection] {
        let ending = mode
        let point = current
        mode = .idle
        longPressDeadline = nil
        switch ending {
        case .idle:
            return []
        case .pending:
            guard lifted else { return [Self.touch(point, .cancelled)] }
            return [.leftClick(origin), Self.touch(point, .ended)]
        case .scrolling:
            var events = scrollEvents(phase: .changed, from: lastScroll, to: point)
            events.append(.scroll(ScrollWheelPayload(point: origin, deltaX: 0, deltaY: 0, phase: .ended)))
            events.append(Self.touch(point, lifted ? .ended : .cancelled))
            return events
        case .held:
            guard lifted else { return [Self.touch(point, .cancelled)] }
            return [.rightDown(origin), .rightUp(origin), Self.touch(point, .ended)]
        case .dragging:
            return [.leftUp(point), Self.touch(point, lifted ? .ended : .cancelled)]
        }
    }

    private static func touch(_ point: CGPoint, _ phase: CGScrollPhase) -> PointerInjection {
        .directTouch(DirectTouchEvent(point: point, phase: phase))
    }

    private mutating func scrollEvents(phase: CGScrollPhase, from: CGPoint, to: CGPoint) -> [PointerInjection] {
        let dx = Self.ticks(to.x - from.x)
        let dy = Self.ticks(to.y - from.y)
        if phase == .changed, dx == 0, dy == 0 { return [] }
        lastScroll = to
        return [.scroll(ScrollWheelPayload(point: origin, deltaX: dx, deltaY: dy, phase: phase))]
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func ticks(_ value: CGFloat) -> Int32 {
        let rounded = value.rounded()
        if rounded >= CGFloat(Int32.max) { return Int32.max }
        if rounded <= CGFloat(Int32.min) { return Int32.min }
        return Int32(rounded)
    }
}

extension TrackpadScrollPhase {
    /// `kCGScrollPhaseEnded` is 4, so the wire value cannot be passed through raw.
    var cgScrollPhase: CGScrollPhase {
        switch self {
        case .began: return .began
        case .changed: return .changed
        case .ended: return .ended
        case .cancelled: return .cancelled
        }
    }
}

/// Posts pointer events for Pencil messages. Desktop switching does not come through here.
///
/// `contact == .button` stays a left-button drag so sliders, window moves, and
/// text selection still see a mouse button. TN3212 gathers recognizers at mouse-down, so a pan
/// recognizer whose `buttonMask` includes the primary button can observe that drag. It is not an
/// `NSTouch` list. `contact == .finger` follows `FingerContactTracker` instead of holding the left
/// button, and also posts a direct-touch event at the Pencil point. A finger pan is still a scroll.
final class MacPointer {
    private let lock = NSLock()
    private let displayIndex: Int?
    private var displayID: CGDirectDisplayID
    private var capturedDisplay = false
    private var frameWidth = 0
    private var frameHeight = 0
    private var buttonDown = false
    private var lastPoint: CGPoint?
    private var finger = FingerContactTracker()
    /// Cursor location where the open virtual-trackpad scroll began. Later samples
    /// stay there so the gesture keeps hitting the view that received `began`.
    private var trackpadScrollOrigin: CGPoint?
    /// Preferences captured when the open scroll began, so a settings change mid-flick
    /// does not reverse the gesture.
    private var activeScrollPreferences = TrackpadPreferences.factory
    /// Last live read. Tracking speed is refreshed with the rest of the pane, but not
    /// on every pointer sample.
    private var cachedPreferences = TrackpadPreferences.factory
    private var preferencesFetchedAt = -TimeInterval.greatestFiniteMagnitude
    /// Leftover fraction after scaling one-finger travel by tracking speed.
    private var moveResidualX = 0.0
    private var moveResidualY = 0.0
    /// Left button held for a three-finger drag on the virtual trackpad.
    private var trackpadDragDown = false
    /// Wheel-space samples for the open scroll, used to coast when momentum is on.
    private var scrollSamples: [(dx: Int32, dy: Int32, time: TimeInterval)] = []
    private var momentumState: TrackpadMomentum?
    private var momentumOrigin: CGPoint?
    private var momentumTimer: DispatchSourceTimer?
    private var momentumToken: UInt = 0
    private var momentumDidBegin = false
    private var longPressTimer: DispatchSourceTimer?
    private var longPressToken: UInt = 0
    private let longPressQueue = DispatchQueue(label: "sketchintent.pointer.longpress")
    private var didLogAccessibility = false

    init(displayIndex: Int?) {
        self.displayIndex = displayIndex
        displayID = CGMainDisplayID()
    }

    deinit {
        longPressTimer?.cancel()
        momentumTimer?.cancel()
    }

    func noteDisplay(_ id: CGDirectDisplayID) {
        lock.lock()
        displayID = id
        capturedDisplay = true
        lock.unlock()
    }

    func noteFrame(width: Int, height: Int) {
        lock.lock()
        frameWidth = width
        frameHeight = height
        lock.unlock()
    }

    func post(phase: PointerPhase, x: UInt16, y: UInt16, contact: PointerContact = .button) {
        lock.lock()
        let momentumEnd = cancelMomentumLocked()
        let events = lockedEvents(phase: phase, x: x, y: y, contact: contact)
        lock.unlock()
        postScroll(momentumEnd)
        deliver(events)
    }

    /// One-finger travel on the virtual trackpad. Positive `dy` is down, in the same
    /// top-left coordinate space `CGEvent` uses for the cursor. Distance is scaled
    /// by the Mac tracking-speed setting.
    func postTrackpadMove(dx: Int16, dy: Int16) {
        guard dx != 0 || dy != 0 else { return }
        let scale = TrackpadMapping.pointerScale(trackingSpeed: preferences().trackingSpeed)
        lock.lock()
        let momentumEnd = cancelMomentumLocked()
        let releaseDrag = cancelTrackpadDragLocked()
        let scaled = takeMoveResidualLocked(dx: dx, dy: dy, scale: scale)
        guard accessibilityTrusted() else {
            lock.unlock()
            postScroll(momentumEnd)
            if releaseDrag { releaseTrackpadButton() }
            return
        }
        lock.unlock()
        postScroll(momentumEnd)
        if releaseDrag { releaseTrackpadButton() }
        guard scaled.x != 0 || scaled.y != 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let cursor = CGEvent(source: source)?.location else { return }
        let point = CGPoint(x: cursor.x + CGFloat(scaled.x), y: cursor.y + CGFloat(scaled.y))
        postMouse(.mouseMoved, point: point, button: .left, source: source, touch: false)
    }

    /// One-finger hold-and-drag, or three-finger travel when three-finger drag is on.
    func postTrackpadDrag(dx: Int16, dy: Int16, phase: PointerPhase, fingers: UInt8) {
        let allowed = fingers == 1 || (fingers >= 3 && preferences(force: phase == .down).threeFingerDrag)
        let scale = TrackpadMapping.pointerScale(trackingSpeed: preferences().trackingSpeed)
        lock.lock()
        let momentumEnd = cancelMomentumLocked()
        guard allowed, accessibilityTrusted() else {
            let releaseDrag = cancelTrackpadDragLocked()
            lock.unlock()
            postScroll(momentumEnd)
            if releaseDrag { releaseTrackpadButton() }
            return
        }
        let scaled = takeMoveResidualLocked(dx: dx, dy: dy, scale: scale)
        let pressing = trackpadDragDown
        if phase == .up {
            trackpadDragDown = false
        } else {
            trackpadDragDown = true
        }
        lock.unlock()
        postScroll(momentumEnd)
        let source = CGEventSource(stateID: .hidSystemState)
        guard let cursor = CGEvent(source: source)?.location else { return }
        var point = cursor
        if scaled.x != 0 || scaled.y != 0 {
            point = CGPoint(x: cursor.x + CGFloat(scaled.x), y: cursor.y + CGFloat(scaled.y))
        }
        switch phase {
        case .down:
            postMouse(.leftMouseDown, point: cursor, button: .left, source: source, touch: false)
            if point != cursor {
                postMouse(.leftMouseDragged, point: point, button: .left, source: source, touch: false)
            }
        case .move:
            if !pressing {
                postMouse(.leftMouseDown, point: cursor, button: .left, source: source, touch: false)
            }
            postMouse(.leftMouseDragged, point: point, button: .left, source: source, touch: false)
        case .up:
            if pressing || scaled.x != 0 || scaled.y != 0 {
                if !pressing {
                    postMouse(.leftMouseDown, point: cursor, button: .left, source: source, touch: false)
                }
                if point != cursor {
                    postMouse(.leftMouseDragged, point: point, button: .left, source: source, touch: false)
                }
                postMouse(.leftMouseUp, point: point, button: .left, source: source, touch: false)
            }
        }
    }

    /// Two-finger travel. Positive `dy` is down, as on the pad. Scroll direction,
    /// horizontal scrolling, and momentum follow the Mac trackpad preferences.
    func postTrackpadScroll(dx: Int16, dy: Int16, phase: TrackpadScrollPhase) {
        let freshPreferences = phase == .began ? preferences(force: true) : nil
        lock.lock()
        var momentumEnd: ScrollWheelPayload?
        if phase == .began {
            momentumEnd = cancelMomentumLocked()
            if let freshPreferences {
                activeScrollPreferences = freshPreferences
            }
            scrollSamples.removeAll()
        }
        let releaseDrag = phase == .began && cancelTrackpadDragLocked()
        let scrollPreferences = activeScrollPreferences
        guard accessibilityTrusted() else {
            if phase == .ended || phase == .cancelled {
                trackpadScrollOrigin = nil
                scrollSamples.removeAll()
            }
            lock.unlock()
            postScroll(momentumEnd)
            if releaseDrag { releaseTrackpadButton() }
            return
        }
        guard scrollPreferences.scroll else {
            if phase == .ended || phase == .cancelled {
                trackpadScrollOrigin = nil
                scrollSamples.removeAll()
            }
            lock.unlock()
            postScroll(momentumEnd)
            if releaseDrag { releaseTrackpadButton() }
            return
        }
        let wheel = TrackpadMapping.wheelDelta(
            fingerDX: Int32(dx),
            fingerDY: Int32(dy),
            preferences: scrollPreferences
        ) ?? (x: 0, y: 0)
        let source = CGEventSource(stateID: .hidSystemState)
        let cursor = CGEvent(source: source)?.location
        let point: CGPoint
        switch phase {
        case .began:
            guard let cursor else {
                lock.unlock()
                postScroll(momentumEnd)
                if releaseDrag { releaseTrackpadButton() }
                return
            }
            trackpadScrollOrigin = cursor
            point = cursor
        case .changed, .ended, .cancelled:
            if trackpadScrollOrigin == nil {
                trackpadScrollOrigin = cursor
            }
            guard let origin = trackpadScrollOrigin else {
                lock.unlock()
                postScroll(momentumEnd)
                if releaseDrag { releaseTrackpadButton() }
                return
            }
            point = origin
            if phase == .ended || phase == .cancelled {
                trackpadScrollOrigin = nil
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if (phase == .began || phase == .changed) && (wheel.x != 0 || wheel.y != 0) {
            scrollSamples.append((dx: wheel.x, dy: wheel.y, time: now))
        }
        let samples = phase == .ended ? scrollSamples : []
        let momentum = phase == .ended && scrollPreferences.momentumScroll
        if phase == .ended || phase == .cancelled {
            scrollSamples.removeAll()
        }
        lock.unlock()
        postScroll(momentumEnd)
        if releaseDrag { releaseTrackpadButton() }
        if phase == .changed, wheel.x == 0, wheel.y == 0 { return }
        ScrollWheelPayload(
            point: point,
            deltaX: wheel.x,
            deltaY: wheel.y,
            phase: phase.cgScrollPhase
        ).makeEvent(source: source)?.post(tap: .cghidEventTap)
        if momentum {
            startMomentum(samples: samples, origin: point)
        }
    }

    /// Two-finger pinch, as a magnify gesture at the cursor. `magnification` is in
    /// ten-thousandths, as on the wire. It follows the Mac's "Zoom in or out" setting.
    func postTrackpadMagnify(magnification: Int16, phase: TrackpadScrollPhase) {
        let allowed = phase == .began ? preferences(force: true).zoom : preferences().zoom
        lock.lock()
        let momentumEnd = phase == .began ? cancelMomentumLocked() : nil
        let releaseDrag = phase == .began && cancelTrackpadDragLocked()
        let trusted = accessibilityTrusted()
        lock.unlock()
        postScroll(momentumEnd)
        if releaseDrag { releaseTrackpadButton() }
        guard trusted, allowed else { return }
        if phase == .changed, magnification == 0 { return }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let cursor = CGEvent(source: source)?.location else { return }
        MagnifyGestureEvent(
            point: cursor,
            magnification: Double(magnification) / 10_000,
            phase: phase.cgScrollPhase
        ).makeEvent(source: source)?.post(tap: .cghidEventTap)
    }

    /// A tap on the pad. The button comes from tap-to-click and secondary click.
    /// A preference that produces no click still stops an open coast.
    func postTrackpadTap(fingers: UInt8, zone: TrackpadTapZone) {
        let button = TrackpadMapping.click(
            fingers: Int(fingers),
            zone: zone,
            preferences: preferences(force: true)
        )
        lock.lock()
        let momentumEnd = cancelMomentumLocked()
        let releaseDrag = cancelTrackpadDragLocked()
        guard accessibilityTrusted() else {
            lock.unlock()
            postScroll(momentumEnd)
            if releaseDrag { releaseTrackpadButton() }
            return
        }
        lock.unlock()
        postScroll(momentumEnd)
        if releaseDrag { releaseTrackpadButton() }
        guard let button else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let cursor = CGEvent(source: source)?.location else { return }
        let mouse: CGMouseButton = button == .left ? .left : .right
        let down: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let up: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        postMouse(down, point: cursor, button: mouse, source: source, touch: false)
        postMouse(up, point: cursor, button: mouse, source: source, touch: false)
    }

    /// Left or right click where the cursor already is. A tap is down then up.
    func postTrackpadClick(button: TrackpadButton, phase: PointerPhase) {
        lock.lock()
        let momentumEnd = cancelMomentumLocked()
        guard accessibilityTrusted() else {
            lock.unlock()
            postScroll(momentumEnd)
            return
        }
        lock.unlock()
        postScroll(momentumEnd)
        let source = CGEventSource(stateID: .hidSystemState)
        guard let cursor = CGEvent(source: source)?.location else { return }
        let type: CGEventType
        let mouse: CGMouseButton
        switch (button, phase) {
        case (.left, .down):
            type = .leftMouseDown
            mouse = .left
        case (.left, .up):
            type = .leftMouseUp
            mouse = .left
        case (.right, .down):
            type = .rightMouseDown
            mouse = .right
        case (.right, .up):
            type = .rightMouseUp
            mouse = .right
        case (_, .move):
            return
        }
        postMouse(type, point: cursor, button: mouse, source: source, touch: false)
    }

    /// Live pane, reused for a fraction of a second so a drag does not resynchronize
    /// preferences on every sample. `force` is for the start of a gesture.
    private func preferences(force: Bool = false) -> TrackpadPreferences {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if !force, now - preferencesFetchedAt < 0.25 {
            let cached = cachedPreferences
            lock.unlock()
            return cached
        }
        lock.unlock()
        let loaded = TrackpadPreferences.load()
        lock.lock()
        cachedPreferences = loaded
        preferencesFetchedAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        return loaded
    }

    /// Called with `lock` held. Scaled pixels, keeping the fraction for the next sample.
    private func takeMoveResidualLocked(dx: Int16, dy: Int16, scale: Double) -> (x: Int32, y: Int32) {
        moveResidualX += Double(dx) * scale
        moveResidualY += Double(dy) * scale
        let ix = Int32(moveResidualX.rounded(.towardZero))
        let iy = Int32(moveResidualY.rounded(.towardZero))
        moveResidualX -= Double(ix)
        moveResidualY -= Double(iy)
        return (ix, iy)
    }

    /// Called with `lock` held. True when a three-finger drag still had the button down.
    private func cancelTrackpadDragLocked() -> Bool {
        let down = trackpadDragDown
        trackpadDragDown = false
        return down
    }

    private func releaseTrackpadButton() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let cursor = CGEvent(source: source)?.location else { return }
        postMouse(.leftMouseUp, point: cursor, button: .left, source: source, touch: false)
    }

    /// Called with `lock` held. The returned event closes an open coast and is posted
    /// after the lock is released.
    private func cancelMomentumLocked() -> ScrollWheelPayload? {
        momentumToken &+= 1
        momentumTimer?.cancel()
        momentumTimer = nil
        let origin = momentumOrigin
        let running = momentumState != nil
        momentumState = nil
        momentumOrigin = nil
        momentumDidBegin = false
        guard running, let origin else { return nil }
        return ScrollWheelPayload(point: origin, deltaX: 0, deltaY: 0, phase: .ended, momentum: .end)
    }

    private func startMomentum(samples: [(dx: Int32, dy: Int32, time: TimeInterval)], origin: CGPoint) {
        guard let momentum = TrackpadMomentum.starting(samples: samples) else { return }
        lock.lock()
        momentumTimer?.cancel()
        momentumToken &+= 1
        let token = momentumToken
        momentumState = momentum
        momentumOrigin = origin
        momentumDidBegin = false
        let timer = DispatchSource.makeTimerSource(queue: longPressQueue)
        timer.schedule(deadline: .now() + .milliseconds(16), repeating: .milliseconds(16), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            self?.stepMomentum(token: token)
        }
        momentumTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func stepMomentum(token: UInt) {
        lock.lock()
        guard token == momentumToken, let state = momentumState, let origin = momentumOrigin else {
            lock.unlock()
            return
        }
        let opening = !momentumDidBegin
        momentumDidBegin = true
        let stepped = state.advance(dt: 1.0 / 60.0)
        let finished = stepped.next == nil
        momentumState = stepped.next
        if finished {
            momentumTimer?.cancel()
            momentumTimer = nil
            momentumOrigin = nil
            momentumState = nil
            momentumDidBegin = false
        }
        lock.unlock()
        let source = CGEventSource(stateID: .hidSystemState)
        let phase: CGMomentumScrollPhase = opening ? .begin : .continuous
        ScrollWheelPayload(
            point: origin,
            deltaX: stepped.dx,
            deltaY: stepped.dy,
            phase: .ended,
            momentum: phase
        ).makeEvent(source: source)?.post(tap: .cghidEventTap)
        if finished {
            ScrollWheelPayload(
                point: origin,
                deltaX: 0,
                deltaY: 0,
                phase: .ended,
                momentum: .end
            ).makeEvent(source: source)?.post(tap: .cghidEventTap)
        }
    }

    private func postScroll(_ payload: ScrollWheelPayload?) {
        guard let payload else { return }
        payload.makeEvent(source: CGEventSource(stateID: .hidSystemState))?.post(tap: .cghidEventTap)
    }

    private func lockedEvents(phase: PointerPhase, x: UInt16, y: UInt16, contact: PointerContact) -> [PointerInjection] {
        guard accessibilityTrusted() else { return [] }
        guard frameWidth > 0, frameHeight > 0 else { return [] }
        let bounds = CGDisplayBounds(resolvedDisplayID())
        let pixels = Self.pixelSize(displayID: resolvedDisplayID(), bounds: bounds)
        let mapped = PointerGeometry.globalPoint(
            x: x,
            y: y,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            bounds: bounds,
            pixelWidth: pixels.width,
            pixelHeight: pixels.height
        )
        let point = mapped ?? ((phase == .up) ? lastPoint : nil)
        guard let point else { return [] }
        lastPoint = point

        switch contact {
        case .button:
            var events = finger.cancel()
            invalidateLongPressLocked()
            events.append(contentsOf: buttonEvents(phase: phase, point: point))
            return events
        case .finger:
            var events = releaseButtonLocked()
            let time = ProcessInfo.processInfo.systemUptime
            events.append(contentsOf: finger.handle(phase: phase, point: point, time: time))
            scheduleLongPressLocked()
            return events
        }
    }

    /// Left-button drag. Move and up are ignored unless a down is still held.
    private func buttonEvents(phase: PointerPhase, point: CGPoint) -> [PointerInjection] {
        if phase != .down && !buttonDown { return [] }
        let injection: PointerInjection
        switch phase {
        case .down:
            injection = .leftDown(point)
            buttonDown = true
        case .move:
            injection = .leftDrag(point)
        case .up:
            injection = .leftUp(point)
            buttonDown = false
        }
        return [injection]
    }

    private func releaseButtonLocked() -> [PointerInjection] {
        guard buttonDown, let lastPoint else {
            buttonDown = false
            return []
        }
        buttonDown = false
        return [.leftUp(lastPoint)]
    }

    private func invalidateLongPressLocked() {
        longPressToken &+= 1
        longPressTimer?.cancel()
        longPressTimer = nil
    }

    /// Called with `lock` held. The timer handler takes the lock only after this returns.
    private func scheduleLongPressLocked() {
        invalidateLongPressLocked()
        guard let deadline = finger.longPressDeadline else { return }
        let token = longPressToken
        let delay = deadline - ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: longPressQueue)
        timer.schedule(deadline: .now() + max(delay, 0), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            self?.fireLongPress(token: token)
        }
        longPressTimer = timer
        timer.resume()
    }

    private func fireLongPress(token: UInt) {
        lock.lock()
        guard token == longPressToken else {
            lock.unlock()
            return
        }
        let events = finger.fireLongPress(time: ProcessInfo.processInfo.systemUptime)
        longPressTimer = nil
        lock.unlock()
        deliver(events)
    }

    private func deliver(_ events: [PointerInjection]) {
        guard !events.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for injection in events {
            switch injection {
            case .move(let point):
                postMouse(.mouseMoved, point: point, button: .left, source: source, touch: true)
            case .leftClick(let point):
                postMouse(.leftMouseDown, point: point, button: .left, source: source, touch: true)
                postMouse(.leftMouseUp, point: point, button: .left, source: source, touch: true)
            case .leftDown(let point):
                postMouse(.leftMouseDown, point: point, button: .left, source: source, touch: false)
            case .leftDrag(let point):
                postMouse(.leftMouseDragged, point: point, button: .left, source: source, touch: false)
            case .leftUp(let point):
                postMouse(.leftMouseUp, point: point, button: .left, source: source, touch: false)
            case .rightDown(let point):
                postMouse(.rightMouseDown, point: point, button: .right, source: source, touch: true)
            case .rightDrag(let point):
                postMouse(.rightMouseDragged, point: point, button: .right, source: source, touch: true)
            case .rightUp(let point):
                postMouse(.rightMouseUp, point: point, button: .right, source: source, touch: true)
            case .scroll(let payload):
                payload.makeEvent(source: source)?.post(tap: .cghidEventTap)
            case .directTouch(let touch):
                touch.makeEvent(source: source)?.post(tap: .cghidEventTap)
            }
        }
    }

    /// `touch` sets `NSEventSubtypeTouch` so AppKit can tell a finger click from a mouse button.
    private func postMouse(
        _ type: CGEventType,
        point: CGPoint,
        button: CGMouseButton,
        source: CGEventSource?,
        touch: Bool
    ) {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }
        if touch {
            event.setIntegerValueField(.mouseEventSubtype, value: DirectTouchEvent.touchSubtype)
        }
        event.post(tap: .cghidEventTap)
    }

    /// The display being captured. `CGMainDisplayID` until capture reports otherwise,
    /// or the display at `ServerConfig.displayIndex` when that flag is set.
    private func resolvedDisplayID() -> CGDirectDisplayID {
        if capturedDisplay { return displayID }
        if let displayIndex, let indexed = Self.activeDisplay(at: displayIndex) {
            return indexed
        }
        return CGMainDisplayID()
    }

    /// Checked at launch. Posting pointer events needs Accessibility, which macOS grants
    /// to the process that launched the server. Asks for it, then fails if it is still off.
    static func ensureAccess() throws {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        let canPost = CGPreflightPostEventAccess() || CGRequestPostEventAccess()
        guard trusted, canPost else { throw PointerAccessError.accessibilityDenied }
    }

    private func accessibilityTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !didLogAccessibility {
            didLogAccessibility = true
            fputs(
                "[sketchintent] Pencil clicks are not being sent. System Settings → Privacy & Security → Accessibility must allow the process that launched the server.\n",
                stderr
            )
        }
        return false
    }

    private static func pixelSize(displayID: CGDirectDisplayID, bounds: CGRect) -> (width: Int, height: Int) {
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            let width = mode.pixelWidth
            let height = mode.pixelHeight
            if width > 0, height > 0 {
                return (width, height)
            }
        }
        return (max(0, Int(bounds.width.rounded())), max(0, Int(bounds.height.rounded())))
    }

    private static func activeDisplay(at index: Int) -> CGDirectDisplayID? {
        guard index >= 0 else { return nil }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, index < count else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success, index < ids.count else { return nil }
        return ids[index]
    }
}
