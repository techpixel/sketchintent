import Foundation
import StreamProtocol

public struct ServerConfig {
    var tcpPort: UInt16 = SketchIntentPorts.tcp
    var usbPort: UInt16 = SketchIntentPorts.usb
    var fps: Int = 60
    /// Average H.264 bitrate, in bits per second. 60 Mbps is sharp on the iPad over USB.
    var bitrate: Int = 60_000_000
    /// Encoded width cap. 2732 is the iPad Pro 12.9-inch panel, so the picture is not upscaled.
    var maxWidth: Int = 2732
    var displayIndex: Int?

    public static func parse(_ arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> ServerConfig {
        var config = ServerConfig()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value(_ name: String) -> String? {
                guard index + 1 < arguments.count else {
                    fputs("Missing value for \(name).\n", stderr)
                    exit(2)
                }
                index += 1
                return arguments[index]
            }
            switch argument {
            case "--help", "-h":
                print(ServerConfig.help)
                exit(0)
            case "--tcp-port":
                config.tcpPort = UInt16(value(argument) ?? "") ?? config.tcpPort
            case "--usb-port":
                config.usbPort = UInt16(value(argument) ?? "") ?? config.usbPort
            case "--fps":
                config.fps = min(120, max(1, Int(value(argument) ?? "") ?? config.fps))
            case "--bitrate":
                let megabits = min(80, max(2, Double(value(argument) ?? "") ?? 60))
                config.bitrate = Int(megabits * 1_000_000)
            case "--max-width":
                config.maxWidth = min(4096, max(640, Int(value(argument) ?? "") ?? config.maxWidth))
            case "--display":
                config.displayIndex = Int(value(argument) ?? "")
            default:
                fputs("Unknown option \(argument).\n\(ServerConfig.help)\n", stderr)
                exit(2)
            }
            index += 1
        }
        return config
    }

    static let help = """
    SketchIntent Server streams this Mac's screen to the SketchIntent iPad app.

    Usage: SketchIntentServer [--fps 60] [--bitrate 60] [--max-width 2732]
                              [--tcp-port 2346] [--usb-port 2345] [--display N]

    --bitrate is the H.264 average rate in megabits per second. The encoder
    is hardware H.264 with B-frames disabled, so a new frame is not held
    back waiting on a future one.

    USB:
      Connect the iPad with a cable and tap Trust. This server reaches the
      iPad app through usbmuxd on device port \(SketchIntentPorts.usb).
      Install and open the iPad app from ios/SketchIntent.xcodeproj.

    Simulator and network:
      The server also listens on TCP \(SketchIntentPorts.tcp) and advertises
      \(SketchIntentPorts.bonjourType). The iOS Simulator connects to 127.0.0.1
      on that port. An iPad on the same network can connect that way too.

    Screen Recording permission is required. The first launch asks for it.
    For a stable permission grant, package the server with scripts/package-mac-app.sh.
    """
}
