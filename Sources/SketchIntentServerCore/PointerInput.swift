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
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(CGMomentumScrollPhase.none.rawValue))
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
/// not a button held for the whole touch. A drag is a continuous pixel `scrollWheel` with
/// `kCGScrollWheelEventScrollPhase` began, changed, and ended. The event location stays at the
/// touch-down point, because AppKit delivers a gesture scroll to the view under the cursor when
/// the phase began (`NSEvent.phase`). A hold without that movement is `rightMouseDown`, then
/// `rightMouseDragged`, then `rightMouseUp`.
///
/// Magnify and rotate are not produced. TN3212 ties those to a two-finger pinch or rotation,
/// and this tracker has one point. Each phase also posts a direct-touch event at the Pencil
/// point. Mouse clicks from this tracker are marked `NSEventSubtypeTouch`.
struct FingerContactTracker {
    static let movementSlop: CGFloat = 6
    /// `NSPressGestureRecognizer.minimumPressDuration` is "appropriate for touch" and not a fixed
    /// public number. Half a second is the hold that becomes the right-click above.
    static let longPressDuration: TimeInterval = 0.5

    private enum Mode {
        case idle
        case pending
        case scrolling
        case pressing
    }

    private var mode: Mode = .idle
    private var origin: CGPoint = .zero
    private var current: CGPoint = .zero
    private var lastScroll: CGPoint = .zero
    /// `ProcessInfo.systemUptime` deadline while the contact is still undecided. Nil once it scrolls or presses.
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
            case .pressing:
                return [.rightDrag(point), Self.touch(point, .changed)]
            case .idle:
                return []
            }
        case .up:
            guard mode != .idle else { return [] }
            current = point
            return finish(lifted: true)
        }
    }

    /// Begins the right-click once `time` has reached `longPressDeadline`.
    mutating func fireLongPress(time: TimeInterval) -> [PointerInjection] {
        guard mode == .pending, let deadline = longPressDeadline, time >= deadline else { return [] }
        mode = .pressing
        longPressDeadline = nil
        return [.rightDown(current), Self.touch(current, .changed)]
    }

    /// Ends an open scroll or right-click without turning an undecided touch into a click.
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
        case .pressing:
            return [.rightUp(point), Self.touch(point, lifted ? .ended : .cancelled)]
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
        let events = lockedEvents(phase: phase, x: x, y: y, contact: contact)
        lock.unlock()
        deliver(events)
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
