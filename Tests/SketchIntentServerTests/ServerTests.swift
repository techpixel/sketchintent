import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import XCTest
import StreamProtocol
@testable import SketchIntentServerCore

final class ServerTests: XCTestCase {
    func testConfigParsesFlags() {
        let config = ServerConfig.parse([
            "--fps", "12",
            "--bitrate", "18",
            "--max-width", "1280",
            "--tcp-port", "2400",
            "--usb-port", "2401",
            "--display", "1"
        ])
        XCTAssertEqual(config.fps, 12)
        XCTAssertEqual(config.bitrate, 18_000_000)
        XCTAssertEqual(config.maxWidth, 1280)
        XCTAssertEqual(config.tcpPort, 2400)
        XCTAssertEqual(config.usbPort, 2401)
        XCTAssertEqual(config.displayIndex, 1)
    }

    func testSessionDeliversHelloAndJPEG() throws {
        let listener = try POSIX.listenTCP(port: 0)
        defer { POSIX.close(listener) }
        let port = try POSIX.boundPort(listener)

        let accepted = FDBox()
        let ready = DispatchSemaphore(value: 0)
        Thread {
            accepted.fd = Darwin.accept(listener, nil, nil)
            ready.signal()
        }.start()

        let client = try POSIX.connectTCP(host: "127.0.0.1", port: port)
        defer { POSIX.close(client) }
        XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
        XCTAssertGreaterThanOrEqual(accepted.fd, 0)
        POSIX.configure(accepted.fd)

        let session = StreamSession(fd: accepted.fd, label: "test")
        session.start()
        let hello = StreamHello(name: "Test", width: 16, height: 10)
        session.offerHello(hello)
        let frame = VideoFrame(isKeyframe: true, presentationMicros: 1000, data: Data([9, 8, 7, 6]))
        session.offer(StreamFraming.encode(.videoFrame(frame)), kind: .frame(keyframe: true))

        let parser = StreamParser()
        var messages: [StreamMessage] = []
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && messages.count < 2 {
            var pollState = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let readyCount = poll(&pollState, 1, 200)
            guard readyCount > 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            messages.append(contentsOf: try parser.append(Data(buffer.prefix(count))))
        }
        session.stop()

        XCTAssertEqual(messages.first, .hello(hello))
        XCTAssertTrue(messages.contains(.videoFrame(frame)))
    }

    func testSessionRequestsKeyframeWhenFramesQueueUp() {
        let listener = try? POSIX.listenTCP(port: 0)
        XCTAssertNotNil(listener)
        guard let listener else { return }
        defer { POSIX.close(listener) }
        let port = try? POSIX.boundPort(listener)
        XCTAssertNotNil(port)
        guard let port else { return }

        let accepted = FDBox()
        let ready = DispatchSemaphore(value: 0)
        Thread {
            accepted.fd = Darwin.accept(listener, nil, nil)
            ready.signal()
        }.start()

        let client = try? POSIX.connectTCP(host: "127.0.0.1", port: port)
        XCTAssertNotNil(client)
        guard let client else { return }
        defer { POSIX.close(client) }
        XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
        POSIX.configure(accepted.fd)

        let session = StreamSession(fd: accepted.fd, label: "test")
        let behind = DispatchSemaphore(value: 0)
        session.onBehind = { behind.signal() }
        // The writer is not running yet, so these frames sit in the queue.
        for index in 0..<3 {
            let frame = VideoFrame(isKeyframe: false, presentationMicros: UInt64(index), data: Data([1, 2, 3, 4]))
            session.offer(StreamFraming.encode(.videoFrame(frame)), kind: .frame(keyframe: false))
        }
        XCTAssertEqual(behind.wait(timeout: .now() + 1), .success)
        session.start()
        session.stop()
    }

    func testSessionReadsDesktopSwipe() throws {
        let listener = try POSIX.listenTCP(port: 0)
        defer { POSIX.close(listener) }
        let port = try POSIX.boundPort(listener)

        let accepted = FDBox()
        let ready = DispatchSemaphore(value: 0)
        Thread {
            accepted.fd = Darwin.accept(listener, nil, nil)
            ready.signal()
        }.start()

        let client = try POSIX.connectTCP(host: "127.0.0.1", port: port)
        defer { POSIX.close(client) }
        XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
        POSIX.configure(accepted.fd)

        let session = StreamSession(fd: accepted.fd, label: "test")
        let received = InputBox()
        let delivered = DispatchSemaphore(value: 0)
        session.onInput = { input in
            received.value = input
            delivered.signal()
        }
        session.start()

        let packet = StreamFraming.encode(.input(.switchDesktop(.right)))
        XCTAssertTrue(POSIX.writeAll(client, packet))
        XCTAssertEqual(delivered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(received.value, .switchDesktop(.right))
        session.stop()
    }

    func testPointerPixelsDivideByDisplayScale() {
        let bounds = CGRect(x: -100, y: 40, width: 1000, height: 500)
        let point = PointerGeometry.globalPoint(
            x: 1000, y: 500,
            frameWidth: 2000, frameHeight: 1000,
            bounds: bounds,
            pixelWidth: 2000, pixelHeight: 1000
        )
        XCTAssertEqual(point?.x ?? 0, 400, accuracy: 0.001)
        XCTAssertEqual(point?.y ?? 0, 290, accuracy: 0.001)
    }

    func testDownscaledFrameStillCoversTheDisplay() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let point = PointerGeometry.globalPoint(
            x: 500, y: 250,
            frameWidth: 1000, frameHeight: 500,
            bounds: bounds,
            pixelWidth: 2000, pixelHeight: 1000
        )
        XCTAssertEqual(point?.x ?? 0, 500, accuracy: 0.001)
        XCTAssertEqual(point?.y ?? 0, 250, accuracy: 0.001)
    }

    func testPointerUsesBoundsWhenPixelSizeIsUnknown() {
        let bounds = CGRect(x: 10, y: 20, width: 200, height: 100)
        let point = PointerGeometry.globalPoint(
            x: 50, y: 25,
            frameWidth: 100, frameHeight: 50,
            bounds: bounds,
            pixelWidth: 0, pixelHeight: 0
        )
        XCTAssertEqual(point?.x ?? 0, 110, accuracy: 0.001)
        XCTAssertEqual(point?.y ?? 0, 70, accuracy: 0.001)
    }

    func testDesktopSwitchMovesToTheNeighboringSpace() {
        let layout = DesktopLayout(display: "Main", spaceIDs: [4, 252, 648], currentIndex: 1, spaceID: "middle")
        XCTAssertEqual(DesktopSwitcher.neighbor(of: .right, in: layout), 648)
        XCTAssertEqual(DesktopSwitcher.neighbor(of: .left, in: layout), 4)
        XCTAssertNil(DesktopSwitcher.neighbor(of: .left, in: DesktopLayout(display: "Main", spaceIDs: [4], currentIndex: 0, spaceID: "only")))
        XCTAssertNil(DesktopSwitcher.neighbor(of: .right, in: DesktopLayout(display: "Main", spaceIDs: [4, 252], currentIndex: 1, spaceID: "last")))
    }

    func testDesktopLayoutReadsTheLiveSpaces() throws {
        let layout = try XCTUnwrap(DesktopSwitcher.currentLayout())
        XCTAssertFalse(layout.display.isEmpty)
        XCTAssertFalse(layout.spaceID.isEmpty)
        XCTAssertFalse(layout.spaceIDs.isEmpty)
        XCTAssertGreaterThanOrEqual(layout.currentIndex, 0)
        XCTAssertLessThan(layout.currentIndex, layout.spaceIDs.count)
    }

    func testCurrentSpaceUsesItsUUID() throws {
        let display = displayRecord(
            identifier: "Main",
            spaces: [
                spaceRecord(id: 4, uuid: "left"),
                spaceRecord(id: 252, uuid: "middle"),
                spaceRecord(id: 648, uuid: "right")
            ],
            current: spaceRecord(id: 252, uuid: "middle")
        )
        let layout = try XCTUnwrap(DesktopSwitcher.layout(from: [display], mainDisplayID: "Main"))
        XCTAssertEqual(layout.spaceID, "middle")
        XCTAssertEqual(layout.currentIndex, 1)
        XCTAssertEqual(layout.spaceIDs, [4, 252, 648])
        XCTAssertEqual(DesktopSwitcher.neighbor(of: .left, in: layout), 4)
        XCTAssertEqual(DesktopSwitcher.neighbor(of: .right, in: layout), 648)
    }

    func testFullscreenSpaceKeepsItsIdentityWhenMissingFromTheDesktopList() throws {
        let display = displayRecord(
            identifier: "Main",
            spaces: [
                spaceRecord(id: 4, uuid: "desktop-a"),
                spaceRecord(id: 252, uuid: "desktop-b")
            ],
            current: spaceRecord(id: 700, uuid: "FULLSCREEN-APP", type: 4)
        )
        let layout = try XCTUnwrap(DesktopSwitcher.layout(from: [display], mainDisplayID: "Main"))
        XCTAssertEqual(layout.spaceID, "FULLSCREEN-APP")
        XCTAssertEqual(layout.currentIndex, -1)
        XCTAssertEqual(layout.spaceIDs, [4, 252])
        XCTAssertNil(DesktopSwitcher.neighbor(of: .left, in: layout))
        XCTAssertNil(DesktopSwitcher.neighbor(of: .right, in: layout))
    }

    func testSpaceIDFallsBackToTheID64String() throws {
        let current = spaceRecord(id: 445, uuid: "")
        let display = displayRecord(identifier: "Main", spaces: [current], current: current)
        let layout = try XCTUnwrap(DesktopSwitcher.layout(from: [display], mainDisplayID: nil))
        XCTAssertEqual(layout.spaceID, "445")
        let parser = StreamParser()
        XCTAssertEqual(try parser.append(StreamFraming.encode(.space(layout.spaceID))), [.space("445")])
    }

    func testLayoutFollowsTheStreamedDisplay() throws {
        let other = displayRecord(
            identifier: "Other",
            spaces: [spaceRecord(id: 1, uuid: "other-space")],
            current: spaceRecord(id: 1, uuid: "other-space")
        )
        let main = displayRecord(
            identifier: "Main",
            spaces: [spaceRecord(id: 2, uuid: "main-space")],
            current: spaceRecord(id: 2, uuid: "main-space")
        )
        let matched = try XCTUnwrap(DesktopSwitcher.layout(from: [other, main], mainDisplayID: "Main"))
        XCTAssertEqual(matched.display, "Main")
        XCTAssertEqual(matched.spaceID, "main-space")
        let fallback = try XCTUnwrap(DesktopSwitcher.layout(from: [other, main], mainDisplayID: "missing"))
        XCTAssertEqual(fallback.display, "Other")
        XCTAssertEqual(fallback.spaceID, "other-space")
    }

    func testSpaceIsBroadcastWhenTheDesktopChangesAndCachedForNewSessions() throws {
        let hub = FrameHub(hostName: "Test")
        let first = try SessionPipe()
        defer { first.stop() }
        hub.add(first.session)
        hub.updateSpace("3991F2FD-B350-68E9-D174-1414C0D927A7")
        hub.updateSpace("3991F2FD-B350-68E9-D174-1414C0D927A7")
        hub.updateSpace("4F909C74-F54F-1359-7777-414FEE8BA3FC")
        XCTAssertEqual(
            try readSpaces(from: first.client, count: 2),
            ["3991F2FD-B350-68E9-D174-1414C0D927A7", "4F909C74-F54F-1359-7777-414FEE8BA3FC"]
        )

        let second = try SessionPipe()
        defer { second.stop() }
        hub.add(second.session)
        XCTAssertEqual(
            try readSpaces(from: second.client, count: 1),
            ["4F909C74-F54F-1359-7777-414FEE8BA3FC"]
        )
    }

    func testHardwareEncoderEmitsDecodableKeyframe() throws {
        let encoder = H264Encoder(fps: 30)
        let delivered = DispatchSemaphore(value: 0)
        let box = EncodedBox()
        encoder.onEncoded = { config, frame in
            if let config {
                box.config = config
            }
            if frame.isKeyframe {
                box.frame = frame
                delivered.signal()
            }
        }
        try encoder.start(width: 640, height: 360, fps: 30, bitrate: 2_000_000)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            640,
            360,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        let buffer = try XCTUnwrap(pixelBuffer)
        encoder.encode(buffer, presentationTime: CMTime(value: 0, timescale: 30))
        encoder.encode(buffer, presentationTime: CMTime(value: 1, timescale: 30))

        XCTAssertEqual(delivered.wait(timeout: .now() + 3), .success)
        let config = try XCTUnwrap(box.config)
        let frame = try XCTUnwrap(box.frame)
        XCTAssertEqual(config.width, 640)
        XCTAssertEqual(config.height, 360)
        XCTAssertGreaterThanOrEqual(config.parameterSets.count, 2)
        XCTAssertFalse(frame.data.isEmpty)
    }

    func testUsbmuxListsDevicesWhenDaemonIsUp() throws {
        do {
            _ = try Usbmux.listDevices()
        } catch {
            throw XCTSkip("usbmuxd is not reachable: \(error)")
        }
    }

    func testFingerTapIsAClickAndNotAScroll() {
        var tracker = FingerContactTracker()
        let origin = CGPoint(x: 10, y: 20)
        XCTAssertEqual(tracker.handle(phase: .down, point: origin, time: 0), [
            .move(origin),
            .directTouch(DirectTouchEvent(point: origin, phase: .began))
        ])
        let wobble = CGPoint(x: 12, y: 21)
        XCTAssertEqual(tracker.handle(phase: .move, point: wobble, time: 0.1), [])
        XCTAssertEqual(tracker.fireLongPress(time: 0.4), [])
        XCTAssertEqual(tracker.handle(phase: .up, point: wobble, time: 0.3), [
            .leftClick(origin),
            .directTouch(DirectTouchEvent(point: wobble, phase: .ended))
        ])
        XCTAssertNil(tracker.longPressDeadline)
    }

    func testFingerDragIsOneScrollAndNotAButton() {
        var tracker = FingerContactTracker()
        let origin = CGPoint(x: 100, y: 80)
        _ = tracker.handle(phase: .down, point: origin, time: 0)
        let moved = CGPoint(x: origin.x + 30, y: origin.y - 10)
        XCTAssertEqual(
            tracker.handle(phase: .move, point: moved, time: 0.1),
            [
                .scroll(ScrollWheelPayload(point: origin, deltaX: 30, deltaY: -10, phase: .began)),
                .directTouch(DirectTouchEvent(point: moved, phase: .changed))
            ]
        )
        XCTAssertNil(tracker.longPressDeadline)
        XCTAssertEqual(tracker.fireLongPress(time: 2), [])
        let next = CGPoint(x: moved.x + 0.4, y: moved.y)
        XCTAssertEqual(tracker.handle(phase: .move, point: next, time: 0.2), [])
        let further = CGPoint(x: moved.x + 1.2, y: moved.y + 4)
        XCTAssertEqual(
            tracker.handle(phase: .move, point: further, time: 0.3),
            [
                .scroll(ScrollWheelPayload(point: origin, deltaX: 1, deltaY: 4, phase: .changed)),
                .directTouch(DirectTouchEvent(point: further, phase: .changed))
            ]
        )
        XCTAssertEqual(
            tracker.handle(phase: .up, point: further, time: 0.4),
            [
                .scroll(ScrollWheelPayload(point: origin, deltaX: 0, deltaY: 0, phase: .ended)),
                .directTouch(DirectTouchEvent(point: further, phase: .ended))
            ]
        )
    }

    func testFingerHoldIsARightClickThenARightDrag() {
        var tracker = FingerContactTracker()
        let origin = CGPoint(x: 4, y: 9)
        _ = tracker.handle(phase: .down, point: origin, time: 5)
        XCTAssertEqual(tracker.longPressDeadline, 5.5)
        XCTAssertEqual(tracker.fireLongPress(time: 5.5), [
            .rightDown(origin),
            .directTouch(DirectTouchEvent(point: origin, phase: .changed))
        ])
        let dragged = CGPoint(x: 18, y: 9)
        XCTAssertEqual(tracker.handle(phase: .move, point: dragged, time: 5.7), [
            .rightDrag(dragged),
            .directTouch(DirectTouchEvent(point: dragged, phase: .changed))
        ])
        XCTAssertEqual(tracker.handle(phase: .up, point: dragged, time: 5.8), [
            .rightUp(dragged),
            .directTouch(DirectTouchEvent(point: dragged, phase: .ended))
        ])
    }

    func testScrollWheelPayloadUsesContinuousPixelPhase() throws {
        let payload = ScrollWheelPayload(
            point: CGPoint(x: 12.5, y: 34),
            deltaX: -3,
            deltaY: 8,
            phase: .began
        )
        let event = try XCTUnwrap(payload.makeEvent())
        XCTAssertEqual(event.type, .scrollWheel)
        XCTAssertEqual(event.location.x, 12.5, accuracy: 0.01)
        XCTAssertEqual(event.location.y, 34, accuracy: 0.01)
        XCTAssertEqual(
            event.getIntegerValueField(.scrollWheelEventScrollPhase),
            Int64(CGScrollPhase.began.rawValue)
        )
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventMomentumPhase), 0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 8)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), -3)
        XCTAssertNotEqual(event.type, .leftMouseDragged)
    }

    func testDirectTouchEventUsesTheTouchTypeAndSubtype() throws {
        let event = try XCTUnwrap(DirectTouchEvent(point: CGPoint(x: 8, y: 9), phase: .began).makeEvent())
        XCTAssertEqual(event.type, DirectTouchEvent.eventType)
        XCTAssertEqual(event.type.rawValue, 37)
        XCTAssertEqual(event.location.x, 8, accuracy: 0.01)
        XCTAssertEqual(event.location.y, 9, accuracy: 0.01)
    }
}

private func spaceRecord(id: UInt64, uuid: String?, type: Int = 0) -> [String: Any] {
    var record: [String: Any] = [
        "id64": NSNumber(value: id),
        "type": NSNumber(value: type),
        "ManagedSpaceID": NSNumber(value: id)
    ]
    if let uuid {
        record["uuid"] = uuid
    }
    return record
}

private func displayRecord(identifier: String, spaces: [[String: Any]], current: [String: Any]) -> [String: Any] {
    [
        "Display Identifier": identifier,
        "Spaces": spaces,
        "Current Space": current
    ]
}

private func readSpaces(from fd: Int32, count: Int, timeout: TimeInterval = 2) throws -> [String] {
    let parser = StreamParser()
    var spaces: [String] = []
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline && spaces.count < count {
        var pollState = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let readyCount = poll(&pollState, 1, 200)
        guard readyCount > 0 else { continue }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let readCount = Darwin.read(fd, &buffer, buffer.count)
        guard readCount > 0 else { break }
        for message in try parser.append(Data(buffer.prefix(readCount))) {
            if case .space(let id) = message {
                spaces.append(id)
            }
        }
    }
    return spaces
}

/// A connected client/server pair. The session owns the accepted socket.
private final class SessionPipe {
    let client: Int32
    let session: StreamSession

    init() throws {
        let listener = try POSIX.listenTCP(port: 0)
        let port = try POSIX.boundPort(listener)
        let accepted = FDBox()
        let ready = DispatchSemaphore(value: 0)
        Thread {
            accepted.fd = Darwin.accept(listener, nil, nil)
            ready.signal()
        }.start()

        let clientFD: Int32
        do {
            clientFD = try POSIX.connectTCP(host: "127.0.0.1", port: port)
        } catch {
            POSIX.close(listener)
            _ = ready.wait(timeout: .now() + 2)
            throw error
        }
        guard ready.wait(timeout: .now() + 2) == .success, accepted.fd >= 0 else {
            POSIX.close(clientFD)
            POSIX.close(listener)
            throw SocketError.failed("accept", EAGAIN)
        }
        POSIX.close(listener)
        POSIX.configure(accepted.fd)
        client = clientFD
        session = StreamSession(fd: accepted.fd, label: "space")
        session.start()
    }

    func stop() {
        session.stop()
        POSIX.close(client)
    }
}

private final class FDBox {
    var fd: Int32 = -1
}

private final class InputBox {
    var value: RemoteInput?
}

private final class EncodedBox {
    var config: VideoConfig?
    var frame: VideoFrame?
}
