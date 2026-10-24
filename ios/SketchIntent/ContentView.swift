import SwiftUI
import UIKit

private enum SwipeSettings {
    static let naturalKey = "naturalSwiping"
}

private struct SharedSketch: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ContentView: View {
    @StateObject private var client = StreamClient()
    @StateObject private var sketch = SketchCanvas()
    @State private var tool = SketchTool.pen
    @State private var showsChrome = true
    @State private var showsSettings = false
    @State private var sharedSketch: SharedSketch?
    @State private var desktopHint: DesktopDirection?
    @State private var hintToken = 0
    @AppStorage(SwipeSettings.naturalKey) private var naturalSwiping = true

    private var showsStatusChrome: Bool {
        !client.hasFrame || showsChrome
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScreenDisplay(client: client)
                .ignoresSafeArea()
            PencilOverlay(spaceID: client.spaceID, canvas: sketch, tool: tool, acceptsTap: client.hasFrame) {
                showsChrome.toggle()
            } onFingerSwipe: { swipe in
                switchDesktop(desktopDirection(for: swipe, natural: naturalSwiping))
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
            if !client.hasFrame {
                waiting
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
                showsTools: client.hasFrame,
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
        .statusBarHidden(client.hasFrame && !showsChrome)
        .persistentSystemOverlays(client.hasFrame && !showsChrome ? .hidden : .visible)
        .animation(.easeOut(duration: 0.18), value: desktopHint)
        .sheet(isPresented: $showsSettings) {
            SettingsSheet()
        }
        .sheet(item: $sharedSketch) { sketch in
            ActivityView(image: sketch.image)
        }
        .onAppear {
            client.start()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: client.hasFrame) { _, hasFrame in
            UIApplication.shared.isIdleTimerDisabled = hasFrame
        }
    }

    private func sendSketch() {
        guard let image = sketch.snapshot() else { return }
        sharedSketch = SharedSketch(image: image)
    }

    /// Opens the desktop `direction` points at, and flashes a chevron that way.
    private func switchDesktop(_ direction: DesktopDirection) {
        guard client.hasFrame else { return }
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
            "Leave SketchIntent open. The Mac screen appears here.",
            "Swipe left or right with three fingers to move between desktops."
        ]
        #endif
    }
}

private struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SwipeSettings.naturalKey) private var naturalSwiping = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Natural swiping", isOn: $naturalSwiping)
                } footer: {
                    Text(detail)
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
}

private struct ActivityView: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
