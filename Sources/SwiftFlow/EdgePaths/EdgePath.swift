import SwiftUI

public struct EdgePath: Sendable {

    public let path: Path
    public let labelPosition: CGPoint
    public let labelAngle: Angle

    public init(path: Path, labelPosition: CGPoint, labelAngle: Angle = .zero) {
        self.path = path
        self.labelPosition = labelPosition
        self.labelAngle = labelAngle
    }
}
