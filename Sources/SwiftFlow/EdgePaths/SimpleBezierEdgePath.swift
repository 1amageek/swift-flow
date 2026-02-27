import SwiftUI

public struct SimpleBezierEdgePath: EdgePathCalculating, Sendable {

    public init() {}

    public func path(
        from source: CGPoint,
        sourcePosition: HandlePosition,
        to target: CGPoint,
        targetPosition: HandlePosition
    ) -> EdgePath {
        let distance = hypot(target.x - source.x, target.y - source.y)
        let curvature = max(30, distance * 0.25)

        let offset = controlOffset(for: sourcePosition, distance: curvature)
        let controlPoint = CGPoint(
            x: (source.x + target.x) / 2 + offset.x,
            y: (source.y + target.y) / 2 + offset.y
        )

        var path = Path()
        path.move(to: source)
        path.addQuadCurve(to: target, control: controlPoint)

        let labelPosition = quadBezierPoint(t: 0.5, p0: source, p1: controlPoint, p2: target)

        return EdgePath(path: path, labelPosition: labelPosition)
    }

    private func controlOffset(for position: HandlePosition, distance: CGFloat) -> CGPoint {
        switch position {
        case .top: CGPoint(x: 0, y: -distance)
        case .bottom: CGPoint(x: 0, y: distance)
        case .left: CGPoint(x: -distance, y: 0)
        case .right: CGPoint(x: distance, y: 0)
        }
    }

    private func quadBezierPoint(t: CGFloat, p0: CGPoint, p1: CGPoint, p2: CGPoint) -> CGPoint {
        let mt = 1 - t
        return CGPoint(
            x: mt * mt * p0.x + 2 * mt * t * p1.x + t * t * p2.x,
            y: mt * mt * p0.y + 2 * mt * t * p1.y + t * t * p2.y
        )
    }
}
