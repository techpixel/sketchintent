import XCTest
@testable import StreamProtocol

final class StreamProtocolTests: XCTestCase {
    func testHelloAndVideoRoundTrip() throws {
        let hello = StreamHello(name: "MacBook", width: 1920, height: 1080)
        let config = VideoConfig(
            width: 1920,
            height: 1080,
            nalUnitHeaderLength: 4,
            parameterSets: [Data([0x67, 0x64, 0x00]), Data([0x68, 0xee])]
        )
        let frame = VideoFrame(isKeyframe: true, presentationMicros: 42_000, data: Data([0, 0, 0, 1, 0x65]))
        let bytes = StreamFraming.encode(.hello(hello))
            + StreamFraming.encode(.videoConfig(config))
            + StreamFraming.encode(.videoFrame(frame))
        let parser = StreamParser()
        let messages = try parser.append(bytes)
        XCTAssertEqual(messages, [.hello(hello), .videoConfig(config), .videoFrame(frame)])
    }

    func testSplitPacketsReassemble() throws {
        let packet = StreamFraming.encode(.heartbeat)
        let parser = StreamParser()
        XCTAssertEqual(try parser.append(packet.prefix(2)), [])
        XCTAssertEqual(try parser.append(packet.dropFirst(2)), [.heartbeat])
    }

    func testOversizedFrameFailsClosed() throws {
        var bytes = Data([0x7f, 0xff, 0xff, 0xff, 0x02])
        let parser = StreamParser()
        XCTAssertThrowsError(try parser.append(bytes)) { error in
            XCTAssertEqual(error as? StreamProtocolError, .frameTooLarge(0x7fffffff))
        }
        bytes = StreamFraming.encode(.heartbeat)
        XCTAssertEqual(try parser.append(bytes), [.heartbeat])
    }

    func testUnknownTypeIsSkipped() throws {
        var length = UInt32(2).bigEndian
        var packet = Data()
        withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        packet.append(0x7f)
        packet.append(0x00)
        packet.append(StreamFraming.encode(.heartbeat))
        let parser = StreamParser()
        XCTAssertEqual(try parser.append(packet), [.heartbeat])
    }

    func testDesktopSwipeRoundTrip() throws {
        let packet = StreamFraming.encode(.input(.switchDesktop(.left)))
            + StreamFraming.encode(.input(.switchDesktop(.right)))
        let parser = StreamParser()
        XCTAssertEqual(
            try parser.append(packet),
            [.input(.switchDesktop(.left)), .input(.switchDesktop(.right))]
        )
        XCTAssertEqual(Array(StreamFraming.encode(.input(.switchDesktop(.left))).suffix(2)), [1, DesktopDirection.left.rawValue])
    }

    func testPointerRoundTrip() throws {
        let down = StreamFraming.encode(.input(.pointer(.down, x: 0x0102, y: 0x0304)))
        XCTAssertEqual(Array(down), [
            0x00, 0x00, 0x00, 0x08,
            5, 2, PointerPhase.down.rawValue, 0x01, 0x02, 0x03, 0x04, PointerContact.button.rawValue
        ])
        let packet = down
            + StreamFraming.encode(.input(.pointer(.move, x: 65535, y: 0)))
            + StreamFraming.encode(.input(.pointer(.up, x: 8, y: 9)))
            + StreamFraming.encode(.input(.switchDesktop(.right)))
        XCTAssertEqual(
            try StreamParser().append(packet),
            [
                .input(.pointer(.down, x: 0x0102, y: 0x0304)),
                .input(.pointer(.move, x: 65535, y: 0)),
                .input(.pointer(.up, x: 8, y: 9)),
                .input(.switchDesktop(.right))
            ]
        )
    }

    func testShortPointerPayloadIsSkipped() throws {
        var length = UInt32(3).bigEndian
        var packet = Data()
        withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        packet.append(5)
        packet.append(2)
        packet.append(1)
        packet.append(StreamFraming.encode(.input(.switchDesktop(.left))))
        XCTAssertEqual(try StreamParser().append(packet), [.input(.switchDesktop(.left))])
    }

    func testFingerContactRoundTripAndLegacyButtonPacket() throws {
        let finger = StreamFraming.encode(.input(.pointer(.move, x: 4, y: 5, contact: .finger)))
        XCTAssertEqual(Array(finger.suffix(7)), [
            2, PointerPhase.move.rawValue, 0x00, 0x04, 0x00, 0x05, PointerContact.finger.rawValue
        ])
        XCTAssertEqual(
            try StreamParser().append(finger),
            [.input(.pointer(.move, x: 4, y: 5, contact: .finger))]
        )

        var length = UInt32(7).bigEndian
        var legacy = Data()
        withUnsafeBytes(of: &length) { legacy.append(contentsOf: $0) }
        legacy.append(contentsOf: [5, 2, PointerPhase.down.rawValue, 0x00, 0x0a, 0x00, 0x0b])
        XCTAssertEqual(
            try StreamParser().append(legacy),
            [.input(.pointer(.down, x: 10, y: 11, contact: .button))]
        )

        var badLength = UInt32(8).bigEndian
        var bad = Data()
        withUnsafeBytes(of: &badLength) { bad.append(contentsOf: $0) }
        bad.append(contentsOf: [5, 2, PointerPhase.up.rawValue, 0, 1, 0, 2, 9])
        bad.append(StreamFraming.encode(.heartbeat))
        XCTAssertEqual(try StreamParser().append(bad), [.heartbeat])
    }

    func testTrackpadScrollAndClickRoundTrip() throws {
        let scroll = StreamFraming.encode(.input(.trackpadScroll(dx: -300, dy: 20, phase: .changed)))
        XCTAssertEqual(Array(scroll.suffix(6)), [
            3, TrackpadScrollPhase.changed.rawValue, 0xfe, 0xd4, 0x00, 0x14
        ])
        let packet = scroll
            + StreamFraming.encode(.input(.trackpadClick(.right, .down)))
            + StreamFraming.encode(.input(.trackpadClick(.left, .up)))
            + StreamFraming.encode(.input(.pointer(.down, x: 1, y: 2)))
        XCTAssertEqual(
            try StreamParser().append(packet),
            [
                .input(.trackpadScroll(dx: -300, dy: 20, phase: .changed)),
                .input(.trackpadClick(.right, .down)),
                .input(.trackpadClick(.left, .up)),
                .input(.pointer(.down, x: 1, y: 2))
            ]
        )

        var length = UInt32(4).bigEndian
        var skipped = Data()
        withUnsafeBytes(of: &length) { skipped.append(contentsOf: $0) }
        skipped.append(contentsOf: [5, 4, TrackpadButton.left.rawValue, PointerPhase.move.rawValue])
        skipped.append(StreamFraming.encode(.heartbeat))
        XCTAssertEqual(try StreamParser().append(skipped), [.heartbeat])
    }

    func testLetterboxedPictureMapsAndBlackBarsAreIgnored() {
        XCTAssertNil(FrameCoordinates.pixel(
            viewX: 40, viewY: 10,
            viewWidth: 100, viewHeight: 200,
            frameWidth: 200, frameHeight: 100
        ))
        let topLeft = FrameCoordinates.pixel(
            viewX: 0, viewY: 75,
            viewWidth: 100, viewHeight: 200,
            frameWidth: 200, frameHeight: 100
        )
        XCTAssertEqual(topLeft?.x, 0)
        XCTAssertEqual(topLeft?.y, 0)
        let middle = FrameCoordinates.pixel(
            viewX: 50, viewY: 100,
            viewWidth: 100, viewHeight: 200,
            frameWidth: 200, frameHeight: 100
        )
        XCTAssertEqual(middle?.x, 100)
        XCTAssertEqual(middle?.y, 50)

        XCTAssertNil(FrameCoordinates.pixel(
            viewX: 10, viewY: 40,
            viewWidth: 200, viewHeight: 100,
            frameWidth: 100, frameHeight: 100
        ))
        let center = FrameCoordinates.pixel(
            viewX: 100, viewY: 50,
            viewWidth: 200, viewHeight: 100,
            frameWidth: 100, frameHeight: 100
        )
        XCTAssertEqual(center?.x, 50)
        XCTAssertEqual(center?.y, 50)
    }

    func testUnknownInputKindIsSkipped() throws {
        var length = UInt32(2).bigEndian
        var packet = Data()
        withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        packet.append(5)
        packet.append(9)
        packet.append(StreamFraming.encode(.input(.switchDesktop(.right))))
        let parser = StreamParser()
        XCTAssertEqual(try parser.append(packet), [.input(.switchDesktop(.right))])
    }

    func testSpaceIdentityRoundTrip() throws {
        let packet = StreamFraming.encode(.space("3991F2FD-B350-68E9-D174-1414C0D927A7"))
        let parser = StreamParser()
        XCTAssertEqual(try parser.append(packet), [.space("3991F2FD-B350-68E9-D174-1414C0D927A7")])
        XCTAssertEqual(try parser.append(StreamFraming.encode(.space(""))), [])
    }

    func testUSBMuxPortByteSwap() {
        XCTAssertEqual(USBMuxPorts.plistValue(for: 2345), 10505)
        XCTAssertEqual(USBMuxPorts.plistValue(for: 22), 5632)
    }
}
