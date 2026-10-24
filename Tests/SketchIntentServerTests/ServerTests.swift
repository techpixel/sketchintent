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

    func testDesktopSwitchMovesToTheNeighboringSpace() {
        let layout = DesktopLayout(display: "Main", spaceIDs: [4, 252, 648], currentIndex: 1)
        XCTAssertEqual(DesktopSwitcher.neighbor(of: .right, in: layout), 648)
        XCTAssertEqual(DesktopSwitcher.neighbor(of: .left, in: layout), 4)
        XCTAssertNil(DesktopSwitcher.neighbor(of: .left, in: DesktopLayout(display: "Main", spaceIDs: [4], currentIndex: 0)))
        XCTAssertNil(DesktopSwitcher.neighbor(of: .right, in: DesktopLayout(display: "Main", spaceIDs: [4, 252], currentIndex: 1)))
    }

    func testDesktopLayoutReadsTheLiveSpaces() throws {
        let layout = try XCTUnwrap(DesktopSwitcher.currentLayout())
        XCTAssertFalse(layout.display.isEmpty)
        XCTAssertFalse(layout.spaceIDs.isEmpty)
        XCTAssertGreaterThanOrEqual(layout.currentIndex, 0)
        XCTAssertLessThan(layout.currentIndex, layout.spaceIDs.count)
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
