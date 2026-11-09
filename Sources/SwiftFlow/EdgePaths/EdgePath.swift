import SwiftUI

public struct EdgePath: Sendable {

    public let path: Path
    public let labelPosition: CGPoint
    public let labelAngle: Angle

    /// Final direction of an explicit route, scaled by the last chord length in canvas space.
    public let targetVector: CGVector?

    public init(path: Path, labelPosition: CGPoint, labelAngle: Angle = .zero) {
        self.init(path: path, labelPosition: labelPosition, labelAngle: labelAngle, targetVector: nil)
    }

    init(path: Path, labelPosition: CGPoint, labelAngle: Angle = .zero, targetVector: CGVector?) {
        self.path = path
        self.labelPosition = labelPosition
        self.labelAngle = labelAngle
        self.targetVector = targetVector
    }
}
