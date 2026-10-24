import SwiftUI
import UIKit

private enum SwipeSettings {
    static let naturalKey = "naturalSwiping"
}

private enum CanvasSettings {
    static let blankKey = "blankCanvas"
}

/// UserDefaults keys the pointer-mode setting may use. The toggle writes `key`.
private enum PencilMacControl {
    static let key = "pencilControlsMac"
    static let storageKeys = [
        key,
        "controlMacWithPencil",
        "controlsMacWithPencil"
    ]
}

private struct SharedSketch: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ContentView: View {
    @StateObject private var client = StreamClient()
    @StateObject private var sketch = SketchCanvas()
    @State private var tool = SketchTool.pen
    @State private var showsToolDial = false
    @State private var showsChrome = true
    @State private var showsSettings = false
    @State private var showsTrackpad = false
    @State private var sharedSketch: SharedSketch?
    @State private var desktopHint: DesktopDirection?
    @State private var hintToken = 0
    @State private var toolSelection = UISelectionFeedbackGenerator()
    @AppStorage(SwipeSettings.naturalKey) private var naturalSwiping = true
    @AppStorage(PencilMacControl.key) private var pencilControlsMacStored = false
    @AppStorage(CanvasSettings.blankKey) private var blankCanvas = false

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

    private var sendsPencilPointer: Bool {
        (pencilControlsMac || tool == .pointer) && hasCapturedFrameSize && canvasReady
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
            ScreenDisplay(client: client, showsPicture: !blankCanvas)
                .ignoresSafeArea()
                .opacity(blankCanvas ? 0 : 1)
                .accessibilityHidden(blankCanvas)
            PencilOverlay(
                spaceID: client.spaceID,
                canvas: sketch,
                tool: tool,
                acceptsTap: canvasReady,
                drawsWithPencil: !pencilControlsMac && tool != .pointer,
                sendsPointer: sendsPencilPointer,
                frameWidth: client.frameWidth,
                frameHeight: client.frameHeight,
                onPencilPointer: { phase, x, y in
                    // The pointer tool is one finger: a tap clicks, a drag scrolls, a hold right-clicks.
                    // Control the Mac with Pencil uses that same finger path for every other tool.
                    let contact: PointerContact = (pencilControlsMac || tool == .pointer) ? .finger : .button
                    client.send(.pointer(phase, x: x, y: y, contact: contact))
                },
                onInk: { png, width, height, spaceID in
                    client.sendInk(png: png, width: width, height: height, spaceID: spaceID)
                },
                onTap: { canvasTapped() },
                onDoubleTap: { fingerDoubleTapped() },
                onFingerSwipe: { swipe in
                    switchDesktop(desktopDirection(for: swipe, natural: naturalSwiping))
                },
                onToggleTool: { toggleToolFromPencil() }
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

            if showsTrackpad && canvasReady {
                VirtualTrackpad(
                    onScroll: { dx, dy, phase in
                        client.send(.trackpadScroll(dx: dx, dy: dy, phase: phase))
                    },
                    onClick: { button, phase in
                        client.send(.trackpadClick(button, phase))
                    }
                )
                .ignoresSafeArea()
                .transition(.opacity)
            }

            if let desktopHint {
                Image(systemName: desktopHint == .left ? "chevron.left" : "chevron.right")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(28)
                    .background(.ultraThinMaterial, in: Circle())
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            MarkupChrome(
                showsTools: canvasReady,
                showsDial: showsToolDial,
                showsGear: showsStatusChrome,
                tool: tool,
                canSend: sketch.hasInk,
                onTool: { tool = $0 },
                onSend: sendSketch,
                onSettings: { showsSettings = true },
                onDismissDial: { showsToolDial = false }
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

    /// One-finger tap. Shows or hides the status badge. While the tool dial is up,
    /// the same tap also dismisses the dial. While the trackpad is up, that tap
    /// only dismisses the trackpad. A finger double-tap is a different gesture.
    private func canvasTapped() {
        if showsTrackpad {
            showsTrackpad = false
            return
        }
        if showsToolDial {
            showsToolDial = false
        }
        showsChrome.toggle()
    }

    /// Finger double-tap on the stream. The Pencil barrel double-tap does not come here,
    /// and this still shows the pad while the Pencil is drawing, erasing, or recording.
    private func fingerDoubleTapped() {
        guard canvasReady else { return }
        showsTrackpad = true
    }

    /// Apple Pencil barrel double-tap. The first one shows the tool dial.
    /// Another, while the dial is up, moves clockwise through pen, pointer, eraser, and voice, then dismisses the dial.
    /// When Settings is using the Pencil as a pointer on the Mac, the double-tap is ignored.
    private func toggleToolFromPencil() {
        guard !pencilControlsMac else { return }
        toolSelection.selectionChanged()
        toolSelection.prepare()
        if showsToolDial {
            tool = tool.nextOnDial
            showsToolDial = false
        } else {
            showsToolDial = true
        }
    }

    /// True when "Control the Mac with Pencil" is on. Default is off until a key is stored.
    /// Once `pencilControlsMac` is written, that value wins over any alias key.
    private var pencilControlsMac: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: PencilMacControl.key) != nil {
            return pencilControlsMacStored
        }
        for key in PencilMacControl.storageKeys where key != PencilMacControl.key && defaults.object(forKey: key) != nil {
            if defaults.bool(forKey: key) { return true }
        }
        return pencilControlsMacStored
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
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.white)
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
    @AppStorage(PencilMacControl.key) private var pencilControlsMac = false
    @AppStorage(CanvasSettings.blankKey) private var blankCanvas = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Natural swiping", isOn: $naturalSwiping)
                } footer: {
                    Text(detail)
                }
                Section {
                    Toggle("Control the Mac with Pencil", isOn: $pencilControlsMac)
                } footer: {
                    Text(pencilDetail)
                }
                Section {
                    Toggle("Blank canvas", isOn: $blankCanvas)
                } footer: {
                    Text(blankCanvasDetail)
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
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var detail: String {
        if naturalSwiping {
            return "On, this matches the Mac trackpad. A three-finger swipe left opens the desktop on the right, and a swipe right opens the desktop on the left."
        }
        return "Off, swiping is inverted. A three-finger swipe left opens the desktop on the left, and a swipe right opens the desktop on the right."
    }

    private var pencilDetail: String {
        if pencilControlsMac {
            return "On, the Pencil is a finger on the Mac for every tool, including the pointer: a tap clicks, a drag scrolls, and a hold right-clicks. Drawing and voice notes stay off while this is on."
        }
        return "Off, the Pencil draws, and the voice tool records while the Pencil is held. The pointer tool is still a finger: a tap clicks, a drag scrolls, and a hold right-clicks."
    }

    private var blankCanvasDetail: String {
        if blankCanvas {
            return "On, the page is black and the Mac picture stays hidden. Drawing, voice notes, desktop swipes, and Pencil clicks keep working while the connection stays up."
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
