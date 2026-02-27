import Foundation

enum GeometryHelpers {

    static func hitTest(point: CGPoint, rect: CGRect, tolerance: CGFloat = 0) -> Bool {
        rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    static func pointOnLine(
        from start: CGPoint,
        to end: CGPoint,
        point: CGPoint,
        tolerance: CGFloat = 5
    ) -> Bool {
        let lineLength = start.distance(to: end)
        guard lineLength > 0 else { return start.distance(to: point) <= tolerance }

        let t = max(0, min(1,
            ((point.x - start.x) * (end.x - start.x) + (point.y - start.y) * (end.y - start.y))
            / (lineLength * lineLength)
        ))

        let projection = CGPoint(
            x: start.x + t * (end.x - start.x),
            y: start.y + t * (end.y - start.y)
        )

        return point.distance(to: projection) <= tolerance
    }

    static func boundingBox(of nodes: [CGRect]) -> CGRect {
        guard let first = nodes.first else { return .zero }
        var result = first
        for rect in nodes.dropFirst() {
            result = result.union(rect)
        }
        return result
    }
}
