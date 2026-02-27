import SwiftUI

public struct StraightEdgePath: EdgePathCalculating, Sendable {

    public init() {}

    public func path(
        from source: CGPoint,
        sourcePosition: HandlePosition,
        to target: CGPoint,
        targetPosition: HandlePosition
    ) -> EdgePath {
        var path = Path()
        path.move(to: source)
        path.addLine(to: target)

        let labelPosition = CGPoint(
            x: (source.x + target.x) / 2,
            y: (source.y + target.y) / 2
        )

        let angle = atan2(target.y - source.y, target.x - source.x)

        return EdgePath(path: path, labelPosition: labelPosition, labelAngle: .radians(angle))
    }
}
