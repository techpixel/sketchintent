import UIKit

/// Liquid glass for the plates in Figma frame 20:295: the trackpad, the send tab,
/// and the tool slider. Each is filled rgba(0, 0, 0, 0.5) with a 16pt corner
/// radius. The frame authors no backdrop blur and no stroke on these plates.
/// iOS 26 and later draw the fill as `UIGlassEffect`. Earlier systems paint the
/// same fill, with the same corners.
final class LiquidGlassPlate: UIView {
    static let fill = UIColor(white: 0, alpha: 0.5)

    var cornerRadius: CGFloat = 16 {
        didSet { applyShape() }
    }

    var roundedCorners: UIRectCorner = .allCorners {
        didSet { applyShape() }
    }

    private let effectView: UIVisualEffectView?
    private let fallback = UIView()

    override init(frame: CGRect) {
        if #available(iOS 26.0, *) {
            effectView = Self.makeGlassView()
        } else {
            effectView = nil
        }
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        if let effectView {
            addSubview(effectView)
        } else {
            fallback.isUserInteractionEnabled = false
            fallback.isOpaque = false
            fallback.backgroundColor = Self.fill
            addSubview(fallback)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let content = effectView ?? fallback
        content.frame = bounds
        applyShape()
    }

    @available(iOS 26.0, *)
    private static func makeGlassView() -> UIVisualEffectView {
        let glass = UIGlassEffect(style: .regular)
        glass.tintColor = fill
        let view = UIVisualEffectView(effect: glass)
        view.isUserInteractionEnabled = false
        return view
    }

    private func applyShape() {
        let content = effectView ?? fallback
        content.clipsToBounds = true
        content.layer.cornerRadius = cornerRadius
        content.layer.maskedCorners = cornerMask
    }

    private var cornerMask: CACornerMask {
        var mask: CACornerMask = []
        if roundedCorners.contains(.topLeft) { mask.insert(.layerMinXMinYCorner) }
        if roundedCorners.contains(.topRight) { mask.insert(.layerMaxXMinYCorner) }
        if roundedCorners.contains(.bottomLeft) { mask.insert(.layerMinXMaxYCorner) }
        if roundedCorners.contains(.bottomRight) { mask.insert(.layerMaxXMaxYCorner) }
        return mask
    }
}
