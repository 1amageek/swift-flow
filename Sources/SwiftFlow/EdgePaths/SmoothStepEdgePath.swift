import SwiftUI

public struct SmoothStepEdgePath: EdgePathCalculating, Sendable {

    public var borderRadius: CGFloat

    public init(borderRadius: CGFloat = 5) {
        self.borderRadius = borderRadius
    }

    public func path(
        from source: CGPoint,
        sourcePosition: HandlePosition,
        to target: CGPoint,
        targetPosition: HandlePosition
    ) -> EdgePath {
        let offset: CGFloat = 20
        let sourceExt = extendedPoint(source, position: sourcePosition, offset: offset)
        let targetExt = extendedPoint(target, position: targetPosition, offset: offset)

        let midX = (sourceExt.x + targetExt.x) / 2
        let midY = (sourceExt.y + targetExt.y) / 2

        let points: [CGPoint]
        let isHorizontalSource = sourcePosition == .left || sourcePosition == .right
        let isHorizontalTarget = targetPosition == .left || targetPosition == .right

        if isHorizontalSource && isHorizontalTarget {
            points = [source, sourceExt, CGPoint(x: midX, y: sourceExt.y), CGPoint(x: midX, y: targetExt.y), targetExt, target]
        } else if !isHorizontalSource && !isHorizontalTarget {
            points = [source, sourceExt, CGPoint(x: sourceExt.x, y: midY), CGPoint(x: targetExt.x, y: midY), targetExt, target]
        } else if isHorizontalSource {
            points = [source, sourceExt, CGPoint(x: targetExt.x, y: sourceExt.y), targetExt, target]
        } else {
            points = [source, sourceExt, CGPoint(x: sourceExt.x, y: targetExt.y), targetExt, target]
        }

        let path = roundedStepPath(points: points, radius: borderRadius)

        let labelPosition = CGPoint(x: midX, y: midY)
        return EdgePath(path: path, labelPosition: labelPosition)
    }

    private func extendedPoint(_ point: CGPoint, position: HandlePosition, offset: CGFloat) -> CGPoint {
        switch position {
        case .top: CGPoint(x: point.x, y: point.y - offset)
        case .bottom: CGPoint(x: point.x, y: point.y + offset)
        case .left: CGPoint(x: point.x - offset, y: point.y)
        case .right: CGPoint(x: point.x + offset, y: point.y)
        }
    }

    private func roundedStepPath(points: [CGPoint], radius: CGFloat) -> Path {
        var path = Path()
        guard points.count >= 2 else { return path }
        path.move(to: points[0])

        for i in 1..<points.count - 1 {
            let prev = points[i - 1]
            let curr = points[i]
            let next = points[i + 1]

            let dx1 = curr.x - prev.x
            let dy1 = curr.y - prev.y
            let len1 = hypot(dx1, dy1)
            let dx2 = next.x - curr.x
            let dy2 = next.y - curr.y
            let len2 = hypot(dx2, dy2)

            guard len1 > 0, len2 > 0 else {
                path.addLine(to: curr)
                continue
            }

            let r = min(radius, len1 / 2, len2 / 2)

            let startX = curr.x - (dx1 / len1) * r
            let startY = curr.y - (dy1 / len1) * r
            let endX = curr.x + (dx2 / len2) * r
            let endY = curr.y + (dy2 / len2) * r

            path.addLine(to: CGPoint(x: startX, y: startY))
            path.addQuadCurve(to: CGPoint(x: endX, y: endY), control: curr)
        }

        path.addLine(to: points[points.count - 1])
        return path
    }
}
