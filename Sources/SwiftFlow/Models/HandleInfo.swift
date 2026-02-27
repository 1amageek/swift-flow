import CoreGraphics

struct HandleInfo: Sendable, Hashable {
    var point: CGPoint
    var position: HandlePosition
    var type: HandleType
}
