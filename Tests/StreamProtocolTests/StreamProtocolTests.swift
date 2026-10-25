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

    func testDesktopPickerAndCancelRoundTrip() throws {
        let packet = StreamFraming.encode(.desktops(index: 2, count: 4))
            + StreamFraming.encode(.desktops(index: -1, count: 3))
            + StreamFraming.encode(.cancelIntent(0x0102_0304))
            + StreamFraming.encode(.input(.goToDesktop(index: 5)))
        XCTAssertEqual(
            try StreamParser().append(packet),
            [
                .desktops(index: 2, count: 4),
                .desktops(index: -1, count: 3),
                .cancelIntent(0x0102_0304),
                .input(.goToDesktop(index: 5))
            ]
        )
    }

    func testTrackpadMagnifyRoundTrip() throws {
        let pinch = StreamFraming.encode(.input(.trackpadMagnify(magnification: -250, phase: .began)))
        XCTAssertEqual(Array(pinch.suffix(4)), [8, TrackpadScrollPhase.began.rawValue, 0xff, 0x06])
        let packet = pinch + StreamFraming.encode(.input(.trackpadMagnify(magnification: 0, phase: .ended)))
        XCTAssertEqual(
            try StreamParser().append(packet),
            [
                .input(.trackpadMagnify(magnification: -250, phase: .began)),
                .input(.trackpadMagnify(magnification: 0, phase: .ended))
            ]
        )
    }

    func testTrackpadMoveAndTapRoundTrip() throws {
        let move = StreamFraming.encode(.input(.trackpadMove(dx: -2, dy: 30)))
        XCTAssertEqual(Array(move.suffix(5)), [5, 0xff, 0xfe, 0x00, 0x1e])
        let drag = StreamFraming.encode(.input(.trackpadDrag(dx: 4, dy: -1, phase: .move, fingers: 3)))
        XCTAssertEqual(Array(drag.suffix(7)), [7, PointerPhase.move.rawValue, 3, 0x00, 0x04, 0xff, 0xff])
        let packet = move
            + StreamFraming.encode(.input(.trackpadTap(fingers: 2, zone: .bottomLeft)))
            + StreamFraming.encode(.input(.trackpadTap(fingers: 1, zone: .bottomRight)))
            + drag
        XCTAssertEqual(
            try StreamParser().append(packet),
            [
                .input(.trackpadMove(dx: -2, dy: 30)),
                .input(.trackpadTap(fingers: 2, zone: .bottomLeft)),
                .input(.trackpadTap(fingers: 1, zone: .bottomRight)),
                .input(.trackpadDrag(dx: 4, dy: -1, phase: .move, fingers: 3))
            ]
        )

        var badLength = UInt32(4).bigEndian
        var bad = Data()
        withUnsafeBytes(of: &badLength) { bad.append(contentsOf: $0) }
        bad.append(contentsOf: [5, 6, 3, 9])
        bad.append(StreamFraming.encode(.heartbeat))
        XCTAssertEqual(try StreamParser().append(bad), [.heartbeat])
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

    func testInkRoundTripSkipsUnknownAndMalformed() throws {
        let space = "3991F2FD-B350-68E9-D174-1414C0D927A7"
        let png = InkSnapshot.pngSignature + Data([0x11, 0x22])
        let ink = InkSnapshot(width: 1920, height: 1080, spaceID: space, png: png)
        let clear = InkSnapshot(width: 0, height: 0, spaceID: space, png: Data())
        let encoded = StreamFraming.encode(.ink(ink))
        XCTAssertLessThanOrEqual(encoded.count, 4 + StreamFraming.maxPayloadLength)
        XCTAssertEqual(encoded[4], 7)
        XCTAssertEqual(Array(encoded[5..<9]), [0x00, 0x00, 0x07, 0x80])
        XCTAssertEqual(Array(encoded[9..<13]), [0x00, 0x00, 0x04, 0x38])
        XCTAssertEqual(encoded[13], UInt8(space.utf8.count))

        var unknownLength = UInt32(2).bigEndian
        var unknown = Data()
        withUnsafeBytes(of: &unknownLength) { unknown.append(contentsOf: $0) }
        unknown.append(0x7f)
        unknown.append(0xAB)

        var shortLength = UInt32(5).bigEndian
        var short = Data()
        withUnsafeBytes(of: &shortLength) { short.append(contentsOf: $0) }
        short.append(7)
        short.append(contentsOf: [0x00, 0x00, 0x00, 0x01])

        let bogus = StreamFraming.encode(.ink(InkSnapshot(width: 8, height: 8, spaceID: "", png: Data([1, 2, 3, 4]))))
        let parser = StreamParser()
        XCTAssertEqual(try parser.append(Data(encoded.prefix(6))), [])
        let rest = Data(encoded.dropFirst(6))
            + unknown
            + short
            + bogus
            + StreamFraming.encode(.ink(clear))
            + StreamFraming.encode(.heartbeat)
        XCTAssertEqual(
            try parser.append(rest),
            [.ink(ink), .ink(clear), .heartbeat]
        )
    }

    func testIntentRoundTrip() throws {
        let png = InkSnapshot.pngSignature + Data([0x01, 0x02, 0x03])
        let request = IntentRequest(
            id: 7,
            width: 320,
            height: 180,
            notes: [IntentNote(text: "make this blue", x: 12.5, y: 40)],
            png: png
        )
        let reply = IntentReply(id: 7, kind: .status, lead: "Calling ", name: "figma-mcp", text: "")
        let done = IntentReply(id: 7, kind: .done)
        let drawing = String(repeating: "[1,2],", count: 3_000)
        let canvas = IntentReply(id: 7, kind: .canvas, text: "{\"strokes\":[{\"points\":[\(drawing)[3,4]]}]}")
        let parser = StreamParser()
        XCTAssertEqual(
            try parser.append(
                StreamFraming.encode(.intent(request))
                    + StreamFraming.encode(.intentReply(reply))
                    + StreamFraming.encode(.intentReply(canvas))
                    + StreamFraming.encode(.intentReply(done))
            ),
            [.intent(request), .intentReply(reply), .intentReply(canvas), .intentReply(done)]
        )
        XCTAssertEqual(StreamFraming.encode(.intent(request))[4], 8)
        XCTAssertEqual(StreamFraming.encode(.intentReply(reply))[4], 9)

        let screen = InkSnapshot.pngSignature + Data([0x09])
        let withScreen = IntentRequest(
            id: 7,
            width: 320,
            height: 180,
            notes: request.notes,
            png: png,
            screenWidth: 1280,
            screenHeight: 800,
            screenPng: screen
        )
        XCTAssertEqual(try parser.append(StreamFraming.encode(.intent(withScreen))), [.intent(withScreen)])

        var inFolder = request
        inFolder.folder = "/Users/me/Notes"
        XCTAssertEqual(try parser.append(StreamFraming.encode(.intent(inFolder))), [.intent(inFolder)])

        var spoken = inFolder
        spoken.spoken = "open the settings page"
        XCTAssertEqual(try parser.append(StreamFraming.encode(.intent(spoken))), [.intent(spoken)])
        var onCanvas = request
        onCanvas.drawnOn = .canvas
        XCTAssertEqual(try parser.append(StreamFraming.encode(.intent(onCanvas))), [.intent(onCanvas)])
        var onDesktop = spoken
        onDesktop.drawnOn = .desktop(2)
        XCTAssertEqual(try parser.append(StreamFraming.encode(.intent(onDesktop))), [.intent(onDesktop)])
        var overFullscreen = withScreen
        overFullscreen.drawnOn = .desktop(-1)
        XCTAssertEqual(try parser.append(StreamFraming.encode(.intent(overFullscreen))), [.intent(overFullscreen)])

        var spokenWithScreen = withScreen
        spokenWithScreen.spoken = "make the header smaller"
        XCTAssertEqual(
            try parser.append(StreamFraming.encode(.intent(spokenWithScreen))),
            [.intent(spokenWithScreen)]
        )
        var live = request
        live.live = true
        XCTAssertEqual(try parser.append(StreamFraming.encode(.intent(live))), [.intent(live)])
        var liveOnCanvas = spokenWithScreen
        liveOnCanvas.drawnOn = .canvas
        liveOnCanvas.live = true
        XCTAssertEqual(try parser.append(StreamFraming.encode(.intent(liveOnCanvas))), [.intent(liveOnCanvas)])
        XCTAssertEqual(
            try parser.append(StreamFraming.encode(.chooseFolder("/Users/me/Notes")) + StreamFraming.encode(.workingFolder(""))),
            [.chooseFolder("/Users/me/Notes"), .workingFolder("")]
        )
    }
}
