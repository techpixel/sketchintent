import SwiftUI
import UIKit

/// Floating markup controls. The send tab hangs from the top edge. The tool
/// slider is attached to the right edge. Empty space falls through to the canvas.
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

/// Spacing shared by the send tab (Figma 28:356) and the tool slider (Figma 28:326).
private enum ChromeMetrics {
    /// `rounded-bl` / `rounded-br` of 16 on the send tab. The slider uses the same radius on its free corners.
    static let cornerRadius: CGFloat = 16
    static let sendWidth: CGFloat = 200
    static let sendHeight: CGFloat = 49
    static let sliderWidth: CGFloat = 60
    /// Node 28:326 is 385pt tall with 8pt padding and 10pt gaps around three equal segments.
    static let sliderLength: CGFloat = 385
    static let sliderPadding: CGFloat = 8
    static let sliderGap: CGFloat = 10
    static let segmentCornerRadius: CGFloat = 8
    static let segmentLength: CGFloat = (sliderLength - sliderPadding * 2 - sliderGap * 2) / 3
    /// Selected tool chip from node 28:340. Not a system token.
    static let selectedFill = UIColor(red: 0, green: 113 / 255, blue: 227 / 255, alpha: 0.4)
}

/// Medium weight and medium scale for every chrome symbol.
private func chromeSymbolConfiguration(pointSize: CGFloat) -> UIImage.SymbolConfiguration {
    UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium, scale: .medium)
}

final class MarkupChromeController: UIViewController {
    var showsTools = false
    var showsGear = false
    var tool = SketchTool.pen
    var canSend = false
    var onTool: (SketchTool) -> Void = { _ in }
    var onSend: () -> Void = {}
    var onSettings: () -> Void = {}

    private let toolSlider = ToolSliderView()
    private let sendButton = UIButton(type: .system)
    private let sendPlate = GlassTab(roundedCorners: [.bottomLeft, .bottomRight])
    private let gearButton = UIButton(type: .system)
    private let gearPlate = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let selection = UISelectionFeedbackGenerator()

    override func loadView() {
        view = PassthroughHost()
        view.backgroundColor = .clear
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        toolSlider.onSelect = { [weak self] tool in
            self?.choose(tool)
        }
        view.addSubview(toolSlider)

        sendPlate.isUserInteractionEnabled = true
        style(
            sendButton,
            symbol: "arrow.up",
            pointSize: 22,
            contentInsets: NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        )
        sendButton.accessibilityLabel = "Send sketch"
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendPlate.addSubview(sendButton)
        view.addSubview(sendPlate)

        configure(gearPlate, radius: 22)
        style(gearButton, symbol: "gearshape", pointSize: 20)
        gearButton.accessibilityLabel = "Settings"
        gearButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)
        gearPlate.contentView.addSubview(gearButton)
        view.addSubview(gearPlate)

        selection.prepare()
        toolSlider.setSelected(tool)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        let bounds = view.bounds

        sendPlate.frame = CGRect(
            x: (bounds.width - ChromeMetrics.sendWidth) / 2,
            y: 0,
            width: ChromeMetrics.sendWidth,
            height: ChromeMetrics.sendHeight
        )
        sendButton.frame = sendPlate.bounds

        let sliderHeight = ToolSliderView.preferredHeight
        var sliderY = (bounds.height - sliderHeight) / 2
        let gearBottom = safe.top + 10 + 44
        if sliderY < gearBottom + 12 {
            sliderY = min(gearBottom + 12, max(0, bounds.height - sliderHeight))
        }
        toolSlider.frame = CGRect(
            x: bounds.width - ChromeMetrics.sliderWidth,
            y: max(0, sliderY),
            width: ChromeMetrics.sliderWidth,
            height: sliderHeight
        )

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
        let toolsVisible = showsTools
        sendPlate.isHidden = !toolsVisible
        toolSlider.isHidden = !toolsVisible
        gearPlate.isHidden = !showsGear
        sendButton.isEnabled = canSend
        sendPlate.alpha = canSend ? 1 : 0.4
        toolSlider.setSelected(tool)
    }

    private func configure(_ plate: UIVisualEffectView, radius: CGFloat) {
        plate.clipsToBounds = true
        plate.layer.cornerCurve = .continuous
        plate.layer.cornerRadius = radius
        plate.isUserInteractionEnabled = true
    }

    private func style(
        _ button: UIButton,
        symbol: String,
        pointSize: CGFloat,
        contentInsets: NSDirectionalEdgeInsets = .zero
    ) {
        let symbolConfiguration = chromeSymbolConfiguration(pointSize: pointSize)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: symbolConfiguration)
        configuration.preferredSymbolConfigurationForImage = symbolConfiguration
        configuration.baseForegroundColor = .white
        configuration.contentInsets = contentInsets
        configuration.background.cornerRadius = 18
        button.configuration = configuration
    }

    private func choose(_ next: SketchTool) {
        guard tool != next else { return }
        selection.selectionChanged()
        selection.prepare()
        tool = next
        toolSlider.setSelected(next)
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

/// Glass tab. Only `roundedCorners` are curved; the edge that sits on the screen stays square.
private class GlassTab: UIView {
    var roundedCorners: UIRectCorner {
        didSet { setNeedsLayout() }
    }

    private let plate = LiquidGlassPlate()

    init(roundedCorners: UIRectCorner) {
        self.roundedCorners = roundedCorners
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        plate.roundedCorners = roundedCorners
        plate.cornerRadius = ChromeMetrics.cornerRadius
        addSubview(plate)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        plate.frame = bounds
        plate.roundedCorners = roundedCorners
        plate.cornerRadius = ChromeMetrics.cornerRadius
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point)
    }
}

/// Vertical tool control flush with the right edge. A vertical swipe steps the
/// tool. A tap selects the segment under the finger.
private final class ToolSliderView: GlassTab, UIGestureRecognizerDelegate {
    static var preferredHeight: CGFloat {
        let count = CGFloat(SketchTool.edgeOrder.count)
        guard count > 0 else { return 0 }
        return ChromeMetrics.sliderPadding * 2
            + ChromeMetrics.segmentLength * count
            + ChromeMetrics.sliderGap * max(0, count - 1)
    }

    private(set) var selectedTool = SketchTool.pen
    var onSelect: ((SketchTool) -> Void)?
    private var panMovedTool = false
    private var highlights: [SketchTool: UIView] = [:]
    private var buttons: [SketchTool: ToolSegmentControl] = [:]

    init() {
        super.init(roundedCorners: [.topLeft, .bottomLeft])
        isAccessibilityElement = false
        for tool in SketchTool.edgeOrder {
            let highlight = UIView()
            highlight.isUserInteractionEnabled = false
            highlight.layer.cornerRadius = ChromeMetrics.segmentCornerRadius
            highlight.backgroundColor = .clear
            addSubview(highlight)
            highlights[tool] = highlight

            let button = ToolSegmentControl(type: .system)
            button.isUserInteractionEnabled = false
            button.accessibilityLabel = tool.accessibilityName
            button.onActivate = { [weak self] in
                self?.onSelect?(tool)
            }
            let symbolConfiguration = chromeSymbolConfiguration(pointSize: 22)
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: tool.symbolName, withConfiguration: symbolConfiguration)
            configuration.preferredSymbolConfigurationForImage = symbolConfiguration
            configuration.baseForegroundColor = .white
            button.configuration = configuration
            buttons[tool] = button
            addSubview(button)
        }
        accessibilityElements = SketchTool.edgeOrder.compactMap { buttons[$0] }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.require(toFail: pan)
        addGestureRecognizer(pan)
        addGestureRecognizer(tap)
        setSelected(selectedTool)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let segmentWidth = bounds.width - ChromeMetrics.sliderPadding * 2
        var y = ChromeMetrics.sliderPadding
        for tool in SketchTool.edgeOrder {
            let frame = CGRect(x: ChromeMetrics.sliderPadding, y: y, width: segmentWidth, height: ChromeMetrics.segmentLength)
            highlights[tool]?.frame = frame
            buttons[tool]?.frame = frame
            y += ChromeMetrics.segmentLength + ChromeMetrics.sliderGap
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, bounds.contains(point) else { return nil }
        return self
    }

    func setSelected(_ tool: SketchTool) {
        selectedTool = tool
        for (candidate, highlight) in highlights {
            highlight.backgroundColor = candidate == tool ? ChromeMetrics.selectedFill : .clear
        }
        for (candidate, button) in buttons {
            button.accessibilityTraits = candidate == tool ? [.button, .selected] : .button
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    private func tool(at point: CGPoint) -> SketchTool? {
        let tools = SketchTool.edgeOrder
        guard bounds.contains(point), !tools.isEmpty else { return nil }
        let stride = ChromeMetrics.segmentLength + ChromeMetrics.sliderGap
        let local = point.y - ChromeMetrics.sliderPadding
        var best = tools[0]
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, tool) in tools.enumerated() {
            let mid = CGFloat(index) * stride + ChromeMetrics.segmentLength / 2
            let distance = abs(local - mid)
            if distance < bestDistance {
                bestDistance = distance
                best = tool
            }
        }
        return best
    }

    private func step(down: Bool) {
        let tools = SketchTool.edgeOrder
        guard !tools.isEmpty else { return }
        guard let index = tools.firstIndex(of: selectedTool) else {
            onSelect?(down ? tools[0] : tools[tools.count - 1])
            return
        }
        let nextIndex = down
            ? (index + 1) % tools.count
            : (index - 1 + tools.count) % tools.count
        onSelect?(tools[nextIndex])
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let tool = tool(at: gesture.location(in: self)) else { return }
        onSelect?(tool)
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            panMovedTool = false
        case .changed:
            guard let tool = tool(at: point), tool != selectedTool else { return }
            panMovedTool = true
            onSelect?(tool)
        case .ended, .cancelled:
            let translation = gesture.translation(in: self)
            if !panMovedTool, abs(translation.y) >= 36, abs(translation.y) > abs(translation.x) {
                step(down: translation.y > 0)
            }
        default:
            break
        }
    }
}

private final class ToolSegmentControl: UIButton {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }
}

/// Full-screen host that only accepts touches on its controls.
private final class PassthroughHost: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
