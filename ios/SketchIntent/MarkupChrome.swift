import SwiftUI
import UIKit

/// Floating markup controls. Empty space falls through to the canvas.
struct MarkupChrome: UIViewControllerRepresentable {
    var showsTools: Bool
    var showsGear: Bool
    var tool: SketchTool
    var canSend: Bool
    var onTool: (SketchTool) -> Void
    var onSend: () -> Void
    var onSettings: () -> Void

    func makeUIViewController(context: Context) -> MarkupChromeController {
        let controller = MarkupChromeController()
        controller.onTool = onTool
        controller.onSend = onSend
        controller.onSettings = onSettings
        return controller
    }

    func updateUIViewController(_ controller: MarkupChromeController, context: Context) {
        controller.onTool = onTool
        controller.onSend = onSend
        controller.onSettings = onSettings
        controller.showsTools = showsTools
        controller.showsGear = showsGear
        controller.tool = tool
        controller.canSend = canSend
        controller.reload()
    }
}

final class MarkupChromeController: UIViewController {
    var showsTools = false
    var showsGear = false
    var tool = SketchTool.pen
    var canSend = false
    var onTool: (SketchTool) -> Void = { _ in }
    var onSend: () -> Void = {}
    var onSettings: () -> Void = {}

    private let toolBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let penButton = UIButton(type: .system)
    private let eraserButton = UIButton(type: .system)
    private let divider = UIView()
    private let sendButton = UIButton(type: .system)
    private let sendPlate = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let gearButton = UIButton(type: .system)
    private let gearPlate = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let selection = UISelectionFeedbackGenerator()

    override func loadView() {
        view = PassthroughHost()
        view.backgroundColor = .clear
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configure(toolBar, radius: 26)
        divider.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        toolBar.contentView.addSubview(penButton)
        toolBar.contentView.addSubview(divider)
        toolBar.contentView.addSubview(eraserButton)
        view.addSubview(toolBar)

        configure(sendPlate, radius: 28)
        style(sendButton, symbol: "arrow.up", pointSize: 20, weight: .semibold)
        sendButton.accessibilityLabel = "Send sketch"
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendPlate.contentView.addSubview(sendButton)
        view.addSubview(sendPlate)

        configure(gearPlate, radius: 22)
        style(gearButton, symbol: "gearshape", pointSize: 17, weight: .medium)
        gearButton.accessibilityLabel = "Settings"
        gearButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)
        gearPlate.contentView.addSubview(gearButton)
        view.addSubview(gearPlate)

        style(penButton, symbol: "pencil.and.outline", pointSize: 20, weight: .medium)
        penButton.accessibilityLabel = "Pencil"
        penButton.addTarget(self, action: #selector(penTapped), for: .touchUpInside)
        style(eraserButton, symbol: "eraser.fill", pointSize: 18, weight: .medium)
        eraserButton.accessibilityLabel = "Eraser"
        eraserButton.addTarget(self, action: #selector(eraserTapped), for: .touchUpInside)
        selection.prepare()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        let bounds = view.bounds

        let toolWidth: CGFloat = 108
        let toolHeight: CGFloat = 52
        toolBar.frame = CGRect(
            x: (bounds.width - toolWidth) / 2,
            y: safe.top + 10,
            width: toolWidth,
            height: toolHeight
        )
        penButton.frame = CGRect(x: 4, y: 4, width: 48, height: 44)
        divider.frame = CGRect(x: 53.5, y: 16, width: 1, height: 20)
        eraserButton.frame = CGRect(x: 56, y: 4, width: 48, height: 44)

        let sendSide: CGFloat = 56
        sendPlate.frame = CGRect(
            x: bounds.width - safe.right - 20 - sendSide,
            y: (bounds.height - sendSide) / 2,
            width: sendSide,
            height: sendSide
        )
        sendButton.frame = sendPlate.bounds

        let gearSide: CGFloat = 44
        gearPlate.frame = CGRect(
            x: bounds.width - safe.right - 20 - gearSide,
            y: safe.top + 10,
            width: gearSide,
            height: gearSide
        )
        gearButton.frame = gearPlate.bounds
    }

    func reload() {
        guard isViewLoaded else { return }
        toolBar.isHidden = !showsTools
        sendPlate.isHidden = !showsTools
        gearPlate.isHidden = !showsGear
        sendButton.isEnabled = canSend
        sendPlate.alpha = canSend ? 1 : 0.4
        refresh(penButton, selected: tool == .pen)
        refresh(eraserButton, selected: tool == .eraser)
    }

    private func configure(_ plate: UIVisualEffectView, radius: CGFloat) {
        plate.clipsToBounds = true
        plate.layer.cornerCurve = .continuous
        plate.layer.cornerRadius = radius
        plate.isUserInteractionEnabled = true
    }

    private func style(_ button: UIButton, symbol: String, pointSize: CGFloat, weight: UIImage.SymbolWeight) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        configuration.baseForegroundColor = .white
        configuration.background.cornerRadius = 18
        button.configuration = configuration
    }

    private func refresh(_ button: UIButton, selected: Bool) {
        var configuration = button.configuration ?? .plain()
        configuration.baseForegroundColor = .white
        configuration.background.backgroundColor = selected ? UIColor.white.withAlphaComponent(0.22) : .clear
        button.configuration = configuration
        button.accessibilityTraits = selected ? [.button, .selected] : .button
    }

    @objc private func penTapped() {
        choose(.pen)
    }

    @objc private func eraserTapped() {
        choose(.eraser)
    }

    private func choose(_ next: SketchTool) {
        guard tool != next else { return }
        selection.selectionChanged()
        onTool(next)
    }

    @objc private func sendTapped() {
        guard canSend else { return }
        onSend()
    }

    @objc private func settingsTapped() {
        onSettings()
    }
}

/// Full-screen host that only accepts touches on its controls.
private final class PassthroughHost: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
