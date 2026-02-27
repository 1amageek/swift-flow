import SwiftUI

public struct BezierEdgePath: EdgePathCalculating, Sendable {

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

    private func controlOffset(for position: HandlePosition, distance: CGFloat) -> CGPoint {
        switch position {
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
