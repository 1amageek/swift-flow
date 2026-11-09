import Foundation

/// A cubic route whose end controls are relative to the live handle anchors.
public struct EdgeBezierRoute: Sendable, Hashable, Codable {
    public var sourceControlOffset: CGPoint
    public var waypoints: [EdgeBezierWaypoint]
    public var targetControlOffset: CGPoint

    public init(sourceControlOffset: CGPoint, waypoints: [EdgeBezierWaypoint], targetControlOffset: CGPoint) {
        self.sourceControlOffset = sourceControlOffset
        self.waypoints = waypoints
        self.targetControlOffset = targetControlOffset
    }
}
