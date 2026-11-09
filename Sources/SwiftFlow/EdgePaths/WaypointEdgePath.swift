import SwiftUI

enum WaypointEdgePath {
    static func path(from source: CGPoint, through waypoints: [CGPoint], to target: CGPoint) -> EdgePath? {
        guard source.x.isFinite, source.y.isFinite else { return nil }
        var path = Path()
        path.move(to: source)
        var previous = source
        var label = source
        var longest: CGFloat = 0
        var targetVector: CGVector?

        for point in waypoints {
            guard append(point) else { return nil }
        }
        guard append(target) else { return nil }
        return EdgePath(path: path, labelPosition: label, targetVector: targetVector)

        func append(_ point: CGPoint) -> Bool {
            let length = previous.distance(to: point)
            guard length.isFinite else { return false }
            if length > 0 {
                path.addLine(to: point)
                targetVector = CGVector(dx: point.x - previous.x, dy: point.y - previous.y)
                if length > longest {
                    longest = length
                    label = previous + (point - previous) / 2
                }
                previous = point
            }
            return true
        }
    }
}
