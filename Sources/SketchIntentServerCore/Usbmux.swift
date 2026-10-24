import Foundation
import StreamProtocol

struct USBDevice: Equatable {
    var deviceID: Int
    var serialNumber: String
    var connectionType: String
}

enum UsbmuxError: Error, Equatable, CustomStringConvertible {
    case badResponse
    case result(Int)

    var description: String {
        switch self {
        case .badResponse:
            return "usbmuxd returned a response SketchIntent could not read."
        case .result(let code):
            switch code {
            case 3:
                return "The iPad refused the USB connection. Open SketchIntent on the iPad."
            case 2:
                return "That iPad is no longer available over USB."
            default:
                return "usbmuxd rejected the connection (code \(code))."
            }
        }
    }

    var isRefused: Bool {
        if case .result(3) = self { return true }
        return false
    }
}

/// Talks to `/var/run/usbmuxd` and turns a successful Connect into a raw byte pipe.
enum Usbmux {
    static let socketPath = "/var/run/usbmuxd"

    static func listDevices() throws -> [USBDevice] {
        let fd = try POSIX.connectUNIX(path: socketPath)
        defer { POSIX.close(fd) }
        try sendPlist([
            "MessageType": "ListDevices",
            "ClientVersionString": "SketchIntent-1.0",
            "ProgName": "SketchIntent"
        ], tag: 1, fd: fd)

        let response = try readPlist(fd)
        let list = response["DeviceList"] as? [[String: Any]] ?? []
        return list.compactMap(parseDevice)
    }

    /// On success the returned descriptor is the tunnel to `port` on the device.
    static func connect(deviceID: Int, port: UInt16) throws -> Int32 {
        let fd = try POSIX.connectUNIX(path: socketPath)
        do {
            try sendPlist([
                "MessageType": "Connect",
                "ClientVersionString": "SketchIntent-1.0",
                "ProgName": "SketchIntent",
                "DeviceID": deviceID,
                "PortNumber": USBMuxPorts.plistValue(for: port)
            ], tag: 1, fd: fd)
            let response = try readPlist(fd)
            let code = integer(response["Number"]) ?? -1
            guard code == 0 else { throw UsbmuxError.result(code) }
            return fd
        } catch {
            POSIX.close(fd)
            throw error
        }
    }

    private static func parseDevice(_ item: [String: Any]) -> USBDevice? {
        let properties = item["Properties"] as? [String: Any] ?? item
        guard let deviceID = integer(properties["DeviceID"]) ?? integer(item["DeviceID"]) else {
            return nil
        }
        let serial = properties["SerialNumber"] as? String ?? ""
        let connection = properties["ConnectionType"] as? String ?? "USB"
        return USBDevice(deviceID: deviceID, serialNumber: serial, connectionType: connection)
    }

    private static func sendPlist(_ body: [String: Any], tag: UInt32, fd: Int32) throws {
        let payload = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        var packet = Data()
        appendLE(UInt32(16 + payload.count), to: &packet)
        appendLE(1, to: &packet) // plist protocol version
        appendLE(8, to: &packet) // plist message
        appendLE(tag, to: &packet)
        packet.append(payload)
        guard POSIX.writeAll(fd, packet) else {
            throw SocketError.failed("write usbmuxd", EPIPE)
        }
    }

    private static func readPlist(_ fd: Int32) throws -> [String: Any] {
        let header = try POSIX.readExact(fd, count: 16)
        let length = readLE(header, offset: 0)
        guard length >= 16, length < 4_000_000 else { throw UsbmuxError.badResponse }
        let body = try POSIX.readExact(fd, count: Int(length - 16))
        let object = try PropertyListSerialization.propertyList(from: body, options: [], format: nil)
        guard let dictionary = object as? [String: Any] else { throw UsbmuxError.badResponse }
        return dictionary
    }

    private static func appendLE(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func readLE(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            return number
        case let number as NSNumber:
            return number.intValue
        default:
            return nil
        }
    }
}
