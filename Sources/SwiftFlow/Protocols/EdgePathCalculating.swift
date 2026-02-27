import Foundation

public protocol EdgePathCalculating: Sendable {
    func path(
        from source: CGPoint,
        sourcePosition: HandlePosition,
        to target: CGPoint,
        targetPosition: HandlePosition
    ) -> EdgePath
}
