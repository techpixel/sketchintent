import Foundation
import SketchIntentServerCore

let server = Server(config: ServerConfig.parse())
do {
    try server.run()
} catch {
    fputs("[sketchintent] \(error)\n", stderr)
    exit(1)
}
dispatchMain()
