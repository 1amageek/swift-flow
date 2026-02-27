import SwiftUI

public enum BackgroundPattern: String, Sendable {
    case none
    case grid
    case dot
}

public struct BackgroundStyle: Sendable {

    public var pattern: BackgroundPattern
    public var color: Color
    public var spacing: CGFloat
    public var lineWidth: CGFloat
    public var dotRadius: CGFloat

    public init(
        pattern: BackgroundPattern = .none,
        color: Color = .gray.opacity(0.2),
        spacing: CGFloat = 20,
        lineWidth: CGFloat = 0.5,
        dotRadius: CGFloat = 1.5
    ) {
        self.pattern = pattern
        self.color = color
        self.spacing = spacing
        self.lineWidth = lineWidth
        self.dotRadius = dotRadius
    }
}
