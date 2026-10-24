import SwiftUI
import UIKit

private enum FingerSwipe {
    case left
    case right
}

private enum SwipeSettings {
    static let naturalKey = "naturalSwiping"
}

struct ContentView: View {
    @StateObject private var client = StreamClient()
    @State private var showsChrome = true
    @State private var showsSettings = false
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
            PencilOverlay()
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

            ScreenTouchLayer(acceptsTap: client.hasFrame) {
                showsChrome.toggle()
            } onFingerSwipe: { swipe in
                switchDesktop(desktopDirection(for: swipe, natural: naturalSwiping))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()

            SettingsGear(isVisible: showsStatusChrome) {
                showsSettings = true
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(client.hasFrame && !showsChrome)
        .persistentSystemOverlays(client.hasFrame && !showsChrome ? .hidden : .visible)
        .animation(.easeOut(duration: 0.18), value: desktopHint)
        .sheet(isPresented: $showsSettings) {
            SettingsSheet()
        }
        .onAppear {
            client.start()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: client.hasFrame) { _, hasFrame in
            UIApplication.shared.isIdleTimerDisabled = hasFrame
        }
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
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Natural swiping", isOn: $naturalSwiping)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.black)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.black)
    }

    private var detail: String {
        if naturalSwiping {
            return "On, this matches the Mac trackpad. A three-finger swipe left opens the desktop on the right, and a swipe right opens the desktop on the left."
        }
        return "Off, swiping is inverted. A three-finger swipe left opens the desktop on the left, and a swipe right opens the desktop on the right."
    }
}

/// Gear in the top-right corner. Touches anywhere else fall through to the gesture layer.
private struct SettingsGear: UIViewControllerRepresentable {
    var isVisible: Bool
    var action: () -> Void

    func makeUIViewController(context: Context) -> GearController {
        let controller = GearController()
        controller.action = action
        return controller
    }

    func updateUIViewController(_ controller: GearController, context: Context) {
        controller.action = action
        controller.setVisible(isVisible)
    }
}

private final class GearController: UIViewController {
    var action: () -> Void = {}
    private let button = UIButton(type: .system)
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))

    override func loadView() {
        view = PassthroughView()
        view.backgroundColor = .clear
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        blur.isUserInteractionEnabled = false
        blur.clipsToBounds = true
        blur.layer.cornerRadius = 18
        view.addSubview(blur)

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "gearshape")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        configuration.baseForegroundColor = .white
        button.configuration = configuration
        button.accessibilityLabel = "Settings"
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        view.addSubview(button)

        button.translatesAutoresizingMaskIntoConstraints = false
        blur.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 36),
            blur.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            blur.topAnchor.constraint(equalTo: button.topAnchor),
            blur.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
    }

    func setVisible(_ visible: Bool) {
        button.isHidden = !visible
        blur.isHidden = !visible
    }

    @objc private func tapped() {
        action()
    }
}

/// Full-screen host that only accepts touches on its subviews.
private final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// One-finger tap toggles the status badge. Three-finger swipes change desktops.
private struct ScreenTouchLayer: UIViewRepresentable {
    var acceptsTap: Bool
    var onTap: () -> Void
    var onFingerSwipe: (FingerSwipe) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(acceptsTap: acceptsTap, onTap: onTap, onFingerSwipe: onFingerSwipe)
    }

    func makeUIView(context: Context) -> FingerTouchView {
        let view = FingerTouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.numberOfTouchesRequired = 1
        tap.allowedTouchTypes = FingerTouchView.fingerTouchTypes
        view.addGestureRecognizer(tap)

        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:)))
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 3
            swipe.allowedTouchTypes = FingerTouchView.fingerTouchTypes
            view.addGestureRecognizer(swipe)
        }
        return view
    }

    func updateUIView(_ uiView: FingerTouchView, context: Context) {
        context.coordinator.acceptsTap = acceptsTap
        context.coordinator.onTap = onTap
        context.coordinator.onFingerSwipe = onFingerSwipe
    }

    final class Coordinator: NSObject {
        var acceptsTap: Bool
        var onTap: () -> Void
        var onFingerSwipe: (FingerSwipe) -> Void

        init(acceptsTap: Bool, onTap: @escaping () -> Void, onFingerSwipe: @escaping (FingerSwipe) -> Void) {
            self.acceptsTap = acceptsTap
            self.onTap = onTap
            self.onFingerSwipe = onFingerSwipe
        }

        @objc func tapped() {
            guard acceptsTap else { return }
            onTap()
        }

        @objc func swiped(_ recognizer: UISwipeGestureRecognizer) {
            switch recognizer.direction {
            case .left:
                onFingerSwipe(.left)
            case .right:
                onFingerSwipe(.right)
            default:
                break
            }
        }
    }
}
