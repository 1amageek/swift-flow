import SwiftUI

public struct BezierEdgePath: EdgePathCalculating, Sendable {

    /// Maximum distance from a waypoint curve to its corresponding chord, in canvas units.
    public static let maximumWaypointDeviation: CGFloat = 6

    /// Maximum distance along either chord over which a waypoint turn is curved.
    public static let maximumWaypointSpan = maximumWaypointDeviation * 27 / 4

    public init() {}

    public func path(
        from source: CGPoint,
        sourcePosition: HandlePosition,
        to target: CGPoint,
        targetPosition: HandlePosition
    ) -> EdgePath {
        let distance = hypot(target.x - source.x, target.y - source.y)
        let curvature = max(50, distance * 0.4)

        let sourceOffset = controlOffset(for: sourcePosition, distance: curvature)
        let targetOffset = controlOffset(for: targetPosition, distance: curvature)

        let cp1 = CGPoint(x: source.x + sourceOffset.x, y: source.y + sourceOffset.y)
        let cp2 = CGPoint(x: target.x + targetOffset.x, y: target.y + targetOffset.y)

        var path = Path()
        path.move(to: source)
        path.addCurve(to: target, control1: cp1, control2: cp2)

        let labelPosition = cubicBezierPoint(t: 0.5, p0: source, p1: cp1, p2: cp2, p3: target)

        return EdgePath(path: path, labelPosition: labelPosition)
    }

    func path(
        from source: CGPoint, through waypoints: [CGPoint], to target: CGPoint, sharpIndices: Set<Int>
    ) -> EdgePath? {
        var points: [CGPoint] = [source]
        var sharpPoints = Set<Int>()
        for (index, point) in waypoints.enumerated() {
            if point != points.last { points.append(point) }
            if sharpIndices.contains(index) { sharpPoints.insert(points.count - 1) }
        }
        if target != points.last { points.append(target) }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }

        var path = Path()
        path.move(to: source)
        var incoming: Turn?
        var label = source
        var longest: CGFloat = 0
        var targetVector: CGVector?
        for index in 1..<points.count {
            let start = points[index - 1]
            let end = points[index]
            let chord = end - start
            let length = hypot(chord.x, chord.y)
            guard length.isFinite, length > 0 else { return nil }

            let unit = chord / length
            var outgoing: Turn?
            if index + 1 < points.count {
                let next = points[index + 1] - end
                let nextLength = hypot(next.x, next.y)
                guard nextLength.isFinite, nextLength > 0 else { return nil }
                if !sharpPoints.contains(index) {
                    outgoing = turn(from: unit, to: next / nextLength, length: min(length, nextLength))
                }
            } else {
                targetVector = CGVector(dx: chord.x, dy: chord.y)
            }

            var straightStart = start
            if let incoming {
                let arm = unit * (incoming.span / 3)
                straightStart = start + unit * incoming.span
                path.addCurve(to: straightStart, control1: start + incoming.tangent, control2: straightStart - arm)
            }

            var straightEnd = end
            if let outgoing {
                straightEnd = end - unit * outgoing.span
                path.addLine(to: straightEnd)
                let arm = unit * (outgoing.span / 3)
                path.addCurve(to: end, control1: straightEnd + arm, control2: end - outgoing.tangent)
            } else {
                path.addLine(to: end)
            }
            incoming = outgoing
            if length > longest {
                longest = length
                label = straightStart + (straightEnd - straightStart) / 2
            }
        }
        return EdgePath(path: path, labelPosition: label, targetVector: targetVector)
    }

    private struct Turn {
        let tangent: CGPoint
        let span: CGFloat
    }

    private func turn(from incoming: CGPoint, to outgoing: CGPoint, length: CGFloat) -> Turn? {
        let cross = incoming.x * outgoing.y - incoming.y * outgoing.x
        guard abs(cross) > CGFloat.ulpOfOne else { return nil }
        let bisector = incoming + outgoing
        let magnitude = hypot(bisector.x, bisector.y)
        guard magnitude > 0 else { return nil }

        // Only one control point is off the chord. Its Bernstein weight
        // is at most 4/9, so bound the arm using the maximum deviation.
        let span = min(length / 3, Self.maximumWaypointSpan)
        return Turn(tangent: (bisector / magnitude) * (span / 3), span: span)
    }

    private func controlOffset(for position: HandlePosition, distance: CGFloat) -> CGPoint {
        switch position {
        case .center: CGPoint(x: 0, y: 0)
        case .top: CGPoint(x: 0, y: -distance)
        case .bottom: CGPoint(x: 0, y: distance)
        case .left: CGPoint(x: -distance, y: 0)
        case .right: CGPoint(x: distance, y: 0)
        }
    }

    private func cubicBezierPoint(t: CGFloat, p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint) -> CGPoint {
        let mt = 1 - t
        let mt2 = mt * mt
        let t2 = t * t
        return CGPoint(
            x: mt2 * mt * p0.x + 3 * mt2 * t * p1.x + 3 * mt * t2 * p2.x + t2 * t * p3.x,
            y: mt2 * mt * p0.y + 3 * mt2 * t * p1.y + 3 * mt * t2 * p2.y + t2 * t * p3.y
        )
    }
}
