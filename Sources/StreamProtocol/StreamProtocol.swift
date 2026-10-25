import Foundation

/// Ports and Bonjour type shared by the Mac server and the iPad app.
public enum SketchIntentPorts {
    /// Port the iPad app listens on. The Mac connects to it through usbmuxd.
    public static let usb: UInt16 = 2345
    /// Port the Mac listens on for the Simulator and for network clients.
    public static let tcp: UInt16 = 2346
    /// Port the AI server listens on. The iPad posts a sketch here.
    public static let ai: UInt16 = 2347
    /// Bonjour service type, without the trailing dot.
    public static let bonjourType = "_sketchintent._tcp"
    /// Bonjour service type for the AI server, without the trailing dot.
    public static let aiBonjourType = "_sketchintent-ai._tcp"
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

/// Where a one-finger tap landed on the virtual trackpad.
/// Corner values match `TrackpadCornerSecondaryClick`: 1 is bottom right, 2 is bottom left.
public enum TrackpadTapZone: UInt8, Equatable {
    case other = 0
    case bottomRight = 1
    case bottomLeft = 2
}

/// Something the iPad asks the Mac to do. The Mac is the only side that reads these.
/// Kind byte 1 is `switchDesktop` (`[1, direction]`). Kind byte 2 is `pointer`, so older packets still decode.
/// Kind byte 3 is a trackpad scroll. Kind byte 4 is a trackpad click.
/// Kind byte 5 is a one-finger pointer move. Kind byte 6 is a trackpad tap.
/// Kind byte 7 is a three-finger drag. The Mac applies it only when three-finger drag is on.
/// Kind byte 8 is a two-finger pinch, posted on the Mac as a magnify gesture.
/// Kind byte 9 opens one desktop by its position in Mission Control.
public enum RemoteInput: Equatable {
    case switchDesktop(DesktopDirection)
    /// Pencil point in captured-frame pixels. `x` and `y` are inside the video frame, not the iPad view.
    /// One packet is one contact. `button` click-drags; `finger` is the Sidecar-style pan.
    case pointer(PointerPhase, x: UInt16, y: UInt16, contact: PointerContact = .button)
    /// Two-finger travel on the virtual trackpad, in points. Positive `dx` is right.
    /// Positive `dy` is down. The Mac applies scrolling direction and axis preferences.
    case trackpadScroll(dx: Int16, dy: Int16, phase: TrackpadScrollPhase)
    /// Left or right button at the current cursor. `move` is not a click phase.
    case trackpadClick(TrackpadButton, PointerPhase)
    /// One-finger travel on the virtual trackpad, in points. Positive `dx` is right
    /// and positive `dy` is down. Moves the pointer and does not scroll.
    case trackpadMove(dx: Int16, dy: Int16)
    /// A finger tap on the pad. `fingers` is 1 or 2. The Mac chooses the button from
    /// the trackpad's tap-to-click and secondary-click preferences.
    case trackpadTap(fingers: UInt8, zone: TrackpadTapZone)
    /// Three-finger travel on the pad. `phase` is down, move, or up. The Mac holds
    /// the left button only when three-finger drag is enabled.
    case trackpadDrag(dx: Int16, dy: Int16, phase: PointerPhase, fingers: UInt8)
    /// Pinch at the Mac cursor. `magnification` is the change in finger separation since the
    /// last sample, minus 1, in ten-thousandths: 100 is 1% wider. Positive zooms in.
    case trackpadMagnify(magnification: Int16, phase: TrackpadScrollPhase)
    /// Zero-based position of the desktop to open on the streamed display.
    case goToDesktop(index: UInt8)
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

/// A voice note in pixels of the sketch image. The origin is the top left.
public struct IntentNote: Codable, Equatable {
    public var text: String
    public var x: Double
    public var y: Double

    public init(text: String, x: Double, y: Double) {
        self.text = text
        self.x = x
        self.y = y
    }
}

/// One sketch the iPad asks the agent to read.
/// `png` is the crop the voice notes point into. `screenPng` is the whole Mac frame, for context.
public struct IntentRequest: Equatable {
    public var id: UInt32
    public var width: Int
    public var height: Int
    public var notes: [IntentNote]
    public var png: Data
    public var screenWidth: Int
    public var screenHeight: Int
    public var screenPng: Data
    /// Absolute path on the Mac. Empty until a folder is chosen in Settings.
    public var folder: String
    /// What the person said to the agent while holding the dictation button. Empty for a sketch alone.
    public var spoken: String

    public init(
        id: UInt32,
        width: Int,
        height: Int,
        notes: [IntentNote],
        png: Data,
        screenWidth: Int = 0,
        screenHeight: Int = 0,
        screenPng: Data = Data(),
        folder: String = "",
        spoken: String = ""
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.notes = notes
        self.png = png
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.screenPng = screenPng
        self.folder = folder
        self.spoken = spoken
    }
}

/// One event in the agent's reply.
public struct IntentReply: Equatable {
    public enum Kind: UInt8, Equatable {
        case status = 1
        case text = 2
        case done = 3
        case error = 4
        /// Ink and notes the agent put on the sketch. `text` is JSON: see `AgentCanvas` on the iPad.
        case canvas = 5
    }

    /// Longest `text` a reply carries. A canvas drawing is JSON, so it is never cut short:
    /// the AI server keeps it under this size instead.
    public static func textLimit(for kind: Kind) -> Int {
        kind == .canvas ? 512_000 : 8_000
    }

    public var id: UInt32
    public var kind: Kind
    public var lead: String
    public var name: String
    public var text: String

    public init(id: UInt32, kind: Kind, lead: String = "", name: String = "", text: String = "") {
        self.id = id
        self.kind = kind
        self.lead = lead
        self.name = name
        self.text = text
    }
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
    /// A sketch for the AI server. The iPad sends it. The Mac reads it.
    case intent(IntentRequest)
    /// One line of the agent's reply. The Mac sends it. The iPad reads it.
    case intentReply(IntentReply)
    /// The iPad asks the Mac to present a folder panel. The payload is the current path, or empty.
    case chooseFolder(String)
    /// The folder the user picked, or empty when the panel was cancelled. The Mac sends it.
    case workingFolder(String)
    /// Zero-based position of the desktop on screen, and how many desktops the display has.
    /// The Mac sends it. `index` is -1 when the current desktop is not in the list.
    case desktops(index: Int, count: Int)
    /// The iPad stops the agent working on this intent id.
    case cancelIntent(UInt32)
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
    case intent = 8
    case intentReply = 9
    case chooseFolder = 10
    case workingFolder = 11
    case desktops = 12
    case cancelIntent = 13
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
        case .intent(let request):
            type = .intent
            payload = request.encodedPayload()
        case .intentReply(let reply):
            type = .intentReply
            payload = reply.encodedPayload()
        case .chooseFolder(let path):
            type = .chooseFolder
            payload = WorkingFolder.encode(path)
        case .workingFolder(let path):
            type = .workingFolder
            payload = WorkingFolder.encode(path)
        case .desktops(let index, let count):
            type = .desktops
            let clampedCount = UInt8(clamping: max(0, count))
            let clampedIndex = index >= 0 && index < Int(clampedCount) ? UInt8(index) : UInt8.max
            payload = Data([clampedIndex, clampedCount])
        case .cancelIntent(let id):
            type = .cancelIntent
            var bytes = Data()
            bytes.appendBE(id)
            payload = bytes
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
            case .intent:
                if let request = IntentRequest(payload: payload) {
                    messages.append(.intent(request))
                }
            case .intentReply:
                if let reply = IntentReply(payload: payload) {
                    messages.append(.intentReply(reply))
                }
            case .chooseFolder:
                if let path = WorkingFolder.decode(payload) {
                    messages.append(.chooseFolder(path))
                }
            case .desktops:
                if payload.count == 2 {
                    let count = Int(payload[1])
                    let index = Int(payload[0]) < count ? Int(payload[0]) : -1
                    messages.append(.desktops(index: index, count: count))
                }
            case .cancelIntent:
                if payload.count == 4 {
                    let id = payload.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                    messages.append(.cancelIntent(id))
                }
            case .workingFolder:
                if let path = WorkingFolder.decode(payload) {
                    messages.append(.workingFolder(path))
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

private extension IntentRequest {
    func encodedPayload() -> Data {
        let notes = (try? JSONEncoder().encode(self.notes)) ?? Data("[]".utf8)
        var payload = Data(capacity: 16 + notes.count + png.count)
        payload.appendBE(id)
        payload.appendBE(UInt32(clamping: max(0, width)))
        payload.appendBE(UInt32(clamping: max(0, height)))
        payload.appendBE(UInt32(notes.count))
        payload.append(notes)
        payload.appendBE(UInt32(png.count))
        payload.append(png)
        let folder = WorkingFolder.encode(self.folder)
        payload.appendBE(UInt16(folder.count))
        payload.append(folder)
        let spoken = Data(self.spoken.utf8.prefix(Self.spokenByteLimit))
        // The screen block is written empty when only the spoken words follow it.
        if !screenPng.isEmpty || !spoken.isEmpty {
            payload.appendBE(UInt32(clamping: screenPng.isEmpty ? 0 : max(0, screenWidth)))
            payload.appendBE(UInt32(clamping: screenPng.isEmpty ? 0 : max(0, screenHeight)))
            payload.appendBE(UInt32(screenPng.count))
            payload.append(screenPng)
        }
        if !spoken.isEmpty {
            payload.appendBE(UInt32(spoken.count))
            payload.append(spoken)
        }
        return payload
    }

    init?(payload: Data) {
        var cursor = PayloadCursor(payload)
        guard let id = cursor.u32(),
              let width = cursor.u32(),
              let height = cursor.u32(),
              let noteCount = cursor.u32(),
              let notes = cursor.bytes(Int(noteCount)),
              let decoded = try? JSONDecoder().decode([IntentNote].self, from: notes),
              let pngCount = cursor.u32(),
              let png = cursor.bytes(Int(pngCount)),
              width > 0, height > 0, png.starts(with: InkSnapshot.pngSignature),
              let folderCount = cursor.u16(),
              let folderBytes = cursor.bytes(Int(folderCount)),
              let folder = WorkingFolder.decode(folderBytes) else { return nil }
        if cursor.isAtEnd {
            self.init(id: id, width: Int(width), height: Int(height), notes: decoded, png: png, folder: folder)
            return
        }
        guard let screenWidth = cursor.u32(),
              let screenHeight = cursor.u32(),
              let screenCount = cursor.u32(),
              let screenPng = cursor.bytes(Int(screenCount)) else { return nil }
        if !screenPng.isEmpty {
            guard screenWidth > 0, screenHeight > 0, screenPng.starts(with: InkSnapshot.pngSignature) else { return nil }
        }
        var spoken = ""
        if !cursor.isAtEnd {
            guard let spokenCount = cursor.u32(),
                  spokenCount <= UInt32(Self.spokenByteLimit),
                  let spokenBytes = cursor.bytes(Int(spokenCount)),
                  let text = String(data: spokenBytes, encoding: .utf8) else { return nil }
            spoken = text
        }
        guard cursor.isAtEnd else { return nil }
        self.init(
            id: id,
            width: Int(width),
            height: Int(height),
            notes: decoded,
            png: png,
            screenWidth: Int(screenWidth),
            screenHeight: Int(screenHeight),
            screenPng: screenPng,
            folder: folder,
            spoken: spoken
        )
    }

    static let spokenByteLimit = 8_000
}

enum WorkingFolder {
    static func encode(_ path: String) -> Data {
        Data(path.utf8.prefix(1024))
    }

    /// Empty is allowed. Any other path must be an absolute Mac path.
    static func decode(_ payload: Data) -> String? {
        if payload.isEmpty { return "" }
        guard payload.count <= 1024,
              !payload.contains(0),
              let path = String(data: payload, encoding: .utf8),
              path.hasPrefix("/") else { return nil }
        return path
    }
}

private extension IntentReply {
    func encodedPayload() -> Data {
        let lead = Data(lead.utf8.prefix(200))
        let name = Data(name.utf8.prefix(80))
        let text = Data(text.utf8.prefix(IntentReply.textLimit(for: kind)))
        var payload = Data(capacity: 11 + lead.count + name.count + text.count)
        payload.appendBE(id)
        payload.append(kind.rawValue)
        payload.appendBE(UInt16(lead.count))
        payload.append(lead)
        payload.appendBE(UInt16(name.count))
        payload.append(name)
        payload.appendBE(UInt32(text.count))
        payload.append(text)
        return payload
    }

    init?(payload: Data) {
        var cursor = PayloadCursor(payload)
        guard let id = cursor.u32(),
              let kindRaw = cursor.u8(),
              let kind = Kind(rawValue: kindRaw),
              let leadCount = cursor.u16(),
              let leadBytes = cursor.bytes(Int(leadCount)),
              let nameCount = cursor.u16(),
              let nameBytes = cursor.bytes(Int(nameCount)),
              let textCount = cursor.u32(),
              let textBytes = cursor.bytes(Int(textCount)),
              cursor.isAtEnd,
              let lead = String(data: leadBytes, encoding: .utf8),
              let name = String(data: nameBytes, encoding: .utf8),
              let text = String(data: textBytes, encoding: .utf8) else { return nil }
        self.init(id: id, kind: kind, lead: lead, name: name, text: text)
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
        case .trackpadMove(let dx, let dy):
            var payload = Data([5])
            payload.appendBE(dx)
            payload.appendBE(dy)
            return payload
        case .trackpadTap(let fingers, let zone):
            return Data([6, fingers, zone.rawValue])
        case .trackpadDrag(let dx, let dy, let phase, let fingers):
            var payload = Data([7, phase.rawValue, fingers])
            payload.appendBE(dx)
            payload.appendBE(dy)
            return payload
        case .trackpadMagnify(let magnification, let phase):
            var payload = Data([8, phase.rawValue])
            payload.appendBE(magnification)
            return payload
        case .goToDesktop(let index):
            return Data([9, index])
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
        case 5:
            guard payload.count == 5 else { return nil }
            let dx = Int16(bitPattern: UInt16(payload[1]) << 8 | UInt16(payload[2]))
            let dy = Int16(bitPattern: UInt16(payload[3]) << 8 | UInt16(payload[4]))
            self = .trackpadMove(dx: dx, dy: dy)
        case 6:
            guard payload.count == 3,
                  payload[1] == 1 || payload[1] == 2,
                  let zone = TrackpadTapZone(rawValue: payload[2]) else { return nil }
            self = .trackpadTap(fingers: payload[1], zone: zone)
        case 7:
            guard payload.count == 7,
                  let phase = PointerPhase(rawValue: payload[1]),
                  payload[2] >= 1, payload[2] <= 5 else { return nil }
            let dx = Int16(bitPattern: UInt16(payload[3]) << 8 | UInt16(payload[4]))
            let dy = Int16(bitPattern: UInt16(payload[5]) << 8 | UInt16(payload[6]))
            self = .trackpadDrag(dx: dx, dy: dy, phase: phase, fingers: payload[2])
        case 8:
            guard payload.count == 4, let phase = TrackpadScrollPhase(rawValue: payload[1]) else { return nil }
            let magnification = Int16(bitPattern: UInt16(payload[2]) << 8 | UInt16(payload[3]))
            self = .trackpadMagnify(magnification: magnification, phase: phase)
        case 9:
            guard payload.count == 2 else { return nil }
            self = .goToDesktop(index: payload[1])
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
