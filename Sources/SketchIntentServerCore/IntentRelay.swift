import Foundation
import StreamProtocol

/// Forwards one sketch to the AI server on this Mac and sends each reply line back.
/// The iPad never opens its own connection to that server. The bytes travel on the
/// socket this Mac already has, including the USB tunnel.
final class IntentRelay {
    private let lock = NSLock()
    private var job: Task<Void, Never>?
    private var jobID: UInt32?

    func cancel() {
        lock.lock()
        job?.cancel()
        job = nil
        jobID = nil
        lock.unlock()
    }

    /// Stops the agent only if it is still working on `id`.
    func cancel(_ id: UInt32) {
        lock.lock()
        guard jobID == id else {
            lock.unlock()
            return
        }
        job?.cancel()
        job = nil
        jobID = nil
        lock.unlock()
    }

    func start(_ request: IntentRequest, reply: @escaping (IntentReply) -> Void) {
        cancel()
        let job = Task { [weak self] in
            guard let self else { return }
            await self.run(request, reply: reply)
        }
        lock.lock()
        self.job = job
        jobID = request.id
        lock.unlock()
    }

    private func run(_ request: IntentRequest, reply: @escaping (IntentReply) -> Void) async {
        let id = request.id
        do {
            var urlRequest = URLRequest(url: Self.endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.timeoutInterval = 180
            var object: [String: Any] = [
                "imagePng": request.png.base64EncodedString(),
                "width": request.width,
                "height": request.height,
                "notes": request.notes.map { ["text": $0.text, "x": $0.x, "y": $0.y] }
            ]
            if !request.screenPng.isEmpty {
                object["screenPng"] = request.screenPng.base64EncodedString()
                object["screenWidth"] = request.screenWidth
                object["screenHeight"] = request.screenHeight
            }
            if request.folder.hasPrefix("/") {
                object["folder"] = request.folder
            }
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: object)
            let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                reply(IntentReply(id: id, kind: .error, text: "SketchIntent AI didn't answer"))
                return
            }
            if http.statusCode != 200 {
                var message = "SketchIntent AI didn't answer"
                for try await line in bytes.lines {
                    if let data = line.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let error = object["error"] as? String, !error.isEmpty {
                        message = error
                        break
                    }
                }
                reply(IntentReply(id: id, kind: .error, text: message))
                return
            }
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = object["type"] as? String else { continue }
                switch type {
                case "status":
                    reply(IntentReply(
                        id: id,
                        kind: .status,
                        lead: object["lead"] as? String ?? "Calling ",
                        name: object["name"] as? String ?? "",
                        // "canvas" for the agent's canvas tools. The iPad shows those in blue.
                        text: object["tone"] as? String ?? ""
                    ))
                case "text":
                    reply(IntentReply(id: id, kind: .text, text: object["text"] as? String ?? ""))
                case "error":
                    reply(IntentReply(id: id, kind: .error, text: object["message"] as? String ?? "The agent stopped"))
                case "canvas":
                    // Strokes and notes for the iPad canvas, passed on as the JSON the AI server wrote.
                    var drawing = object
                    drawing.removeValue(forKey: "type")
                    guard let encoded = try? JSONSerialization.data(withJSONObject: drawing),
                          encoded.count <= IntentReply.textLimit(for: .canvas),
                          let text = String(data: encoded, encoding: .utf8) else { continue }
                    reply(IntentReply(id: id, kind: .canvas, text: text))
                case "done":
                    reply(IntentReply(id: id, kind: .done))
                default:
                    break
                }
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            reply(IntentReply(id: id, kind: .error, text: "SketchIntent AI isn't running on this Mac"))
        }
    }

    private static let endpoint = URL(string: "http://127.0.0.1:\(SketchIntentPorts.ai)/v1/intent")!
}
