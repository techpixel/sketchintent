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

/// Posts left-mouse events for Pencil pointer messages. Desktop switching does not come through here.
final class MacPointer {
    private let lock = NSLock()
    private let displayIndex: Int?
    private var displayID: CGDirectDisplayID
    private var capturedDisplay = false
    private var frameWidth = 0
    private var frameHeight = 0
    private var buttonDown = false
    private var lastPoint: CGPoint?
    private var didLogAccessibility = false

    init(displayIndex: Int?) {
        self.displayIndex = displayIndex
        displayID = CGMainDisplayID()
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

    func post(phase: PointerPhase, x: UInt16, y: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        guard accessibilityTrusted() else { return }
        guard frameWidth > 0, frameHeight > 0 else { return }
        if phase != .down && !buttonDown { return }

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
        let point = mapped ?? (phase == .up ? lastPoint : nil)
        guard let point else { return }

        let type: CGEventType
        switch phase {
        case .down:
            type = .leftMouseDown
        case .move:
            type = .leftMouseDragged
        case .up:
            type = .leftMouseUp
        }
        guard let event = CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        event.post(tap: .cghidEventTap)
        lastPoint = point
        switch phase {
        case .down:
            buttonDown = true
        case .up:
            buttonDown = false
        case .move:
            break
        }
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
