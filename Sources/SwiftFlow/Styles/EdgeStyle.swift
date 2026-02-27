import SwiftUI

public struct EdgeStyle: Sendable {

    public var strokeColor: Color
    public var selectedStrokeColor: Color
    public var lineWidth: CGFloat
    public var selectedLineWidth: CGFloat
    public var dashPattern: [CGFloat]
    public var animatedDashPattern: [CGFloat]

    public init(
        strokeColor: Color = .gray,
        selectedStrokeColor: Color = .blue,
        lineWidth: CGFloat = 1.5,
        selectedLineWidth: CGFloat = 2.5,
        dashPattern: [CGFloat] = [],
        animatedDashPattern: [CGFloat] = [5, 5]
    ) {
        self.strokeColor = strokeColor
        self.selectedStrokeColor = selectedStrokeColor
        self.lineWidth = lineWidth
        self.selectedLineWidth = selectedLineWidth
        self.dashPattern = dashPattern
        self.animatedDashPattern = animatedDashPattern
    }
}
