import CoreGraphics

public struct Viewport: Sendable, Hashable, Codable {

    public var offset: CGPoint
    public var zoom: CGFloat

    public init(offset: CGPoint = .zero, zoom: CGFloat = 1.0) {
        self.offset = offset
        self.zoom = zoom
    }

    public func screenToCanvas(_ point: CGPoint) -> CGPoint {
        let safeZoom = max(zoom, 0.01)
        return CGPoint(
            x: (point.x - offset.x) / safeZoom,
            y: (point.y - offset.y) / safeZoom
        )
    }

    public func canvasToScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x * zoom + offset.x,
            y: point.y * zoom + offset.y
        )
    }
}
