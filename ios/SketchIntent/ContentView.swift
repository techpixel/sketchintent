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

private struct SharedSketch: Identifiable {
    let id = UUID()
    let image: UIImage
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
    @State private var tool = SketchTool.pen
    @State private var showsChrome = true
    @State private var showsSettings = false
    @State private var showsTrackpad = false
    @State private var sharedSketch: SharedSketch?
    @State private var desktopHint: DesktopDirection?
    @State private var hintToken = 0
    @State private var toolSelection = UISelectionFeedbackGenerator()
    @State private var frozenBySpace: [String: FrozenPicture] = [:]
    @AppStorage(SwipeSettings.naturalKey) private var naturalSwiping = true
    @AppStorage(CanvasSettings.blankKey) private var blankCanvas = false
    @AppStorage(TrackpadSettings.speedKey) private var trackingSpeed = TrackpadSettings.defaultSpeed
    @State private var trackingResidualX = 0.0
    @State private var trackingResidualY = 0.0

    private var showsStatusChrome: Bool {
        !canvasReady || showsChrome
    }

    /// The page accepts drawing and chrome once a picture is up, and immediately in blank-canvas mode.
    private var canvasReady: Bool {
        blankCanvas || client.hasFrame
    }

    /// Pointer mapping needs the captured size. Without it a click would land on a bogus origin.
    private var hasCapturedFrameSize: Bool {
        client.frameWidth > 0 && client.frameHeight > 0
    }

    /// A finger drives the Mac with the pen or the eraser, until this desktop has a sketch.
    /// Lasso keeps the finger off the Mac. A Pencil touch never uses it.
    private var sendsFingerPointer: Bool {
        !sketch.hasInk
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScreenDisplay(
                client: client,
                showsPicture: !blankCanvas,
                frozenImage: shownFrozen?.image,
                frozenWidth: shownFrozen?.width ?? 0,
                frozenHeight: shownFrozen?.height ?? 0
            )
            .ignoresSafeArea()
            .opacity(blankCanvas ? 0 : 1)
            .accessibilityHidden(blankCanvas)
            PencilOverlay(
                spaceID: client.spaceID,
                canvas: sketch,
                tool: tool,
                acceptsTap: canvasReady,
                acceptsCanvasSwipe: shownFrozen != nil && sketch.hasInk,
                sendsFingerPointer: sendsFingerPointer,
                frameWidth: sketchFrameWidth,
                frameHeight: sketchFrameHeight,
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
                onToggleTool: { toggleToolFromPencil() },
                onSketchBegan: { freezeFrameForCurrentSpace() },
                onSketchAbandoned: { frozenBySpace[$0] = nil }
            )
            .ignoresSafeArea()
            .accessibilityHidden(true)
            if showsWaiting {
                waiting
                    .allowsHitTesting(!blankCanvas)
            }

            if showsStatusChrome {
                VStack {
                    statusBadge
                    Spacer()
                }
                .padding(.leading, 20)
                .padding(.trailing, 72)
                .padding(.top, 12)
                .allowsHitTesting(false)
            }

            if client.hasFrame && showsStatusChrome {
                VStack {
                    Spacer()
                    HStack {
                        Text("\(client.framesPerSecond) fps")
                            .font(.subheadline.weight(.medium).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                    }
                }
                .padding(.leading, 20)
                .padding(.bottom, 16)
                .allowsHitTesting(false)
            }

            if sketch.hasInk || shownFrozen != nil {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: clearSketch) {
                            Image(systemName: "trash")
                                .symbolRenderingMode(.monochrome)
                                .font(.system(size: 20, weight: .medium))
                                .imageScale(.medium)
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Clear sketch")
                    }
                    Spacer()
                }
                .padding(.top, 10)
                .padding(.trailing, showsStatusChrome ? 74 : 20)
            }

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
                    }
                )
                .ignoresSafeArea()
                .transition(.opacity)
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

            MarkupChrome(
                showsTools: canvasReady,
                showsGear: showsStatusChrome,
                tool: tool,
                canSend: sketch.hasInk,
                onTool: { tool = $0 },
                onSend: sendSketch,
                onSettings: { showsSettings = true }
            )
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(canvasReady && !showsChrome)
        .persistentSystemOverlays(canvasReady && !showsChrome ? .hidden : .visible)
        .animation(.easeOut(duration: 0.18), value: desktopHint)
        .animation(.easeOut(duration: 0.16), value: showsTrackpad)
        .sheet(isPresented: $showsSettings) {
            SettingsSheet()
        }
        .sheet(item: $sharedSketch) { sketch in
            ActivityView(image: sketch.image)
        }
        .onAppear {
            client.start()
            toolSelection.prepare()
            updateIdleTimer()
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

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = client.hasFrame || blankCanvas
    }

    private func sendSketch() {
        guard let image = sketch.snapshot() else { return }
        sharedSketch = SharedSketch(image: image)
    }

    /// One-finger tap. Shows or hides the status badge. While the trackpad is up,
    /// that tap only dismisses the trackpad. The finger's pointer packets follow
    /// the touch. This toggle waits until a double-tap has failed. A double-tap
    /// shows the trackpad.
    private func canvasTapped() {
        if showsTrackpad {
            showsTrackpad = false
            return
        }
        showsChrome.toggle()
    }

    /// Removes this desktop's sketch and returns the picture to the live Mac frame.
    private func clearSketch() {
        sketch.clearSketch()
        frozenBySpace[client.spaceID ?? ""] = nil
        frozenBySpace[""] = nil
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
    /// (pen, eraser, lasso) without presenting a dial. The Pencil keeps drawing.
    /// A finger drives the Mac on an empty desktop with the pen or the eraser.
    /// Lasso keeps the finger off the Mac.
    private func toggleToolFromPencil() {
        toolSelection.selectionChanged()
        toolSelection.prepare()
        tool = tool.nextOnDial
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
        }
        .padding(32)
    }

    private var statusBadge: some View {
        HStack {
            Text(client.badge)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            Spacer()
        }
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
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SwipeSettings.naturalKey) private var naturalSwiping = true
    @AppStorage(TrackpadSettings.speedKey) private var trackingSpeed = TrackpadSettings.defaultSpeed
    @AppStorage(CanvasSettings.blankKey) private var blankCanvas = false
    @AppStorage(CartesiaSettings.key) private var cartesiaAPIKey = ""

    var body: some View {
        NavigationStack {
            Form {
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
                    Toggle("Blank canvas", isOn: $blankCanvas)
                } footer: {
                    Text(blankCanvasDetail)
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

    private var blankCanvasDetail: String {
        if blankCanvas {
            return "On, the page is black and the Mac picture stays hidden. Drawing, voice notes, and desktop swipes keep working while the connection stays up."
        }
        return "Off, the live Mac screen shows here."
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
