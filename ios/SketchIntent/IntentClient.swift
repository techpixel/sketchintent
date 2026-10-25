import Foundation

/// One line the agent produced while working on a sketch.
enum AgentStep: Equatable {
    /// "Calling" plus the tool name, shown with the name in bold. `onCanvas` is the
    /// agent rendering to the canvas, shown in blue.
    case status(lead: String, name: String?, onCanvas: Bool)
    case text(String)
    case error(String)
}

/// One sketch sent to the agent and everything it answered. Shown in the chat sidebar.
struct AgentTurn: Identifiable, Equatable {
    enum State: Equatable {
        case working
        case finished
        case stopped
    }

    /// One step and when it arrived. Live turns show the time beside each line.
    struct Entry: Equatable {
        var step: AgentStep
        var at: Date
    }

    var id: UInt32
    /// The voice notes on the sketch and anything said through the dictation button. Empty when there were none.
    var prompt: String
    var steps: [Entry] = []
    var state: State = .working
    /// A moment from live mode rather than a sketch sent by hand.
    var live = false
    var startedAt = Date()
}

/// The cropped sketch, the voice notes on it, and the whole Mac screen for context.
struct IntentSketch {
    var png: Data
    var width: Int
    var height: Int
    var notes: [IntentNote]
    var screenPng: Data
    var screenWidth: Int
    var screenHeight: Int
    /// Where these images sit on the canvas, so the agent's drawing lands where it saw things.
    var placement: AgentPlacement
}

/// Pixels in the sketch image, or the whole-screen image, mapped back to canvas points.
/// A point is `origin + pixel / pixelsPerPoint`.
struct AgentPlacement {
    /// The desktop the sketch came from. Nil before the Mac names one.
    var spaceID: String?
    var sketchOrigin: CGPoint
    var sketchPixelsPerPoint: CGFloat
    /// Nil when no whole-screen image was sent, as on the canvas.
    var screenOrigin: CGPoint?
    var screenPixelsPerPoint: CGFloat?
}

/// What the AI server's show_image tool sends: code the iPad renders to an image.
/// The frame is in pixels of `space`.
struct AgentRender: Decodable {
    /// "sketch" or "screen".
    var space: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// A complete HTML document.
    var html: String
}

/// The agent conversation for sketches sent over the Mac connection.
final class IntentClient: ObservableObject {
    @Published private(set) var turns: [AgentTurn] = []
    @Published private(set) var isSending = false

    private var nextID: UInt32 = 1
    private var activeID: UInt32 = 0

    /// Starts a turn and returns the packet to send on the open Mac socket.
    /// `spoken` is what was said while holding the dictation button.
    /// `drawnOn` is the page the sketch was drawn on, or nil before the Mac has listed its desktops.
    func begin(
        _ sketch: IntentSketch,
        folder: String,
        spoken: String = "",
        drawnOn: IntentRequest.DrawnOn? = nil,
        live: Bool = false
    ) -> IntentRequest {
        let id = nextID
        nextID &+= 1
        activeID = id
        isSending = true
        let prompt = (sketch.notes.map(\.text) + [spoken])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        turns.append(AgentTurn(id: id, prompt: prompt, live: live))
        return IntentRequest(
            id: id,
            width: sketch.width,
            height: sketch.height,
            notes: sketch.notes,
            png: sketch.png,
            screenWidth: sketch.screenWidth,
            screenHeight: sketch.screenHeight,
            screenPng: sketch.screenPng,
            folder: folder,
            spoken: spoken,
            drawnOn: drawnOn,
            live: live
        )
    }

    /// The sketch never reached the agent, or the open turn could not go on.
    func fail(_ message: String) {
        if isSending, let index = activeIndex {
            add(.error(message), at: index)
            finish(as: .finished)
            return
        }
        let id = nextID
        nextID &+= 1
        turns.append(AgentTurn(id: id, prompt: "", steps: [.init(step: .error(message), at: Date())], state: .finished))
    }

    /// Ends the open turn on the iPad. Returns its id so the Mac can stop the agent too.
    func stop() -> UInt32? {
        guard isSending, activeIndex != nil else { return nil }
        let id = activeID
        finish(as: .stopped)
        return id
    }

    /// Returns true when this reply is the agent finishing the sketch it was sent.
    @discardableResult
    func apply(_ reply: IntentReply) -> Bool {
        guard reply.id == activeID, isSending, let index = activeIndex else { return false }
        switch reply.kind {
        case .status:
            // The AI server reports a tool call as it starts and again when its message completes.
            let step = AgentStep.status(
                lead: reply.lead,
                name: reply.name.isEmpty ? nil : reply.name,
                onCanvas: reply.text == "canvas"
            )
            if turns[index].steps.last?.step != step {
                add(step, at: index)
            }
        case .text:
            if case .text = turns[index].steps.last?.step {
                turns[index].steps[turns[index].steps.count - 1].step = .text(reply.text)
            } else {
                add(.text(reply.text), at: index)
            }
        case .error:
            add(.error(reply.text.isEmpty ? "The agent stopped" : reply.text), at: index)
            finish(as: .finished)
        case .canvas, .screen:
            // The image goes to the canvas, and a screen reply changes the page. Both already have a status line.
            break
        case .done:
            let answered = turns[index].steps.contains { entry in
                if case .text = entry.step { return true }
                if case .status = entry.step { return true }
                return false
            }
            // A live moment that needs nothing yet gets no answer on purpose.
            if !answered && !turns[index].live {
                add(.error("The agent didn't answer"), at: index)
            }
            finish(as: .finished)
            return true
        }
        return false
    }

    /// True while the agent is still working on `id`. A stopped turn's late drawing is dropped.
    func isWorking(on id: UInt32) -> Bool {
        isSending && id == activeID
    }

    private func add(_ step: AgentStep, at index: Int) {
        turns[index].steps.append(.init(step: step, at: Date()))
    }

    private var activeIndex: Int? {
        turns.lastIndex { $0.id == activeID }
    }

    private func finish(as state: AgentTurn.State) {
        guard isSending else { return }
        isSending = false
        if let index = activeIndex {
            turns[index].state = state
        }
    }
}
