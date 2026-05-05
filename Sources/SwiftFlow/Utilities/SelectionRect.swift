import Foundation

public struct SelectionRect: Sendable, Hashable {

    public var origin: CGPoint
    public var size: CGSize

    public init(origin: CGPoint, size: CGSize) {
        self.origin = origin
        self.size = size
    }

    public var rect: CGRect {
        CGRect(origin: origin, size: size).standardized
    }

    public func contains(_ point: CGPoint) -> Bool {
        rect.contains(point)
    }

    public func intersects(_ frame: CGRect) -> Bool {
        rect.intersects(frame)
    }
}
