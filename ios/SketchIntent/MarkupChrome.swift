import SwiftUI
import UIKit

/// Floating markup controls. The tool dial stays hidden until `showsDial`.
/// Empty space falls through to the canvas while the dial is hidden.
struct MarkupChrome: UIViewControllerRepresentable {
    var showsTools: Bool
    var showsDial: Bool
    var showsGear: Bool
    var tool: SketchTool
    var canSend: Bool
    var onTool: (SketchTool) -> Void
    var onSend: () -> Void
    var onSettings: () -> Void
    var onDismissDial: () -> Void

    func makeUIViewController(context: Context) -> MarkupChromeController {
        let controller = MarkupChromeController()
        controller.onTool = onTool
        controller.onSend = onSend
        controller.onSettings = onSettings
        controller.onDismissDial = onDismissDial
        return controller
    }

    func updateUIViewController(_ controller: MarkupChromeController, context: Context) {
        controller.onTool = onTool
        controller.onSend = onSend
        controller.onSettings = onSettings
        controller.onDismissDial = onDismissDial
        controller.showsTools = showsTools
        controller.showsDial = showsDial
        controller.showsGear = showsGear
        controller.tool = tool
        controller.canSend = canSend
        controller.reload()
    }
}

final class MarkupChromeController: UIViewController {
    var showsTools = false
    var showsDial = false
    var showsGear = false
    var tool = SketchTool.pen
    var canSend = false
    var onTool: (SketchTool) -> Void = { _ in }
    var onSend: () -> Void = {}
    var onSettings: () -> Void = {}
    var onDismissDial: () -> Void = {}
    private var dialIsShown = false

    private let toolDial = ToolDialView()
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
        toolDial.onSelect = { [weak self] tool in
            self?.choose(tool)
        }
        toolDial.onCommit = { [weak self] in
            self?.onDismissDial()
        }
        toolDial.isHidden = true
        toolDial.alpha = 0
        toolDial.isUserInteractionEnabled = false
        view.addSubview(toolDial)

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

        selection.prepare()
        toolDial.setSelected(tool, animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        let bounds = view.bounds

        let side = ToolDialView.diameter
        toolDial.frame = CGRect(
            x: (bounds.width - side) / 2,
            y: safe.top + 56,
            width: side,
            height: side
        )

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
        sendPlate.isHidden = !showsTools
        gearPlate.isHidden = !showsGear
        sendButton.isEnabled = canSend
        sendPlate.alpha = canSend ? 1 : 0.4
        toolDial.setSelected(tool, animated: toolDial.selectedTool != tool)
        guard dialIsShown != showsDial else { return }
        toolDial.cancelPendingCommit()
        dialIsShown = showsDial
        updateDialVisibility(animated: view.window != nil)
    }

    /// The send button and settings gear stay up with the stream. Only the dial toggles.
    private func updateDialVisibility(animated: Bool) {
        if showsDial {
            toolDial.isHidden = false
            toolDial.isUserInteractionEnabled = true
            guard animated else {
                toolDial.alpha = 1
                toolDial.transform = .identity
                return
            }
            toolDial.alpha = 0
            toolDial.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            UIView.animate(
                withDuration: 0.32,
                delay: 0,
                usingSpringWithDamping: 0.86,
                initialSpringVelocity: 0.2,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                self.toolDial.alpha = 1
                self.toolDial.transform = .identity
            }
        } else {
            toolDial.isUserInteractionEnabled = false
            guard animated, !toolDial.isHidden else {
                toolDial.isHidden = true
                toolDial.alpha = 0
                toolDial.transform = .identity
                return
            }
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseIn]
            ) {
                self.toolDial.alpha = 0
            } completion: { _ in
                guard !self.showsDial else { return }
                self.toolDial.isHidden = true
                self.toolDial.alpha = 0
                self.toolDial.transform = .identity
            }
        }
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

    private func choose(_ next: SketchTool) {
        guard tool != next else { return }
        selection.selectionChanged()
        selection.prepare()
        tool = next
        toolDial.setSelected(next, animated: true)
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

/// Glass ring for pen, pointer, and eraser. Symbols stay upright. The center
/// hole and the square corners pass touches through to the canvas.
private final class ToolDialView: UIView, UIGestureRecognizerDelegate {
    static let diameter: CGFloat = 176

    private(set) var selectedTool = SketchTool.pen
    var onSelect: ((SketchTool) -> Void)?
    var onCommit: (() -> Void)?
    /// Bumped when the selection changes or a commit is cancelled, so a drag
    /// that is still settling does not dismiss the dial afterward.
    private var commitToken = 0
    private var selectionSettlesAt = Date.distantPast
    private var dragChangedTool = false
    private static let wedgeSpringDuration: TimeInterval = 0.32

    private let ring = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let hairline = RingHairline()
    private let wedge = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let wedgeTint = UIView()
    private let ringMask = CAShapeLayer()
    private let wedgeMask = CAShapeLayer()
    private var buttons: [SketchTool: UIButton] = [:]

    private static let innerRadius: CGFloat = 42
    private static let symbolRadius: CGFloat = 65
    private static let bandWidth: CGFloat = 46
    /// Half the stroked arc, before the round caps widen it.
    private static let wedgeHalfAngle: CGFloat = 0.52

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = false

        ring.isUserInteractionEnabled = false
        ring.layer.cornerCurve = .continuous
        ring.layer.mask = ringMask
        ringMask.fillRule = .evenOdd
        addSubview(ring)
        addSubview(hairline)

        wedge.isUserInteractionEnabled = false
        wedge.layer.cornerCurve = .continuous
        wedge.layer.mask = wedgeMask
        wedgeMask.fillColor = nil
        wedgeMask.strokeColor = UIColor.white.cgColor
        wedgeMask.lineWidth = Self.bandWidth
        wedgeMask.lineCap = .round
        wedgeTint.isUserInteractionEnabled = false
        wedgeTint.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.42)
        wedge.contentView.addSubview(wedgeTint)
        addSubview(wedge)

        for tool in [SketchTool.eraser, .pen, .pointer] {
            let button = UIButton(type: .system)
            button.automaticallyUpdatesConfiguration = false
            button.accessibilityLabel = tool.accessibilityName
            if tool == .pointer {
                button.accessibilityHint = "Clicks and drags on the Mac"
            }
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: tool.symbolName)
            configuration.background.backgroundColor = .clear
            button.configuration = configuration
            button.tag = tool.rawTag
            button.addTarget(self, action: #selector(toolTapped(_:)), for: .touchUpInside)
            buttons[tool] = button
            addSubview(button)
        }
        accessibilityElements = [SketchTool.eraser, .pen, .pointer].compactMap { buttons[$0] }

        let tap = UITapGestureRecognizer(target: self, action: #selector(ringTapped(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        refreshButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds
        hairline.frame = bounds
        wedge.bounds = bounds
        wedge.center = CGPoint(x: bounds.midX, y: bounds.midY)
        wedgeTint.frame = wedge.contentView.bounds
        updatePaths()
        layoutButtons()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, bounds.contains(point) else { return nil }
        let distance = hypot(point.x - bounds.midX, point.y - bounds.midY)
        guard distance <= bounds.width / 2 else { return nil }
        for button in buttons.values where !button.isHidden {
            let local = convert(point, to: button)
            if button.point(inside: local, with: event) {
                return button
            }
        }
        guard distance >= Self.innerRadius else { return nil }
        return self
    }

    func cancelPendingCommit() {
        commitToken += 1
    }

    func setSelected(_ tool: SketchTool, animated: Bool) {
        let changed = selectedTool != tool
        if changed {
            commitToken += 1
        }
        selectedTool = tool
        refreshButtons()
        guard changed else { return }
        let angle = tool.dialAngle
        let apply = { self.wedge.transform = CGAffineTransform(rotationAngle: angle) }
        if animated, window != nil {
            selectionSettlesAt = Date().addingTimeInterval(Self.wedgeSpringDuration)
            UIView.animate(
                withDuration: Self.wedgeSpringDuration,
                delay: 0,
                usingSpringWithDamping: 0.86,
                initialSpringVelocity: 0.2,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: apply
            )
        } else {
            selectionSettlesAt = .distantPast
            apply()
        }
    }

    private func updatePaths() {
        guard bounds.width > 0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let outer = bounds.width / 2 - 0.5
        let donut = UIBezierPath(arcCenter: center, radius: outer, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
        donut.append(UIBezierPath(arcCenter: center, radius: Self.innerRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: true))
        ringMask.frame = ring.bounds
        ringMask.path = donut.cgPath

        let outline = UIBezierPath(arcCenter: center, radius: outer, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
        outline.append(UIBezierPath(arcCenter: center, radius: Self.innerRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: true))
        hairline.shapeLayer.path = outline.cgPath

        let arc = UIBezierPath(
            arcCenter: center,
            radius: Self.symbolRadius,
            startAngle: -Self.wedgeHalfAngle,
            endAngle: Self.wedgeHalfAngle,
            clockwise: true
        )
        wedgeMask.frame = wedge.bounds
        wedgeMask.path = arc.cgPath
    }

    private func layoutButtons() {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for (tool, button) in buttons {
            let angle = tool.dialAngle
            let origin = CGPoint(
                x: center.x + cos(angle) * Self.symbolRadius - 22,
                y: center.y + sin(angle) * Self.symbolRadius - 22
            )
            button.frame = CGRect(origin: origin, size: CGSize(width: 44, height: 44))
        }
    }

    private func refreshButtons() {
        for (tool, button) in buttons {
            let selected = tool == selectedTool
            var configuration = button.configuration ?? .plain()
            let pointSize: CGFloat = tool == .eraser ? 20 : 22
            configuration.image = UIImage(systemName: tool.symbolName)
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                pointSize: pointSize,
                weight: selected ? .semibold : .medium
            )
            configuration.baseForegroundColor = selected ? .white : UIColor.white.withAlphaComponent(0.78)
            configuration.background.backgroundColor = .clear
            button.configuration = configuration
            button.isSelected = selected
            button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
    }

    private func nearestTool(to point: CGPoint) -> SketchTool {
        let angle = atan2(point.y - bounds.midY, point.x - bounds.midX)
        return SketchTool.allCases.min { lhs, rhs in
            abs(Self.wrapped(angle - lhs.dialAngle)) < abs(Self.wrapped(angle - rhs.dialAngle))
        } ?? .pen
    }

    private static func wrapped(_ delta: CGFloat) -> CGFloat {
        var value = delta
        while value > .pi { value -= 2 * .pi }
        while value < -.pi { value += 2 * .pi }
        return value
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let point = touch.location(in: self)
        for button in buttons.values {
            let local = convert(point, to: button)
            if button.point(inside: local, with: nil) {
                return false
            }
        }
        return true
    }

    @objc private func toolTapped(_ sender: UIButton) {
        guard let tool = SketchTool(rawTag: sender.tag) else { return }
        onSelect?(tool)
        commitNow()
    }

    @objc private func ringTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onSelect?(nearestTool(to: gesture.location(in: self)))
        commitNow()
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            cancelPendingCommit()
            dragChangedTool = false
            selectFromDrag(gesture)
        case .changed:
            selectFromDrag(gesture)
        case .ended:
            selectFromDrag(gesture)
            let remaining = selectionSettlesAt.timeIntervalSinceNow
            if dragChangedTool, remaining > 0.02 {
                commitAfter(remaining)
            } else {
                commitNow()
            }
        default:
            break
        }
    }

    private func selectFromDrag(_ gesture: UIPanGestureRecognizer) {
        let tool = nearestTool(to: gesture.location(in: self))
        if tool != selectedTool {
            dragChangedTool = true
        }
        onSelect?(tool)
    }

    private func commitNow() {
        commitToken += 1
        onCommit?()
    }

    /// Waits out the wedge spring, then dismisses. A newer selection cancels it.
    private func commitAfter(_ delay: TimeInterval) {
        commitToken += 1
        let token = commitToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.commitToken == token else { return }
            self.onCommit?()
        }
    }
}

private final class RingHairline: UIView {
    override class var layerClass: AnyClass { CAShapeLayer.self }
    var shapeLayer: CAShapeLayer { layer as! CAShapeLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        shapeLayer.fillColor = nil
        shapeLayer.strokeColor = UIColor.white.withAlphaComponent(0.28).cgColor
        shapeLayer.lineWidth = 1
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Full-screen host that only accepts touches on its controls.
private final class PassthroughHost: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
