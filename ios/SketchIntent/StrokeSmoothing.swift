import CoreGraphics

/// A pen sample's center, tip size, opacity, and force. Time and tilt stay with the original point.
struct StrokeSample {
    var location: CGPoint
    var size: CGSize
    var opacity: CGFloat
    var force: CGFloat
}

/// One triangular average along a finished pen stroke.
enum StrokeCenterline {
    /// Arc-length blend radius, in points. 10pt left an 18pt kink in place; raise this to smooth slower wobble.
    static let windowRadius: CGFloat = 48

    static func smoothed(_ samples: [StrokeSample]) -> [StrokeSample] {
        let count = samples.count
        guard count >= 3 else { return samples }
        var distanceFromStart = [CGFloat](repeating: 0, count: count)
        for index in 1..<count {
            let previous = samples[index - 1].location
            let current = samples[index].location
            distanceFromStart[index] = distanceFromStart[index - 1] + hypot(current.x - previous.x, current.y - previous.y)
        }
        let radius = windowRadius
        return samples.indices.map { index in
            let sample = samples[index]
            if index == 0 || index == count - 1 { return sample }
            let center = distanceFromStart[index]
            var left = index
            while left > 0, center - distanceFromStart[left] <= radius {
                left -= 1
            }
            if center - distanceFromStart[left] > radius {
                left += 1
            }
            var right = index
            while right + 1 < count, distanceFromStart[right + 1] - center <= radius {
                right += 1
            }
            var weightSum: CGFloat = 0
            var x: CGFloat = 0
            var y: CGFloat = 0
            var width: CGFloat = 0
            var height: CGFloat = 0
            var opacity: CGFloat = 0
            var force: CGFloat = 0
            for other in left...right {
                let weight = 1 - abs(distanceFromStart[other] - center) / radius
                guard weight > 0 else { continue }
                let neighbor = samples[other]
                weightSum += weight
                x += neighbor.location.x * weight
                y += neighbor.location.y * weight
                width += neighbor.size.width * weight
                height += neighbor.size.height * weight
                opacity += neighbor.opacity * weight
                force += neighbor.force * weight
            }
            guard weightSum > 0 else { return sample }
            var averaged = sample
            averaged.location = CGPoint(x: x / weightSum, y: y / weightSum)
            averaged.size = CGSize(width: width / weightSum, height: height / weightSum)
            averaged.opacity = opacity / weightSum
            averaged.force = force / weightSum
            return averaged
        }
    }
}
