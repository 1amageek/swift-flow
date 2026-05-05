import SwiftUI

/// Geometry information provided to custom edge content closures.
///
/// All point coordinates are in the edge view's **local coordinate system**,
/// where the bounding rect origin is mapped to (0, 0). The `bounds` property
/// retains the original canvas-space rect for placement by the canvas.
public struct EdgeGeometry: Sendable {

    /// Pre-computed edge path in local coordinates.
    public let path: Path

    /// Source handle position in local coordinates.
    public let sourcePoint: CGPoint

    /// Target handle position in local coordinates.
    public let targetPoint: CGPoint

    /// Source handle direction (top/bottom/left/right).
    public let sourcePosition: HandlePosition

    /// Target handle direction (top/bottom/left/right).
    public let targetPosition: HandlePosition

    /// Suggested label placement in local coordinates.
    public let labelPosition: CGPoint

    /// Suggested label rotation angle.
    public let labelAngle: Angle

    /// Canvas-space bounding rect used for symbol placement.
    /// The view's local coordinate system spans (0, 0) to (bounds.width, bounds.height).
    public let bounds: CGRect
}
