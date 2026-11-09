import Foundation

public enum HandlePosition: String, Sendable, Hashable, Codable {
    case center
    case top
    case bottom
    case left
    case right

    /// The handle anchor in the coordinate system of the supplied frame.
    public func anchor(in frame: CGRect) -> CGPoint {
        switch self {
        case .center: CGPoint(x: frame.midX, y: frame.midY)
        case .top: CGPoint(x: frame.midX, y: frame.minY)
        case .bottom: CGPoint(x: frame.midX, y: frame.maxY)
        case .left: CGPoint(x: frame.minX, y: frame.midY)
        case .right: CGPoint(x: frame.maxX, y: frame.midY)
        }
    }
}
