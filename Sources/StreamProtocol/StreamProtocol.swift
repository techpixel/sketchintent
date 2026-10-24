import Foundation

/// Ports and Bonjour type shared by the Mac server and the iPad app.
public enum SketchIntentPorts {
    /// Port the iPad app listens on. The Mac connects to it through usbmuxd.
    public static let usb: UInt16 = 2345
    /// Port the Mac listens on for the Simulator and for network clients.
    public static let tcp: UInt16 = 2346
    /// Bonjour service type, without the trailing dot.
    public static let bonjourType = "_sketchintent._tcp"
}

/// usbmuxd stores the TCP port with its two bytes swapped inside the plist integer.
public enum USBMuxPorts {
    public static func plistValue(for port: UInt16) -> Int {
        Int((UInt32(port & 0x00ff) << 8) | UInt32(port >> 8))
    }
}

public struct StreamHello: Codable, Equatable {
    public var name: String
    public var width: Int
    public var height: Int

    public init(name: String, width: Int, height: Int) {
        self.name = name
        self.width = width
        self.height = height
    }
}

/// H.264 parameter sets the iPad needs before it can decode.
public struct VideoConfig: Equatable {
    public var width: Int
    public var height: Int
    public var nalUnitHeaderLength: Int
    public var parameterSets: [Data]

    public init(width: Int, height: Int, nalUnitHeaderLength: Int, parameterSets: [Data]) {
        self.width = width
        self.height = height
        self.nalUnitHeaderLength = nalUnitHeaderLength
        self.parameterSets = parameterSets
    }
}

/// One encoded access unit, in AVCC form (length-prefixed NAL units).
public struct VideoFrame: Equatable {
    public var isKeyframe: Bool
    public var presentationMicros: UInt64
    public var data: Data

    public init(isKeyframe: Bool, presentationMicros: UInt64, data: Data) {
        self.isKeyframe = isKeyframe
        self.presentationMicros = presentationMicros
        self.data = data
    }
}

/// Which neighboring macOS desktop a gesture should open.
public enum DesktopDirection: UInt8, Equatable {
    /// The space to the left of the current one.
    case left = 1
    /// The space to the right of the current one.
    case right = 2
}

/// Phase of a Pencil pointer on the streamed picture.
public enum PointerPhase: UInt8, Equatable {
    case down = 1
    case move = 2
    case up = 3
}

/// How one Pencil contact should drive the Mac.
/// A missing byte on the wire is `button`, so older clients keep click-and-drag.
public enum PointerContact: UInt8, Equatable {
    /// Left-button down, drag, and up. The explicit mouse path.
    case button = 1
    /// One finger, as TN3212 emulates a Sidecar touch for apps that are not touch-native.
    case finger = 2
}

/// Phase of one continuous trackpad scroll. These are not `CGScrollPhase` raw values:
/// ended is 4 there, so the wire uses its own small set and the Mac maps it.
public enum TrackpadScrollPhase: UInt8, Equatable {
    case began = 1
    case changed = 2
    case ended = 3
    case cancelled = 4
}

/// Which mouse button a virtual-trackpad cell presses. The click lands on the
/// Mac cursor. The pad is not a point on the streamed picture.
public enum TrackpadButton: UInt8, Equatable {
    case left = 1
    case right = 2
}

/// Something the iPad asks the Mac to do. The Mac is the only side that reads these.
/// Kind byte 1 is `switchDesktop` (`[1, direction]`). Kind byte 2 is `pointer`, so older packets still decode.
/// Kind byte 3 is a trackpad scroll. Kind byte 4 is a trackpad click.
public enum RemoteInput: Equatable {
    case switchDesktop(DesktopDirection)
    /// Pencil point in captured-frame pixels. `x` and `y` are inside the video frame, not the iPad view.
    /// One packet is one contact. `button` click-drags; `finger` is the Sidecar-style pan.
    case pointer(PointerPhase, x: UInt16, y: UInt16, contact: PointerContact = .button)
    /// One-finger travel on the virtual trackpad, in pixels. Positive `dx` is right.
    /// Positive `dy` is down. This does not move the pointer to a picture point.
    case trackpadScroll(dx: Int16, dy: Int16, phase: TrackpadScrollPhase)
    /// Left or right button at the current cursor. `move` is not a click phase.
    case trackpadClick(TrackpadButton, PointerPhase)
}

/// Maps a point in the iPad's video view into captured-frame pixels.
/// The picture uses the same aspect fit as `AVSampleBufferDisplayLayer` videoGravity `.resizeAspect`.
public enum FrameCoordinates {
    public struct Rect: Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
    }

    /// Letterboxed (or pillarboxed) picture inside the view. The origin is the view's top left.
    public static func pictureRect(viewWidth: Double, viewHeight: Double, frameWidth: Int, frameHeight: Int) -> Rect? {
        guard viewWidth > 0, viewHeight > 0, frameWidth > 0, frameHeight > 0 else { return nil }
        let frameAspect = Double(frameWidth) / Double(frameHeight)
        let viewAspect = viewWidth / viewHeight
        if viewAspect > frameAspect {
            let width = viewHeight * frameAspect
            return Rect(x: (viewWidth - width) / 2, y: 0, width: width, height: viewHeight)
        }
        let height = viewWidth / frameAspect
        return Rect(x: 0, y: (viewHeight - height) / 2, width: viewWidth, height: height)
    }

    /// Nil when the point is in a black bar, or when the sizes are empty.
    public static func pixel(
        viewX: Double,
        viewY: Double,
        viewWidth: Double,
        viewHeight: Double,
        frameWidth: Int,
        frameHeight: Int
    ) -> (x: UInt16, y: UInt16)? {
        guard let picture = pictureRect(
            viewWidth: viewWidth,
            viewHeight: viewHeight,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        ), picture.width > 0, picture.height > 0 else { return nil }
        let dx = viewX - picture.x
        let dy = viewY - picture.y
        guard dx >= 0, dy >= 0, dx <= picture.width, dy <= picture.height else { return nil }
        let nx = dx / picture.width
        let ny = dy / picture.height
        let maxX = min(frameWidth, Int(UInt16.max) + 1) - 1
        let maxY = min(frameHeight, Int(UInt16.max) + 1) - 1
        let x = min(max(Int(nx * Double(frameWidth)), 0), maxX)
        let y = min(max(Int(ny * Double(frameHeight)), 0), maxY)
        return (UInt16(x), UInt16(y))
    }
}

/// Pen ink for one desktop, already mapped into captured-frame pixels.
/// The PNG is the whole frame with alpha, so the Mac can stretch it onto the display.
/// An empty PNG clears the overlay. Voice notes are not included.
public struct InkSnapshot: Equatable {
    public var width: Int
    public var height: Int
    /// Mission Control id this ink belongs to. Empty until the iPad has heard one.
    public var spaceID: String
    public var png: Data

    public init(width: Int, height: Int, spaceID: String, png: Data) {
        self.width = width
        self.height = height
        self.spaceID = spaceID
        self.png = png
    }

    public static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
}

public enum StreamMessage: Equatable {
    case hello(StreamHello)
    case videoConfig(VideoConfig)
    case videoFrame(VideoFrame)
    case heartbeat
    case input(RemoteInput)
    /// The macOS desktop currently on the streamed display. Sketches stay with this id.
    case space(String)
    /// Pen ink drawn on the iPad, in captured-frame pixels. Not a video frame.
    case ink(InkSnapshot)
}

public enum StreamProtocolError: Error, Equatable, CustomStringConvertible {
    case frameTooLarge(Int)
    case invalidHello
    case invalidVideo

    public var description: String {
        switch self {
        case .frameTooLarge(let length):
            return "Frame length \(length) exceeds the protocol limit."
        case .invalidHello:
            return "Hello payload was not a valid display description."
        case .invalidVideo:
            return "Video payload was truncated or malformed."
        }
    }
}

enum StreamMessageType: UInt8 {
    case hello = 1
    case videoConfig = 2
    case heartbeat = 3
    case videoFrame = 4
    case input = 5
    case space = 6
    case ink = 7
}

public enum StreamFraming {
    /// Largest accepted frame, including the type byte. Keeps a bad length from allocating.
    public static let maxPayloadLength = 12_000_000

    public static func encode(_ message: StreamMessage) -> Data {
        let type: StreamMessageType
        let payload: Data
        switch message {
        case .hello(let hello):
            type = .hello
            payload = (try? JSONEncoder().encode(hello)) ?? Data()
        case .videoConfig(let config):
            type = .videoConfig
            payload = config.encodedPayload()
        case .videoFrame(let frame):
            type = .videoFrame
            payload = frame.encodedPayload()
        case .heartbeat:
            type = .heartbeat
            payload = Data()
        case .input(let input):
            type = .input
            payload = input.encodedPayload()
        case .space(let id):
            type = .space
            payload = Data(id.utf8)
        case .ink(let ink):
            type = .ink
            payload = ink.encodedPayload()
        }

        var packet = Data(capacity: 5 + payload.count)
        var length = UInt32(1 + payload.count).bigEndian
        withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        packet.append(type.rawValue)
        packet.append(payload)
        return packet
    }
}

/// Incremental decoder for the length-prefixed stream.
public final class StreamParser {
    private var buffer = Data()
    private var offset = 0

    public init() {}

    public func reset() {
        buffer.removeAll(keepingCapacity: true)
        offset = 0
    }

    public func append(_ data: Data) throws -> [StreamMessage] {
        if data.isEmpty { return [] }
        buffer.append(data)
        var messages: [StreamMessage] = []

        while buffer.count - offset >= 4 {
            let length = Int(readUInt32BE(at: offset))
            if length < 1 || length > StreamFraming.maxPayloadLength {
                reset()
                throw StreamProtocolError.frameTooLarge(length)
            }
            let frameEnd = offset + 4 + length
            if buffer.count < frameEnd { break }

            let typeRaw = buffer[offset + 4]
            let payloadStart = offset + 5
            let payload = payloadStart < frameEnd
                ? buffer.subdata(in: payloadStart..<frameEnd)
                : Data()
            offset = frameEnd

            guard let type = StreamMessageType(rawValue: typeRaw) else { continue }
            switch type {
            case .hello:
                guard let hello = try? JSONDecoder().decode(StreamHello.self, from: payload) else {
                    reset()
                    throw StreamProtocolError.invalidHello
                }
                messages.append(.hello(hello))
            case .videoConfig:
                guard let config = VideoConfig(payload: payload) else {
                    reset()
                    throw StreamProtocolError.invalidVideo
                }
                messages.append(.videoConfig(config))
            case .videoFrame:
                guard let frame = VideoFrame(payload: payload) else {
                    reset()
                    throw StreamProtocolError.invalidVideo
                }
                messages.append(.videoFrame(frame))
            case .heartbeat:
                messages.append(.heartbeat)
            case .input:
                if let input = RemoteInput(payload: payload) {
                    messages.append(.input(input))
                }
            case .space:
                if let id = DesktopSpace.id(from: payload) {
                    messages.append(.space(id))
                }
            case .ink:
                if let ink = InkSnapshot(payload: payload) {
                    messages.append(.ink(ink))
                }
            }
        }

        if offset > 1_048_576 {
            buffer.removeSubrange(0..<offset)
            offset = 0
        }
        return messages
    }

    private func readUInt32BE(at index: Int) -> UInt32 {
        let b0 = UInt32(buffer[index])
        let b1 = UInt32(buffer[index + 1])
        let b2 = UInt32(buffer[index + 2])
        let b3 = UInt32(buffer[index + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}

enum DesktopSpace {
    /// A space id is the Mission Control UUID, a short ASCII token.
    static func id(from payload: Data) -> String? {
        guard (1...80).contains(payload.count),
              let id = String(data: payload, encoding: .utf8),
              id.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return nil }
        return id
    }
}

private extension InkSnapshot {
    func encodedPayload() -> Data {
        let space = Data(spaceID.utf8.prefix(80))
        var payload = Data(capacity: 9 + space.count + png.count)
        payload.appendBE(UInt32(clamping: max(0, width)))
        payload.appendBE(UInt32(clamping: max(0, height)))
        payload.append(UInt8(space.count))
        payload.append(space)
        payload.append(png)
        return payload
    }

    init?(payload: Data) {
        var cursor = PayloadCursor(payload)
        guard let width = cursor.u32(),
              let height = cursor.u32(),
              let spaceCount = cursor.u8(),
              let spaceBytes = cursor.bytes(Int(spaceCount)) else { return nil }
        let spaceID: String
        if spaceCount == 0 {
            spaceID = ""
        } else {
            guard let id = DesktopSpace.id(from: spaceBytes) else { return nil }
            spaceID = id
        }
        let png = cursor.remaining()
        if png.isEmpty {
            self.init(width: Int(width), height: Int(height), spaceID: spaceID, png: Data())
            return
        }
        guard width > 0, height > 0, png.starts(with: Self.pngSignature) else { return nil }
        self.init(width: Int(width), height: Int(height), spaceID: spaceID, png: png)
    }
}

private extension RemoteInput {
    func encodedPayload() -> Data {
        switch self {
        case .switchDesktop(let direction):
            return Data([1, direction.rawValue])
        case .pointer(let phase, let x, let y, let contact):
            var payload = Data([2, phase.rawValue])
            payload.appendBE(x)
            payload.appendBE(y)
            payload.append(contact.rawValue)
            return payload
        case .trackpadScroll(let dx, let dy, let phase):
            var payload = Data([3, phase.rawValue])
            payload.appendBE(dx)
            payload.appendBE(dy)
            return payload
        case .trackpadClick(let button, let phase):
            return Data([4, button.rawValue, phase.rawValue])
        }
    }

    init?(payload: Data) {
        guard let kind = payload.first else { return nil }
        switch kind {
        case 1:
            guard payload.count == 2, let direction = DesktopDirection(rawValue: payload[1]) else { return nil }
            self = .switchDesktop(direction)
        case 2:
            guard payload.count == 6 || payload.count == 7, let phase = PointerPhase(rawValue: payload[1]) else { return nil }
            let x = UInt16(payload[2]) << 8 | UInt16(payload[3])
            let y = UInt16(payload[4]) << 8 | UInt16(payload[5])
            let contact: PointerContact
            if payload.count == 6 {
                contact = .button
            } else {
                guard let decoded = PointerContact(rawValue: payload[6]) else { return nil }
                contact = decoded
            }
            self = .pointer(phase, x: x, y: y, contact: contact)
        case 3:
            guard payload.count == 6, let phase = TrackpadScrollPhase(rawValue: payload[1]) else { return nil }
            let dx = Int16(bitPattern: UInt16(payload[2]) << 8 | UInt16(payload[3]))
            let dy = Int16(bitPattern: UInt16(payload[4]) << 8 | UInt16(payload[5]))
            self = .trackpadScroll(dx: dx, dy: dy, phase: phase)
        case 4:
            guard payload.count == 3,
                  let button = TrackpadButton(rawValue: payload[1]),
                  let phase = PointerPhase(rawValue: payload[2]),
                  phase != .move else { return nil }
            self = .trackpadClick(button, phase)
        default:
            return nil
        }
    }
}

private extension VideoConfig {
    func encodedPayload() -> Data {
        var payload = Data()
        payload.appendBE(UInt32(width))
        payload.appendBE(UInt32(height))
        payload.append(UInt8(clamping: nalUnitHeaderLength))
        payload.append(UInt8(min(parameterSets.count, 255)))
        for set in parameterSets.prefix(255) {
            payload.appendBE(UInt16(min(set.count, Int(UInt16.max))))
            payload.append(set.prefix(Int(UInt16.max)))
        }
        return payload
    }

    init?(payload: Data) {
        var cursor = PayloadCursor(payload)
        guard let width = cursor.u32(),
              let height = cursor.u32(),
              let nalLength = cursor.u8(),
              let count = cursor.u8(),
              nalLength == 4 || nalLength == 2 || nalLength == 1,
              count > 0 else { return nil }
        var sets: [Data] = []
        sets.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let size = cursor.u16(), let bytes = cursor.bytes(Int(size)), !bytes.isEmpty else { return nil }
            sets.append(bytes)
        }
        guard cursor.isAtEnd else { return nil }
        self.init(width: Int(width), height: Int(height), nalUnitHeaderLength: Int(nalLength), parameterSets: sets)
    }
}

private extension VideoFrame {
    func encodedPayload() -> Data {
        var payload = Data(capacity: 9 + data.count)
        payload.append(isKeyframe ? 1 : 0)
        payload.appendBE(presentationMicros)
        payload.append(data)
        return payload
    }

    init?(payload: Data) {
        var cursor = PayloadCursor(payload)
        guard let flags = cursor.u8(), let micros = cursor.u64() else { return nil }
        let data = cursor.remaining()
        guard !data.isEmpty else { return nil }
        self.init(isKeyframe: flags & 1 == 1, presentationMicros: micros, data: data)
    }
}

private struct PayloadCursor {
    var data: Data
    var index = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { index == data.count }

    mutating func u8() -> UInt8? {
        guard index < data.count else { return nil }
        let value = data[index]
        index += 1
        return value
    }

    mutating func u16() -> UInt16? {
        guard index + 2 <= data.count else { return nil }
        let value = UInt16(data[index]) << 8 | UInt16(data[index + 1])
        index += 2
        return value
    }

    mutating func u32() -> UInt32? {
        guard index + 4 <= data.count else { return nil }
        let value = UInt32(data[index]) << 24
            | UInt32(data[index + 1]) << 16
            | UInt32(data[index + 2]) << 8
            | UInt32(data[index + 3])
        index += 4
        return value
    }

    mutating func u64() -> UInt64? {
        guard index + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for offset in 0..<8 {
            value = (value << 8) | UInt64(data[index + offset])
        }
        index += 8
        return value
    }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, index + count <= data.count else { return nil }
        let slice = data.subdata(in: index..<(index + count))
        index += count
        return slice
    }

    mutating func remaining() -> Data {
        let slice = data.subdata(in: index..<data.count)
        index = data.count
        return slice
    }
}

private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
