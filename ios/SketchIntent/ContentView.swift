import SwiftUI
import UIKit

private enum SwipeSettings {
    static let naturalKey = "naturalSwiping"
}

private enum TrackpadSettings {
    static let speedKey = "trackpadTrackingSpeed"
    static let defaultSpeed = 1.0
    static let minimumSpeed = 0.25
    static let maximumSpeed = 2.5
}

private enum CanvasSettings {
    static let blankKey = "blankCanvas"
}

enum StrokeSettings {
    static let widthKey = "strokeWidth"
    static let defaultWidth = 4.0
    static let minimumWidth = 1.0
    static let maximumWidth = 20.0
    static let colorKey = "inkColor"

    static func clamped(_ width: Double) -> CGFloat {
        CGFloat(min(maximumWidth, max(minimumWidth, width)))
    }
}

/// The Mac picture, and its pixel size, from the moment a desktop's sketch started.
private struct FrozenPicture {
    var image: UIImage
    var width: Int
    var height: Int
}

struct ContentView: View {
    @StateObject private var client = StreamClient()
    @StateObject private var sketch = SketchCanvas()
    @StateObject private var intent = IntentClient()
    @StateObject private var dictation = AgentDictation()
    @StateObject private var live = LiveSession()
    @Environment(\.scenePhase) private var scenePhase
    @State private var dictationHaptic = UIImpactFeedbackGenerator(style: .medium)
    @State private var tool = SketchTool.pen
    @State private var showsSidebar = false
    @State private var showsSettings = false
    @State private var showsTrackpad = false
    @State private var desktopHint: DesktopDirection?
    @State private var hintToken = 0
    @State private var toolSelection = UISelectionFeedbackGenerator()
    @State private var frozenBySpace: [String: FrozenPicture] = [:]
    /// Where each sent sketch sits on the canvas, by intent id, for the agent's drawing.
    @State private var agentPlacements: [UInt32: AgentPlacement] = [:]
    @AppStorage(SwipeSettings.naturalKey) private var naturalSwiping = true
    @AppStorage(CanvasSettings.blankKey) private var blankCanvas = false
    @AppStorage(TrackpadSettings.speedKey) private var trackingSpeed = TrackpadSettings.defaultSpeed
    @AppStorage(StrokeSettings.widthKey) private var strokeWidth = StrokeSettings.defaultWidth
    @AppStorage(StrokeSettings.colorKey) private var inkColorName = InkColor.red.rawValue
    @State private var trackingResidualX = 0.0
    @State private var trackingResidualY = 0.0

    /// The page accepts drawing and chrome once a picture is up, and immediately in blank-canvas mode.
    private var canvasReady: Bool {
        blankCanvas || client.hasFrame
    }

    /// Pointer mapping needs the captured size. Without it a click would land on a bogus origin.
    private var hasCapturedFrameSize: Bool {
        client.frameWidth > 0 && client.frameHeight > 0
    }

    /// A finger drives the Mac with the pen or the eraser, until this desktop has a sketch.
    /// Dictation and lasso keep the finger off the Mac. A Pencil touch never uses it.
    private var sendsFingerPointer: Bool {
        !sketch.hasInk
            && !blankCanvas
            && tool != .voice
            && tool != .lasso
            && hasCapturedFrameSize
            && canvasReady
    }

    /// The still picture for the desktop on screen, taken when its sketch began.
    private var shownFrozen: FrozenPicture? {
        if let id = client.spaceID {
            if let frame = frozenBySpace[id] { return frame }
            if frozenBySpace.count == 1 { return frozenBySpace[""] }
            return nil
        }
        return frozenBySpace[""]
    }

    /// Ink and pointer mapping stay on the frame the sketch started with.
    private var sketchFrameWidth: Int {
        shownFrozen?.width ?? client.frameWidth
    }

    private var sketchFrameHeight: Int {
        shownFrozen?.height ?? client.frameHeight
    }

    /// Searching chrome stays while the Mac is disconnected. Blank canvas is black before the first frame.
    private var showsWaiting: Bool {
        if blankCanvas {
            return !client.isConnected
        }
        return !client.hasFrame
    }

    private var inkColor: InkColor {
        InkColor(rawValue: inkColorName) ?? .red
    }

    private var surface: CanvasSurface {
        blankCanvas ? .canvas : .desktop(client.desktopIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar(
                    showsSidebar: $showsSidebar,
                    workingFolder: client.workingFolder,
                    isChoosingFolder: client.isChoosingFolder,
                    isConnected: client.isConnected,
                    surface: surface,
                    desktopCount: client.desktopCount,
                    canSend: (sketch.hasInk || sketch.hasNotes) && !intent.isSending,
                    isSending: intent.isSending,
                    isLive: live.isOn,
                    onChooseFolder: { client.requestWorkingFolder() },
                    onClearFolder: { client.clearWorkingFolder() },
                    onSurface: selectSurface,
                    onSend: { sendSketch() },
                    onStop: stopAgent,
                    onLive: toggleLive,
                    onSettings: { showsSettings = true }
                )
                HStack(spacing: 0) {
                    if showsSidebar {
                        AgentSidebar(
                            turns: intent.turns,
                            isSending: intent.isSending,
                            isLive: live.isOn,
                            heard: live.isOn ? live.heard : dictation.heard,
                            onStop: stopAgent
                        )
                            .transition(.move(edge: .leading))
                    }
                    VStack(spacing: 0) {
                        stage
                        BottomBar(
                            tool: tool,
                            inkColor: inkColor,
                            canClear: sketch.hasInk || shownFrozen != nil,
                            isLive: live.isOn,
                            onTool: chooseTool,
                            onColor: { inkColorName = $0.rawValue },
                            onClear: clearSketch,
                            onDictationBegan: beginDictation,
                            onDictationEnded: endDictation
                        )
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: showsSidebar)
            }
            .ignoresSafeArea()

            if showsTrackpad && canvasReady {
                VirtualTrackpad(
                    onMove: { dx, dy in
                        let scaled = scaleTracking(dx, dy)
                        guard scaled.dx != 0 || scaled.dy != 0 else { return }
                        client.send(.trackpadMove(dx: scaled.dx, dy: scaled.dy))
                    },
                    onScroll: { dx, dy, phase in
                        let scaled = scaleTracking(dx, dy)
                        client.send(.trackpadScroll(dx: scaled.dx, dy: scaled.dy, phase: phase))
                    },
                    onTap: { fingers, zone in
                        client.send(.trackpadTap(fingers: fingers, zone: zone))
                    },
                    onDrag: { dx, dy, phase, fingers in
                        let scaled = scaleTracking(dx, dy)
                        client.send(.trackpadDrag(dx: scaled.dx, dy: scaled.dy, phase: phase, fingers: fingers))
                    },
                    onSwipe: { swipe in
                        guard !sketch.hasInk else { return }
                        switchDesktop(desktopDirection(for: swipe, natural: naturalSwiping))
                    },
                    onMagnify: { factor, phase in
                        client.send(.trackpadMagnify(magnification: macMagnification(factor), phase: phase))
                    }
                )
                .ignoresSafeArea()
                // A ZStack child needs a fixed zIndex, or its removal skips the fade.
                .zIndex(1)
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(canvasReady ? .hidden : .automatic)
        .animation(.easeOut(duration: 0.18), value: desktopHint)
        .sheet(isPresented: $showsSettings) {
            SettingsSheet(client: client)
        }
        .onAppear {
            client.start()
            client.onIntentReply = { reply in
                if reply.kind == .canvas {
                    showAgentRender(reply)
                    return
                }
                if reply.kind == .screen {
                    // The agent opened something on the Mac. The Mac already chose the desktop.
                    if intent.isWorking(on: reply.id) { blankCanvas = false }
                    return
                }
                if reply.kind == .done || reply.kind == .error {
                    agentPlacements[reply.id] = nil
                }
                let working = intent.isWorking(on: reply.id)
                if intent.apply(reply) {
                    // The agent read the sketch, so its ink goes. Its images stay on the Canvas.
                    sketch.wipeSentInk { space in
                        frozenBySpace[space] = nil
                        frozenBySpace[""] = nil
                    }
                } else if working, reply.kind == .error {
                    sketch.cancelSent()
                }
            }
            live.canSend = {
                !intent.isSending && client.isConnected && !sketch.isMarking
            }
            live.send = { spoken in
                sendSketch(spoken: spoken, live: true)
            }
            live.onFailure = { message in
                showsSidebar = true
                intent.fail(message)
            }
            sketch.onEdit = { live.pageEdited() }
            sketch.onVoiceNoteMic = { claimed in
                live.hold(.voiceNote, claimed)
            }
            toolSelection.prepare()
            dictationHaptic.prepare()
            updateIdleTimer()
        }
        .onChange(of: scenePhase) { _, phase in
            // The microphone is never kept in the background.
            live.hold(.background, phase == .background)
        }
        .onChange(of: client.hasFrame) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: blankCanvas) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: trackingSpeed) { _, _ in
            trackingResidualX = 0
            trackingResidualY = 0
        }
        .onChange(of: sketch.hasInk) { _, hasInk in
            if hasInk {
                showsTrackpad = false
            } else {
                frozenBySpace[client.spaceID ?? ""] = nil
            }
        }
        .onChange(of: client.spaceID) { _, id in
            guard let id, frozenBySpace[id] == nil, let pending = frozenBySpace.removeValue(forKey: "") else { return }
            frozenBySpace[id] = pending
        }
        .onChange(of: canvasReady) { _, ready in
            if !ready {
                showsTrackpad = false
            }
        }
    }

    /// The Mac picture, or the dotted canvas, between the two bars. Ink sits on top of either.
    /// The canvas keeps its own sketch and never draws on the Mac.
    private var stage: some View {
        ZStack {
            if blankCanvas {
                DotCanvas()
            }
            ScreenDisplay(
                client: client,
                liveWidth: client.frameWidth,
                liveHeight: client.frameHeight,
                showsPicture: !blankCanvas,
                frozenImage: shownFrozen?.image,
                frozenWidth: shownFrozen?.width ?? 0,
                frozenHeight: shownFrozen?.height ?? 0
            )
            .opacity(blankCanvas ? 0 : 1)
            .accessibilityHidden(blankCanvas)
            PencilOverlay(
                spaceID: blankCanvas ? Self.canvasSketchID : client.spaceID,
                canvas: sketch,
                tool: tool,
                strokeWidth: StrokeSettings.clamped(strokeWidth),
                inkColor: inkColor.color,
                outlinesInk: blankCanvas,
                acceptsTap: canvasReady,
                acceptsCanvasSwipe: shownFrozen != nil && sketch.hasInk,
                pansPage: blankCanvas,
                sendsFingerPointer: sendsFingerPointer,
                frameWidth: blankCanvas ? 0 : sketchFrameWidth,
                frameHeight: blankCanvas ? 0 : sketchFrameHeight,
                onFingerPointer: { phase, x, y in
                    // A finger on the picture: a tap clicks, a drag scrolls, a hold right-clicks.
                    client.send(.pointer(phase, x: x, y: y, contact: .finger))
                },
                onFingerCancel: { x, y in
                    // A second finger ends that contact. Button-up cancels it so a
                    // three-finger swipe can switch desktops: a still finger stays
                    // cancelled, and an open scroll or right-click finishes.
                    client.send(.pointer(.up, x: x, y: y, contact: .button))
                },
                onInk: { png, width, height, spaceID in
                    client.sendInk(png: png, width: width, height: height, spaceID: spaceID)
                },
                onTap: { canvasTapped() },
                onDoubleTap: { fingerDoubleTapped() },
                onFingerSwipe: { swipe in
                    guard !sketch.hasInk else { return }
                    switchDesktop(desktopDirection(for: swipe, natural: naturalSwiping))
                },
                onFingerPinch: { factor, phase in
                    client.send(.trackpadMagnify(magnification: macMagnification(factor), phase: phase))
                },
                onToggleTool: { toggleToolFromPencil() },
                onSketchBegan: { freezeFrameForCurrentSpace() },
                onSketchAbandoned: { frozenBySpace[$0] = nil }
            )
            .accessibilityHidden(true)
            if showsWaiting {
                waiting
                    .allowsHitTesting(!blankCanvas)
            }
            if let desktopHint {
                Image(systemName: desktopHint == .left ? "chevron.left" : "chevron.right")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 64, weight: .medium))
                    .imageScale(.medium)
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityHidden(true)
                    .padding(28)
                    .background(.ultraThinMaterial, in: Circle())
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Sketch key for the dotted canvas. Mac desktops use their Mission Control id.
    private static let canvasSketchID = "canvas"

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = client.hasFrame || blankCanvas
    }

    /// Sends the sketch. `spoken` is what was said through the dictation button, or in live mode.
    /// Words go out even on an empty page, which is then sent whole so the agent sees what was on screen.
    /// `live` marks a moment from live mode.
    private func sendSketch(spoken: String = "", live: Bool = false) {
        guard !intent.isSending else { return }
        let wholePage = !spoken.isEmpty
        // An empty desktop is only looked at, so its live picture keeps playing.
        let screen = screenForIntent(freezes: !wholePage || self.sketch.hasInk)
        guard let sketch = self.sketch.intentSketch(screen: screen, wholePage: wholePage) else {
            if wholePage {
                showsSidebar = true
                intent.fail("The page couldn't be read")
            }
            return
        }
        showsSidebar = true
        guard client.isConnected else {
            intent.fail("The Mac isn't connected")
            return
        }
        let request = intent.begin(sketch, folder: client.workingFolder, spoken: spoken, drawnOn: drawnOn, live: live)
        agentPlacements = [request.id: sketch.placement]
        if client.sendIntent(request) {
            self.sketch.markSent()
        } else {
            intent.fail("The sketch is too large to send")
        }
    }

    /// Live mode sends what is said and drawn on its own, a moment at a time. The sidebar opens
    /// to show it.
    private func toggleLive() {
        if live.isOn {
            live.stop()
        } else {
            showsSidebar = true
            live.start()
            // Dictation and lasso are hidden while live, so neither stays chosen.
            if !SketchTool.liveOrder.contains(tool) {
                chooseTool(.pen)
            }
        }
    }

    /// Holding the dictation button talks to the agent. The sidebar shows the words as they come.
    /// Live mode is already listening, so the hold does nothing then.
    private func beginDictation() {
        guard !intent.isSending, !live.isOn else { return }
        showsSidebar = true
        dictationHaptic.impactOccurred()
        dictationHaptic.prepare()
        dictation.begin { message in
            intent.fail(message)
        }
    }

    /// Letting go sends what was said, with the sketch when there is one.
    private func endDictation() {
        let spoken = dictation.end()
        guard !spoken.isEmpty else { return }
        sendSketch(spoken: spoken)
    }

    /// An image from the agent's show_image tool, for a sketch it is still working on.
    /// It always goes on the Canvas page, centered and fit inside it, so the person
    /// can mark it up there. Once it is on the page, the view moves to the Canvas.
    private func showAgentRender(_ reply: IntentReply) {
        guard intent.isWorking(on: reply.id),
              var placement = agentPlacements[reply.id],
              let data = reply.text.data(using: .utf8),
              let render = try? JSONDecoder().decode(AgentRender.self, from: data) else { return }
        placement.spaceID = Self.canvasSketchID
        sketch.showAgentRender(render, placement: placement) {
            selectSurface(.canvas)
        }
    }

    /// The page the sketch is on, for the agent. Nil until the Mac has listed its desktops.
    private var drawnOn: IntentRequest.DrawnOn? {
        switch surface {
        case .canvas:
            return .canvas
        case .desktop(let index):
            return client.desktopCount > 0 ? .desktop(index) : nil
        }
    }

    /// Stops the agent on the iPad and on the Mac.
    private func stopAgent() {
        guard let id = intent.stop() else { return }
        sketch.cancelSent()
        client.cancelIntent(id)
    }

    /// Canvas shows the dotted page. A space shows that Mac desktop, and opens it on the Mac.
    private func selectSurface(_ next: CanvasSurface) {
        switch next {
        case .canvas:
            blankCanvas = true
        case .desktop(let index):
            blankCanvas = false
            guard index >= 0, index != client.desktopIndex, index <= Int(UInt8.max) else { return }
            client.send(.goToDesktop(index: UInt8(index)))
        }
    }

    private func chooseTool(_ next: SketchTool) {
        guard next != tool else { return }
        toolSelection.selectionChanged()
        toolSelection.prepare()
        tool = next
    }

    /// One-finger tap. While the trackpad is up, that tap dismisses it. The finger's
    /// pointer packets follow the touch. This waits until a double-tap has failed.
    /// A double-tap shows the trackpad.
    private func canvasTapped() {
        if showsTrackpad {
            showsTrackpad = false
        }
    }

    /// Removes this desktop's sketch and returns the picture to the live Mac frame.
    private func clearSketch() {
        sketch.clearSketch()
        frozenBySpace[client.spaceID ?? ""] = nil
        frozenBySpace[""] = nil
    }
    /// The Mac picture under the ink. A sketch freezes that picture when the first stroke starts.
    /// Sending again captures it if that freeze missed, and keeps it frozen when `freezes` is set.
    private func screenForIntent(freezes: Bool = true) -> UIImage? {
        guard !blankCanvas else { return nil }
        if let image = shownFrozen?.image { return image }
        guard let captured = client.captureDisplayedFrame() else { return nil }
        if freezes {
            frozenBySpace[client.spaceID ?? ""] = FrozenPicture(
                image: captured.image,
                width: captured.width,
                height: captured.height
            )
        }
        return captured.image
    }

    private func freezeFrameForCurrentSpace() {
        guard !blankCanvas, client.hasFrame else { return }
        let key = client.spaceID ?? ""
        guard frozenBySpace[key] == nil, let captured = client.captureDisplayedFrame() else { return }
        frozenBySpace[key] = FrozenPicture(image: captured.image, width: captured.width, height: captured.height)
    }
    /// A finger double-tap opens the trackpad. A desktop that already has a sketch keeps the finger off the Mac.
    private func fingerDoubleTapped() {
        guard canvasReady, !sketch.hasInk else { return }
        showsTrackpad = true
    }

    /// Apple Pencil barrel double-tap. Cycles the right-edge slider's tools
    /// (only pen and eraser while live) without presenting a dial. The Pencil keeps drawing.
    /// A finger drives the Mac on an empty desktop with the pen or the eraser.
    /// Lasso keeps the finger off the Mac.
    private func toggleToolFromPencil() {
        toolSelection.selectionChanged()
        toolSelection.prepare()
        tool = tool.next(live: live.isOn)
    }

    /// Separation ratio since the last sample, as the wire's ten-thousandths. 1 is no change.
    private func macMagnification(_ factor: CGFloat) -> Int16 {
        guard factor.isFinite, factor > 0 else { return 0 }
        return Int16(clamping: Int(((factor - 1) * 10_000).rounded()))
    }

    /// Leftover fraction so a slow tracking speed still moves the pointer.
    private func scaleTracking(_ dx: Int16, _ dy: Int16) -> (dx: Int16, dy: Int16) {
        let speed = min(TrackpadSettings.maximumSpeed, max(TrackpadSettings.minimumSpeed, trackingSpeed))
        trackingResidualX += Double(dx) * speed
        trackingResidualY += Double(dy) * speed
        let ix = Int(trackingResidualX.rounded(.towardZero))
        let iy = Int(trackingResidualY.rounded(.towardZero))
        trackingResidualX -= Double(ix)
        trackingResidualY -= Double(iy)
        return (Int16(clamping: ix), Int16(clamping: iy))
    }

    /// Opens the desktop `direction` points at, and flashes a chevron that way.
    private func switchDesktop(_ direction: DesktopDirection) {
        guard client.hasFrame || (blankCanvas && client.isConnected) else { return }
        client.send(.switchDesktop(direction))
        desktopHint = direction
        hintToken += 1
        let token = hintToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            if hintToken == token {
                desktopHint = nil
            }
        }
    }

    /// Natural swiping matches a Mac trackpad: fingers moving left open the desktop on the right.
    private func desktopDirection(for swipe: FingerSwipe, natural: Bool) -> DesktopDirection {
        switch swipe {
        case .left:
            return natural ? .right : .left
        case .right:
            return natural ? .left : .right
        }
    }

    private var waiting: some View {
        VStack(spacing: 22) {
            Image(systemName: "ipad.and.arrow.forward")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 56, weight: .medium))
                .imageScale(.medium)
                .foregroundStyle(.white)
                .accessibilityHidden(true)
            Text("Waiting for your Mac")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(instructions, id: \.self) { step in
                    Text(step)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 460, alignment: .leading)
            Text(client.badge)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(32)
    }

    private var instructions: [String] {
        #if targetEnvironment(simulator)
        [
            "Run SketchIntent Server on this Mac.",
            "This simulator connects to it on its own."
        ]
        #else
        [
            "Run SketchIntent Server on the Mac.",
            "Connect this iPad with a USB cable and tap Trust.",
            blankCanvas
                ? "Leave SketchIntent open. This page stays black while the Mac stays connected."
                : "Leave SketchIntent open. The Mac screen appears here.",
            "Swipe left or right with three fingers to move between desktops."
        ]
        #endif
    }
}

private struct SettingsSheet: View {
    @ObservedObject var client: StreamClient
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SwipeSettings.naturalKey) private var naturalSwiping = true
    @AppStorage(TrackpadSettings.speedKey) private var trackingSpeed = TrackpadSettings.defaultSpeed
    @AppStorage(StrokeSettings.widthKey) private var strokeWidth = StrokeSettings.defaultWidth
    @AppStorage(CartesiaSettings.key) private var cartesiaAPIKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        client.requestWorkingFolder()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Working folder")
                                Text(client.workingFolder.isEmpty ? "Not chosen" : client.workingFolder)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if client.isChoosingFolder {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!client.isConnected || client.isChoosingFolder)
                    if !client.workingFolder.isEmpty {
                        Button("Clear folder", role: .destructive) {
                            client.clearWorkingFolder()
                        }
                    }
                } footer: {
                    Text(client.isConnected
                        ? "Opens a folder panel on the Mac. The agent works in that folder."
                        : "Connect to the Mac to choose the folder the agent works in.")
                }
                Section {
                    Slider(
                        value: $strokeWidth,
                        in: StrokeSettings.minimumWidth...StrokeSettings.maximumWidth,
                        step: 0.5
                    ) {
                        Text("Stroke width")
                    } minimumValueLabel: {
                        Text("1")
                            .font(.caption2)
                            .accessibilityHidden(true)
                    } maximumValueLabel: {
                        Text("20")
                            .font(.caption2)
                            .accessibilityHidden(true)
                    }
                    .accessibilityValue(Text(strokeWidthLabel))
                } footer: {
                    Text("New pen strokes and snapped shapes use this width. Ink already on the page keeps its width.")
                }
                Section {
                    Toggle("Natural swiping", isOn: $naturalSwiping)
                } footer: {
                    Text(detail)
                }
                Section {
                    Slider(
                        value: $trackingSpeed,
                        in: TrackpadSettings.minimumSpeed...TrackpadSettings.maximumSpeed,
                        step: 0.05
                    ) {
                        Text("Tracking speed")
                    } minimumValueLabel: {
                        Image(systemName: "tortoise.fill")
                            .accessibilityHidden(true)
                    } maximumValueLabel: {
                        Image(systemName: "hare.fill")
                            .accessibilityHidden(true)
                    }
                    .accessibilityValue(Text(trackingSpeedLabel))
                } footer: {
                    Text("Scales pointer movement, scrolling, and three-finger drag on the virtual trackpad. The Mac's tracking speed still applies.")
                }
                Section {
                    SecureField("Cartesia API key", text: $cartesiaAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Voice notes are transcribed by Cartesia Ink-2. The key stays on this iPad.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var strokeWidthLabel: String {
        if strokeWidth.rounded() == strokeWidth {
            return "\(Int(strokeWidth)) points"
        }
        return String(format: "%.1f points", strokeWidth)
    }

    private var trackingSpeedLabel: String {
        let percent = Int((trackingSpeed * 100).rounded())
        return "\(percent) percent"
    }

    private var detail: String {
        if naturalSwiping {
            return "On, this matches the Mac trackpad. A three-finger swipe left opens the desktop on the right, and a swipe right opens the desktop on the left."
        }
        return "Off, swiping is inverted. A three-finger swipe left opens the desktop on the left, and a swipe right opens the desktop on the right."
    }
}
