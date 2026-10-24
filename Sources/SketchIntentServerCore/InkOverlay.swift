import AppKit
import CoreGraphics
import Foundation
import StreamProtocol

/// Draws iPad pen ink on top of the captured display.
///
/// The window is the display bounds, and the PNG is stretched across it, so captured-frame
/// pixels land on the same pixels the picture used. It ignores clicks. ScreenCaptureKit is
/// pointed away from it, and the window's sharing type is none, so the ink is not encoded
/// back into the H.264 stream.
final class InkOverlay {
    private var window: NSWindow?
    private var displayID: CGDirectDisplayID?
    private var spaceID: String?
    private var displayedSpaceID: String?
    private var pending: InkSnapshot?
    private var canShowInk = false
    private var exclusionAttempts = 0
    private var exclusionInFlight = false
    private var didLogUndecodable = false
    private var exclude: ((CGWindowID, @escaping (Bool) -> Void) -> Void)?
    private var screenObserver: NSObjectProtocol?

    func place(on displayID: CGDirectDisplayID, exclude: @escaping (CGWindowID, @escaping (Bool) -> Void) -> Void) {
        let work = {
            self.displayID = displayID
            self.exclude = exclude
            self.ensureWindow()
            self.layoutOnDisplay()
            self.beginExclusionIfNeeded()
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// The desktop on the streamed display changed. Drop whatever ink was showing
    /// unless it already belongs to this desktop. The iPad then sends that desktop's drawing.
    func noteSpace(_ id: String) {
        let work = {
            guard self.spaceID != id else { return }
            self.spaceID = id
            if self.displayedSpaceID == id {
                self.applyPending()
                return
            }
            self.displayedSpaceID = nil
            self.inkView?.image = nil
            self.applyPending()
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    func show(_ ink: InkSnapshot) {
        DispatchQueue.main.async {
            self.pending = ink
            self.applyPending()
        }
    }

    private var inkView: InkOverlayView? {
        window?.contentView as? InkOverlayView
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.animationBehavior = .none
        // Shareable until ScreenCaptureKit has excluded it, then locked off.
        window.sharingType = .readOnly
        let view = InkOverlayView(frame: window.contentView?.bounds ?? .zero)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.layoutOnDisplay()
        }
    }

    private func layoutOnDisplay() {
        guard let displayID, let window else { return }
        guard let frame = screenFrame(displayID: displayID), frame.width > 1, frame.height > 1 else { return }
        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
        if !canShowInk {
            window.orderFrontRegardless()
        }
    }

    /// Gives ScreenCaptureKit a chance to list the window and drop it from the stream
    /// before any ink is drawn. After that, sharing type none keeps later frames clean.
    private func beginExclusionIfNeeded() {
        guard !canShowInk, !exclusionInFlight else { return }
        guard let window, window.windowNumber > 0, let exclude else { return }
        exclusionInFlight = true
        let windowID = CGWindowID(window.windowNumber)
        exclude(windowID) { [weak self] found in
            guard let self else { return }
            self.exclusionInFlight = false
            if found || self.exclusionAttempts >= 4 {
                self.window?.sharingType = .none
                self.canShowInk = true
                if !found {
                    fputs("[sketchintent] Ink overlay uses window sharing none so capture skips it.\n", stderr)
                }
                self.applyPending()
                return
            }
            self.exclusionAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.beginExclusionIfNeeded()
            }
        }
    }

    private func applyPending() {
        guard canShowInk, let ink = pending else { return }
        if let spaceID, ink.spaceID.isEmpty || ink.spaceID != spaceID { return }
        apply(ink)
    }

    private func apply(_ ink: InkSnapshot) {
        displayedSpaceID = ink.spaceID.isEmpty ? spaceID : ink.spaceID
        guard let inkView else { return }
        guard !ink.png.isEmpty else {
            inkView.image = nil
            return
        }
        guard let image = NSImage(data: ink.png) else {
            if !didLogUndecodable {
                didLogUndecodable = true
                fputs("[sketchintent] Ink PNG could not be decoded.\n", stderr)
            }
            return
        }
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            image.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        } else if ink.width > 0, ink.height > 0 {
            image.size = NSSize(width: ink.width, height: ink.height)
        }
        inkView.image = image
        window?.orderFrontRegardless()
    }

    private func screenFrame(displayID: CGDirectDisplayID) -> NSRect? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            if CGDirectDisplayID(number.uint32Value) == displayID {
                return screen.frame
            }
        }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let primary = CGDisplayBounds(CGMainDisplayID())
        return NSRect(
            x: bounds.origin.x,
            y: primary.height - bounds.origin.y - bounds.height,
            width: bounds.width,
            height: bounds.height
        )
    }
}

/// Stretches one frame-sized PNG across the display. The view is flipped so the
/// top of the PNG is the top of the screen, matching captured-frame pixels.
private final class InkOverlayView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        guard let image else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }
}
