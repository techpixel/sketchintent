import CoreGraphics
import Foundation

/// A pen stroke corrected into a line, circle, square, rectangle, or clean curve.
enum FittedShape: Equatable {
    case line(CGPoint, CGPoint)
    case circle(center: CGPoint, radius: CGFloat, handleAngle: CGFloat)
    case square(center: CGPoint, side: CGFloat, rotation: CGFloat)
    case rectangle(center: CGPoint, width: CGFloat, height: CGFloat, rotation: CGFloat)
    case curve(controls: [CGPoint], closed: Bool)

    var handles: [CGPoint] {
        switch self {
        case let .line(start, end):
            return [start, end]
        case let .circle(center, radius, handleAngle):
            return [center, center + CGPoint(x: cos(handleAngle) * radius, y: sin(handleAngle) * radius)]
        case .square, .rectangle:
            return corners
        case let .curve(controls, _):
            return controls
        }
    }

    func moved(by delta: CGPoint) -> FittedShape {
        switch self {
        case let .line(start, end):
            return .line(start + delta, end + delta)
        case let .circle(center, radius, handleAngle):
            return .circle(center: center + delta, radius: radius, handleAngle: handleAngle)
        case let .square(center, side, rotation):
            return .square(center: center + delta, side: side, rotation: rotation)
        case let .rectangle(center, width, height, rotation):
            return .rectangle(center: center + delta, width: width, height: height, rotation: rotation)
        case let .curve(controls, closed):
            return .curve(controls: controls.map { $0 + delta }, closed: closed)
        }
    }

    func replacingHandle(_ index: Int, with point: CGPoint) -> FittedShape {
        switch self {
        case let .line(start, end):
            if index == 0 { return .line(point, end) }
            return .line(start, point)
        case let .circle(center, radius, handleAngle):
            if index == 0 {
                return .circle(center: point, radius: radius, handleAngle: handleAngle)
            }
            let radius = max(8, point.distance(to: center))
            let angle = atan2(point.y - center.y, point.x - center.x)
            return .circle(center: center, radius: radius, handleAngle: angle)
        case .square, .rectangle:
            return replacingCorner(index, with: point)
        case let .curve(controls, closed):
            guard controls.indices.contains(index) else { return self }
            var updated = controls
            updated[index] = point
            return .curve(controls: updated, closed: closed)
        }
    }

    /// The point a rigid move or rotate turns around.
    var center: CGPoint {
        switch self {
        case let .line(start, end):
            return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        case let .circle(center, _, _):
            return center
        case let .square(center, _, _):
            return center
        case let .rectangle(center, _, _, _):
            return center
        case let .curve(controls, _):
            guard !controls.isEmpty else { return .zero }
            var x: CGFloat = 0
            var y: CGFloat = 0
            for point in controls {
                x += point.x
                y += point.y
            }
            let count = CGFloat(controls.count)
            return CGPoint(x: x / count, y: y / count)
        }
    }

    /// Where the rotate stem meets the shape.
    var rotateAnchor: CGPoint {
        switch self {
        case .square, .rectangle:
            let box = corners
            guard box.count == 4 else { return center }
            return CGPoint(x: (box[0].x + box[1].x) / 2, y: (box[0].y + box[1].y) / 2)
        case let .circle(center, radius, _):
            let handle = rotateHandle
            let dx = handle.x - center.x
            let dy = handle.y - center.y
            let length = hypot(dx, dy)
            guard length > 0.001 else { return CGPoint(x: center.x, y: center.y - radius) }
            return CGPoint(x: center.x + dx / length * radius, y: center.y + dy / length * radius)
        case .line:
            return center
        case .curve:
            let bounds = controlBounds
            return CGPoint(x: bounds.midX, y: bounds.minY)
        }
    }

    /// Sits just outside the shape so a drag there turns it without grabbing a resize handle.
    var rotateHandle: CGPoint {
        let gap: CGFloat = 44
        switch self {
        case .square, .rectangle, .curve:
            return rotateAnchor.extended(from: center, by: gap)
        case let .line(start, end):
            let mid = center
            var px = -(end.y - start.y)
            var py = end.x - start.x
            let length = hypot(px, py)
            guard length > 0.001 else { return CGPoint(x: mid.x, y: mid.y - gap) }
            px /= length
            py /= length
            if py > 0 {
                px = -px
                py = -py
            }
            return CGPoint(x: mid.x + px * gap, y: mid.y + py * gap)
        case let .circle(center, radius, handleAngle):
            let rim = CGPoint(
                x: center.x + cos(handleAngle) * radius,
                y: center.y + sin(handleAngle) * radius
            )
            let candidates = [
                CGPoint(x: center.x, y: center.y - radius - gap),
                CGPoint(x: center.x - radius - gap, y: center.y),
                CGPoint(x: center.x + radius + gap, y: center.y),
                CGPoint(x: center.x, y: center.y + radius + gap)
            ]
            return candidates.max { lhs, rhs in
                hypot(lhs.x - rim.x, lhs.y - rim.y) < hypot(rhs.x - rim.x, rhs.y - rim.y)
            } ?? candidates[0]
        }
    }

    /// Rigid turn around `center`. Line endpoints keep the new angle. Squares and
    /// rectangles add to their stored rotation. Curve controls turn about the centroid.
    /// A circle only moves its resize handle; the outline stays round.
    func rotated(by angle: CGFloat) -> FittedShape {
        let origin = center
        switch self {
        case let .line(start, end):
            return .line(start.rotated(around: origin, by: angle), end.rotated(around: origin, by: angle))
        case let .circle(center, radius, handleAngle):
            return .circle(center: center, radius: radius, handleAngle: wrappedAngle(handleAngle + angle))
        case let .square(center, side, rotation):
            return .square(center: center, side: side, rotation: wrappedAngle(rotation + angle))
        case let .rectangle(center, width, height, rotation):
            return .rectangle(
                center: center,
                width: width,
                height: height,
                rotation: wrappedAngle(rotation + angle)
            )
        case let .curve(controls, closed):
            return .curve(controls: controls.map { $0.rotated(around: origin, by: angle) }, closed: closed)
        }
    }

    /// Applies a move, turn, uniform scale, or a one-axis stretch.
    /// A square becomes a rectangle when the two axes scale differently.
    func applying(_ transform: CGAffineTransform) -> FittedShape {
        switch self {
        case let .line(start, end):
            return .line(start.applying(transform), end.applying(transform))
        case let .circle(center, radius, handleAngle):
            let scaled = axisScale(of: center, rotation: 0, by: transform)
            let turn = atan2(transform.b, transform.a)
            if abs(scaled.x - scaled.y) < 0.02 {
                return .circle(
                    center: scaled.center,
                    radius: max(0.001, radius * scaled.x),
                    handleAngle: wrappedAngle(handleAngle + turn)
                )
            }
            return .rectangle(
                center: scaled.center,
                width: max(0.001, radius * 2 * scaled.x),
                height: max(0.001, radius * 2 * scaled.y),
                rotation: scaled.rotation
            )
        case let .square(center, side, squareRotation):
            let scaled = axisScale(of: center, rotation: squareRotation, by: transform)
            if abs(scaled.x - scaled.y) < 0.02 {
                return .square(
                    center: scaled.center,
                    side: max(0.001, side * scaled.x),
                    rotation: wrappedAngle(scaled.rotation)
                )
            }
            return .rectangle(
                center: scaled.center,
                width: max(0.001, side * scaled.x),
                height: max(0.001, side * scaled.y),
                rotation: wrappedAngle(scaled.rotation)
            )
        case let .rectangle(center, width, height, rectRotation):
            let scaled = axisScale(of: center, rotation: rectRotation, by: transform)
            return .rectangle(
                center: scaled.center,
                width: max(0.001, width * scaled.x),
                height: max(0.001, height * scaled.y),
                rotation: wrappedAngle(scaled.rotation)
            )
        case let .curve(controls, closed):
            return .curve(controls: controls.map { $0.applying(transform) }, closed: closed)
        }
    }

    /// How `transform` scales the local axes through `center`.
    private func axisScale(
        of center: CGPoint,
        rotation: CGFloat,
        by transform: CGAffineTransform
    ) -> (x: CGFloat, y: CGFloat, center: CGPoint, rotation: CGFloat) {
        let xAxis = ShapeFit.rotate(CGPoint(x: 1, y: 0), by: rotation)
        let yAxis = ShapeFit.rotate(CGPoint(x: 0, y: 1), by: rotation)
        let moved = center.applying(transform)
        let mappedX = CGPoint(x: center.x + xAxis.x, y: center.y + xAxis.y).applying(transform)
        let mappedY = CGPoint(x: center.x + yAxis.x, y: center.y + yAxis.y).applying(transform)
        let newX = CGPoint(x: mappedX.x - moved.x, y: mappedX.y - moved.y)
        let newY = CGPoint(x: mappedY.x - moved.x, y: mappedY.y - moved.y)
        return (
            max(hypot(newX.x, newX.y), 0.001),
            max(hypot(newY.x, newY.y), 0.001),
            moved,
            atan2(newX.y, newX.x)
        )
    }

    /// Interior of a closed shape. A line and an open curve have no interior.
    func contains(_ point: CGPoint) -> Bool {
        switch self {
        case .line:
            return false
        case let .circle(center, radius, _):
            return hypot(point.x - center.x, point.y - center.y) <= radius
        case let .square(center, side, rotation):
            let local = ShapeFit.rotate(CGPoint(x: point.x - center.x, y: point.y - center.y), by: -rotation)
            let half = side / 2
            return abs(local.x) <= half && abs(local.y) <= half
        case let .rectangle(center, width, height, rotation):
            let local = ShapeFit.rotate(CGPoint(x: point.x - center.x, y: point.y - center.y), by: -rotation)
            return abs(local.x) <= width / 2 && abs(local.y) <= height / 2
        case let .curve(controls, closed):
            guard closed, controls.count >= 3 else { return false }
            return pointIsInside(point, polygon: ShapeFit.smoothCurve(controls, closed: true))
        }
    }

    private var controlBounds: CGRect {
        guard case let .curve(controls, _) = self, let first = controls.first else {
            return CGRect(origin: center, size: .zero)
        }
        var rect = CGRect(origin: first, size: .zero)
        for point in controls.dropFirst() {
            rect = rect.union(CGRect(origin: point, size: .zero))
        }
        return rect
    }

    /// Points that trace the corrected stroke, including a repeated start when the shape closes.
    func outline() -> [CGPoint] {
        switch self {
        case let .line(start, end):
            return [start, end]
        case let .circle(center, radius, _):
            let count = 64
            var points: [CGPoint] = []
            points.reserveCapacity(count + 1)
            for index in 0..<count {
                let angle = CGFloat(index) / CGFloat(count) * 2 * .pi
                points.append(center + CGPoint(x: cos(angle) * radius, y: sin(angle) * radius))
            }
            points.append(points[0])
            return points
        case .square, .rectangle:
            let box = corners
            guard box.count == 4 else { return box }
            var points: [CGPoint] = []
            let perSide = 12
            for side in 0..<4 {
                let start = box[side]
                let end = box[(side + 1) % 4]
                for step in 0..<perSide {
                    let t = CGFloat(step) / CGFloat(perSide)
                    points.append(CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
                }
            }
            if let first = points.first { points.append(first) }
            return points
        case let .curve(controls, closed):
            return ShapeFit.smoothCurve(controls, closed: closed)
        }
    }

    func distance(to point: CGPoint) -> CGFloat {
        let path = outline()
        guard let first = path.first else { return .greatestFiniteMagnitude }
        if path.count == 1 { return point.distance(to: first) }
        var best = CGFloat.greatestFiniteMagnitude
        for index in 1..<path.count {
            best = min(best, point.distance(toSegmentFrom: path[index - 1], to: path[index]))
        }
        return best
    }

    private var corners: [CGPoint] {
        let center: CGPoint
        let width: CGFloat
        let height: CGFloat
        let rotation: CGFloat
        switch self {
        case let .square(squareCenter, side, squareRotation):
            center = squareCenter
            width = side
            height = side
            rotation = squareRotation
        case let .rectangle(rectCenter, rectWidth, rectHeight, rectRotation):
            center = rectCenter
            width = rectWidth
            height = rectHeight
            rotation = rectRotation
        default:
            return []
        }
        let halfWidth = width / 2
        let halfHeight = height / 2
        let locals = [
            CGPoint(x: -halfWidth, y: -halfHeight),
            CGPoint(x: halfWidth, y: -halfHeight),
            CGPoint(x: halfWidth, y: halfHeight),
            CGPoint(x: -halfWidth, y: halfHeight)
        ]
        return locals.map { center + ShapeFit.rotate($0, by: rotation) }
    }

    private func replacingCorner(_ index: Int, with point: CGPoint) -> FittedShape {
        let box = corners
        guard box.count == 4, box.indices.contains(index) else { return self }
        let opposite = box[(index + 2) % 4]
        let rotation: CGFloat
        let keepSquare: Bool
        switch self {
        case let .square(_, _, squareRotation):
            rotation = squareRotation
            keepSquare = true
        case let .rectangle(_, _, _, rectRotation):
            rotation = rectRotation
            keepSquare = false
        default:
            return self
        }
        let local = ShapeFit.rotate(point - opposite, by: -rotation)
        let original = ShapeFit.rotate(box[index] - opposite, by: -rotation)
        let signX: CGFloat = original.x >= 0 ? 1 : -1
        let signY: CGFloat = original.y >= 0 ? 1 : -1
        let spanX = max(8, abs(local.x))
        let spanY = max(8, abs(local.y))
        let size = keepSquare ? max(spanX, spanY) : 0
        let newLocal = CGPoint(
            x: signX * (keepSquare ? size : spanX),
            y: signY * (keepSquare ? size : spanY)
        )
        let newCorner = opposite + ShapeFit.rotate(newLocal, by: rotation)
        let center = CGPoint(x: (opposite.x + newCorner.x) / 2, y: (opposite.y + newCorner.y) / 2)
        if keepSquare {
            return .square(center: center, side: size, rotation: rotation)
        }
        return .rectangle(center: center, width: spanX, height: spanY, rotation: rotation)
    }
}

enum ShapeFit {
    /// Nil when the stroke is too short to correct. Otherwise a line, circle, square,
    /// rectangle, or a curve reduced to a handful of handles.
    static func fit(_ points: [CGPoint]) -> FittedShape? {
        let cleaned = deduped(points)
        guard cleaned.count >= 2 else { return nil }
        let length = pathLength(cleaned)
        guard length >= 18 else { return nil }
        let gap = cleaned[0].distance(to: cleaned[cleaned.count - 1])
        let closed = gap < max(28, length * 0.16) && length > gap * 2.2

        if !closed, let line = lineFit(cleaned), line.maxDeviation <= max(10, line.length * 0.08), line.length >= 18 {
            return .line(line.start, line.end)
        }
        if closed {
            let samples = resample(cleaned, count: 72)
            if let box = boxFit(samples) {
                return box
            }
            if let circle = circleFit(samples), circle.radius >= 10, circle.error <= circle.radius * 0.16 {
                let angle = atan2(cleaned[0].y - circle.center.y, cleaned[0].x - circle.center.x)
                return .circle(center: circle.center, radius: circle.radius, handleAngle: angle)
            }
        }
        return cleanCurve(cleaned, closed: closed)
    }

    static func smoothCurve(_ controls: [CGPoint], closed: Bool) -> [CGPoint] {
        guard controls.count >= 2 else { return controls }
        if controls.count == 2 { return controls }
        var result: [CGPoint] = []
        let count = controls.count
        let spans = closed ? count : count - 1
        let steps = 8
        for span in 0..<spans {
            let p1 = controls[span % count]
            let p2 = controls[(span + 1) % count]
            let p0 = closed || span > 0 ? controls[(span - 1 + count) % count] : p1
            let p3 = closed || span + 2 < count ? controls[(span + 2) % count] : p2
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                result.append(catmullRom(t, p0, p1, p2, p3))
            }
        }
        result.append(closed ? controls[0] : controls[count - 1])
        return result
    }

    static func rotate(_ point: CGPoint, by angle: CGFloat) -> CGPoint {
        let cosAngle = cos(angle)
        let sinAngle = sin(angle)
        return CGPoint(x: point.x * cosAngle - point.y * sinAngle, y: point.x * sinAngle + point.y * cosAngle)
    }

    private static func cleanCurve(_ points: [CGPoint], closed: Bool) -> FittedShape {
        let bounds = boundingBox(points)
        let diagonal = max(hypot(bounds.width, bounds.height), 1)
        var epsilon = max(16, diagonal * 0.07)
        var simplified = rdp(points, epsilon: epsilon)
        while simplified.count > 6, epsilon < diagonal * 0.45 {
            epsilon *= 1.35
            simplified = rdp(points, epsilon: epsilon)
        }
        if closed, simplified.count > 2 {
            simplified.removeLast()
        }
        if simplified.count < 2, let first = points.first, let last = points.last {
            return .line(first, last)
        }
        if simplified.count == 2, !closed {
            return .line(simplified[0], simplified[1])
        }
        return .curve(controls: simplified, closed: closed)
    }

    private static func lineFit(_ points: [CGPoint]) -> (start: CGPoint, end: CGPoint, length: CGFloat, maxDeviation: CGFloat)? {
        let mean = centroid(points)
        var sxx: CGFloat = 0
        var syy: CGFloat = 0
        var sxy: CGFloat = 0
        for point in points {
            let dx = point.x - mean.x
            let dy = point.y - mean.y
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        var minProjection = CGFloat.greatestFiniteMagnitude
        var maxProjection = -CGFloat.greatestFiniteMagnitude
        var maxDeviation: CGFloat = 0
        for point in points {
            let delta = point - mean
            let projection = delta.x * direction.x + delta.y * direction.y
            let perpendicular = abs(delta.x * direction.y - delta.y * direction.x)
            minProjection = min(minProjection, projection)
            maxProjection = max(maxProjection, projection)
            maxDeviation = max(maxDeviation, perpendicular)
        }
        let start = mean + CGPoint(x: direction.x * minProjection, y: direction.y * minProjection)
        let end = mean + CGPoint(x: direction.x * maxProjection, y: direction.y * maxProjection)
        return (start, end, start.distance(to: end), maxDeviation)
    }

    private static func circleFit(_ points: [CGPoint]) -> (center: CGPoint, radius: CGFloat, error: CGFloat)? {
        var a00 = 0.0, a01 = 0.0, a02 = 0.0
        var a11 = 0.0, a12 = 0.0, a22 = 0.0
        var b0 = 0.0, b1 = 0.0, b2 = 0.0
        for point in points {
            let x = Double(point.x)
            let y = Double(point.y)
            let target = -(x * x + y * y)
            a00 += x * x
            a01 += x * y
            a02 += x
            a11 += y * y
            a12 += y
            a22 += 1
            b0 += x * target
            b1 += y * target
            b2 += target
        }
        guard let solution = solve3(
            a00, a01, a02,
            a01, a11, a12,
            a02, a12, a22,
            b0, b1, b2
        ) else { return nil }
        let centerX = -solution.0 / 2
        let centerY = -solution.1 / 2
        let radiusSquared = centerX * centerX + centerY * centerY - solution.2
        guard radiusSquared > 1 else { return nil }
        let radius = CGFloat(radiusSquared.squareRoot())
        let center = CGPoint(x: centerX, y: centerY)
        var error: CGFloat = 0
        for point in points {
            error += abs(point.distance(to: center) - radius)
        }
        return (center, radius, error / CGFloat(points.count))
    }

    private static func boxFit(_ points: [CGPoint]) -> FittedShape? {
        let found = corners(points)
        guard found.count == 4 else { return nil }
        let side = found[1] - found[0]
        var rotation = atan2(side.y, side.x)
        let rightAngle = CGFloat.pi / 2
        let snapped = (rotation / rightAngle).rounded() * rightAngle
        if abs(rotation - snapped) < 0.12 { rotation = snapped }
        let center = centroid(found)
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for point in points {
            let local = rotate(point - center, by: -rotation)
            minX = min(minX, local.x)
            maxX = max(maxX, local.x)
            minY = min(minY, local.y)
            maxY = max(maxY, local.y)
        }
        let width = maxX - minX
        let height = maxY - minY
        guard width >= 16, height >= 16 else { return nil }
        let boxCenter = center + rotate(CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2), by: rotation)
        let shape: FittedShape
        if abs(width - height) / max(width, height) < 0.2 {
            shape = .square(center: boxCenter, side: (width + height) / 2, rotation: rotation)
        } else {
            shape = .rectangle(center: boxCenter, width: width, height: height, rotation: rotation)
        }
        let outline = shape.outline()
        var error: CGFloat = 0
        for point in points {
            error += point.distance(toPolyline: outline)
        }
        error /= CGFloat(points.count)
        guard error <= 0.16 * min(width, height) else { return nil }
        return shape
    }

    private static func corners(_ points: [CGPoint]) -> [CGPoint] {
        let samples = resample(points, count: 80)
        guard samples.count >= 12 else { return [] }
        let window = 3
        var turns: [(index: Int, amount: CGFloat)] = []
        for index in 0..<samples.count {
            let previous = samples[(index - window + samples.count) % samples.count]
            let current = samples[index]
            let next = samples[(index + window) % samples.count]
            let incoming = atan2(current.y - previous.y, current.x - previous.x)
            let outgoing = atan2(next.y - current.y, next.x - current.x)
            var turn = outgoing - incoming
            while turn > .pi { turn -= 2 * .pi }
            while turn < -.pi { turn += 2 * .pi }
            turns.append((index, abs(turn)))
        }
        var peaks: [Int] = []
        for index in 0..<turns.count {
            let amount = turns[index].amount
            guard amount > 0.55 else { continue }
            let before = turns[(index - 1 + turns.count) % turns.count].amount
            let after = turns[(index + 1) % turns.count].amount
            if amount >= before, amount >= after {
                peaks.append(turns[index].index)
            }
        }
        var kept: [Int] = []
        for peak in peaks {
            if let near = kept.firstIndex(where: { circularDistance($0, peak, modulo: samples.count) < 8 }) {
                if turns[peak].amount > turns[kept[near]].amount {
                    kept[near] = peak
                }
            } else {
                kept.append(peak)
            }
        }
        return kept.sorted().map { samples[$0] }
    }

    private static func circularDistance(_ left: Int, _ right: Int, modulo: Int) -> Int {
        let delta = abs(left - right)
        return min(delta, modulo - delta)
    }

    private static func rdp(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var maxDistance: CGFloat = 0
        var split = 0
        let start = points[0]
        let end = points[points.count - 1]
        for index in 1..<(points.count - 1) {
            let distance = points[index].distance(toSegmentFrom: start, to: end)
            if distance > maxDistance {
                maxDistance = distance
                split = index
            }
        }
        if maxDistance > epsilon {
            let left = rdp(Array(points[0...split]), epsilon: epsilon)
            let right = rdp(Array(points[split...]), epsilon: epsilon)
            return left.dropLast() + right
        }
        return [start, end]
    }

    private static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard count > 1, points.count > 1 else { return points }
        let length = pathLength(points)
        guard length > 0 else { return points }
        var result: [CGPoint] = [points[0]]
        var cursor = 1
        var walked: CGFloat = 0
        for step in 1..<count {
            let target = length * CGFloat(step) / CGFloat(count - 1)
            while cursor < points.count, walked + points[cursor - 1].distance(to: points[cursor]) < target {
                walked += points[cursor - 1].distance(to: points[cursor])
                cursor += 1
            }
            guard cursor < points.count else {
                result.append(points[points.count - 1])
                continue
            }
            let segment = points[cursor - 1].distance(to: points[cursor])
            let t = segment > 0 ? (target - walked) / segment : 0
            let start = points[cursor - 1]
            let end = points[cursor]
            result.append(CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
        return result
    }

    private static func deduped(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points {
            if let last = result.last, last.distance(to: point) < 0.5 { continue }
            result.append(point)
        }
        return result
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        var length: CGFloat = 0
        for index in 1..<points.count {
            length += points[index - 1].distance(to: points[index])
        }
        return length
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        var x: CGFloat = 0
        var y: CGFloat = 0
        for point in points {
            x += point.x
            y += point.y
        }
        return CGPoint(x: x / CGFloat(points.count), y: y / CGFloat(points.count))
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func catmullRom(_ t: CGFloat, _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t
        let x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
        let y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
        return CGPoint(x: x, y: y)
    }

    private static func solve3(
        _ a00: Double, _ a01: Double, _ a02: Double,
        _ a10: Double, _ a11: Double, _ a12: Double,
        _ a20: Double, _ a21: Double, _ a22: Double,
        _ b0: Double, _ b1: Double, _ b2: Double
    ) -> (Double, Double, Double)? {
        let det = a00 * (a11 * a22 - a12 * a21) - a01 * (a10 * a22 - a12 * a20) + a02 * (a10 * a21 - a11 * a20)
        guard abs(det) > 1e-6 else { return nil }
        let dx = b0 * (a11 * a22 - a12 * a21) - a01 * (b1 * a22 - a12 * b2) + a02 * (b1 * a21 - a11 * b2)
        let dy = a00 * (b1 * a22 - a12 * b2) - b0 * (a10 * a22 - a12 * a20) + a02 * (a10 * b2 - b1 * a20)
        let dz = a00 * (a11 * b2 - b1 * a21) - a01 * (a10 * b2 - b1 * a20) + b0 * (a10 * a21 - a11 * a20)
        return (dx / det, dy / det, dz / det)
    }
}

private func wrappedAngle(_ angle: CGFloat) -> CGFloat {
    var value = angle
    let turn = 2 * CGFloat.pi
    while value > .pi { value -= turn }
    while value < -.pi { value += turn }
    return value
}

private func pointIsInside(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
    guard polygon.count >= 3 else { return false }
    var inside = false
    var previous = polygon[polygon.count - 1]
    for current in polygon {
        let crosses = (current.y > point.y) != (previous.y > point.y)
        if crosses, previous.y != current.y {
            let x = (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x
            if point.x < x { inside.toggle() }
        }
        previous = current
    }
    return inside
}

private extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }

    func rotated(around center: CGPoint, by angle: CGFloat) -> CGPoint {
        let turned = ShapeFit.rotate(self - center, by: angle)
        return center + turned
    }

    func extended(from origin: CGPoint, by distance: CGFloat) -> CGPoint {
        let dx = x - origin.x
        let dy = y - origin.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return CGPoint(x: x, y: y - distance) }
        return CGPoint(x: x + dx / length * distance, y: y + dy / length * distance)
    }

    func distance(toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared <= 0.0001 { return distance(to: start) }
        let t = min(1, max(0, ((x - start.x) * dx + (y - start.y) * dy) / lengthSquared))
        return distance(to: CGPoint(x: start.x + t * dx, y: start.y + t * dy))
    }

    func distance(toPolyline points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .greatestFiniteMagnitude }
        if points.count == 1 { return distance(to: first) }
        var best = CGFloat.greatestFiniteMagnitude
        for index in 1..<points.count {
            best = min(best, distance(toSegmentFrom: points[index - 1], to: points[index]))
        }
        return best
    }
}
