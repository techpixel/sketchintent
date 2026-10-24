import AppKit
import Foundation
import SketchIntentServerCore

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let server = Server(config: ServerConfig.parse())
do {
    try server.run()
} catch {
    fputs("[sketchintent] \(error)\n", stderr)
    exit(1)
}
app.run()
