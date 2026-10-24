import Foundation
import StreamProtocol

/// Publishes the direct TCP port so an iPad on the same network can find this Mac.
final class ServiceAdvertiser: NSObject, NetServiceDelegate {
    private var service: NetService?

    func start(name: String, port: Int) {
        let service = NetService(domain: "local.", type: "\(SketchIntentPorts.bonjourType).", name: name, port: Int32(port))
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.publish()
        self.service = service
    }

    func netServiceDidPublish(_ sender: NetService) {
        print("[sketchintent] Advertising \(SketchIntentPorts.bonjourType) as \(sender.name).")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        print("[sketchintent] Bonjour advertisement failed: \(errorDict)")
    }
}
