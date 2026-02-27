import Foundation

public enum EdgePathType: String, Sendable, Hashable, Codable {
    case bezier
    case straight
    case smoothStep
    case simpleBezier
}
