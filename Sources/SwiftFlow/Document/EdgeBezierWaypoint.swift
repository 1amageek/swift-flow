import Foundation

/// An on-curve point and the offsets to the controls on each side of it.
public struct EdgeBezierWaypoint: Sendable, Hashable, Codable {
    public var point: CGPoint
    public var incomingControlOffset: CGPoint
    public var outgoingControlOffset: CGPoint

    public init(point: CGPoint, incomingControlOffset: CGPoint, outgoingControlOffset: CGPoint) {
        self.point = point
        self.incomingControlOffset = incomingControlOffset
        self.outgoingControlOffset = outgoingControlOffset
    }
}
