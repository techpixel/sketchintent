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
