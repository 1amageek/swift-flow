import Testing
import Foundation
@testable import SwiftFlow

@Suite("EdgePath Tests")
struct EdgePathTests {

    @Test("BezierEdgePath produces non-empty path")
    func bezierPath() {
        let calculator = BezierEdgePath()
        let result = calculator.path(
            from: CGPoint(x: 0, y: 0),
            sourcePosition: .right,
            to: CGPoint(x: 200, y: 100),
            targetPosition: .left
        )
        #expect(!result.path.isEmpty)
    }

    @Test("StraightEdgePath produces non-empty path")
    func straightPath() {
        let calculator = StraightEdgePath()
        let result = calculator.path(
            from: CGPoint(x: 0, y: 0),
            sourcePosition: .right,
            to: CGPoint(x: 200, y: 100),
            targetPosition: .left
        )
        #expect(!result.path.isEmpty)
    }

    @Test("StraightEdgePath label at midpoint")
    func straightLabelPosition() {
        let calculator = StraightEdgePath()
        let result = calculator.path(
            from: CGPoint(x: 0, y: 0),
            sourcePosition: .right,
            to: CGPoint(x: 200, y: 100),
            targetPosition: .left
        )
        #expect(abs(result.labelPosition.x - 100) < 0.01)
        #expect(abs(result.labelPosition.y - 50) < 0.01)
    }

    @Test("SmoothStepEdgePath produces non-empty path")
    func smoothStepPath() {
        let calculator = SmoothStepEdgePath()
        let result = calculator.path(
            from: CGPoint(x: 0, y: 0),
            sourcePosition: .right,
            to: CGPoint(x: 200, y: 100),
            targetPosition: .left
        )
        #expect(!result.path.isEmpty)
    }

    @Test("SimpleBezierEdgePath produces non-empty path")
    func simpleBezierPath() {
        let calculator = SimpleBezierEdgePath()
        let result = calculator.path(
            from: CGPoint(x: 0, y: 0),
            sourcePosition: .bottom,
            to: CGPoint(x: 100, y: 200),
            targetPosition: .top
        )
        #expect(!result.path.isEmpty)
    }
}
