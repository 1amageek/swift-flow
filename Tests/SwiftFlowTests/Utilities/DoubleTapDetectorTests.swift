import Testing
@testable import SwiftFlow

@Suite("DoubleTapDetector")
struct DoubleTapDetectorTests {

    @Test("Same target within interval triggers double-tap")
    func sameTargetWithinInterval() {
        var detector = DoubleTapDetector(interval: 1.0)
        let first = detector.recordTap(target: .node("n1"))
        #expect(first == false)
        let second = detector.recordTap(target: .node("n1"))
        #expect(second == true)
    }

    @Test("Different node targets do not trigger double-tap")
    func differentNodeTargets() {
        var detector = DoubleTapDetector(interval: 1.0)
        _ = detector.recordTap(target: .node("n1"))
        let second = detector.recordTap(target: .node("n2"))
        #expect(second == false)
    }

    @Test("Triple-tap does not trigger second double-tap")
    func tripleTap() {
        var detector = DoubleTapDetector(interval: 1.0)
        _ = detector.recordTap(target: .node("n1"))
        let second = detector.recordTap(target: .node("n1"))
        #expect(second == true)
        let third = detector.recordTap(target: .node("n1"))
        #expect(third == false)
    }

    @Test("None target resets tracking state")
    func noneTargetResets() {
        var detector = DoubleTapDetector(interval: 1.0)
        _ = detector.recordTap(target: .node("n1"))
        _ = detector.recordTap(target: .none)
        let result = detector.recordTap(target: .node("n1"))
        #expect(result == false)
    }

    @Test("Edge double-tap detection")
    func edgeDoubleTap() {
        var detector = DoubleTapDetector(interval: 1.0)
        _ = detector.recordTap(target: .edge("e1"))
        let second = detector.recordTap(target: .edge("e1"))
        #expect(second == true)
    }

    @Test("Node then edge does not trigger double-tap")
    func nodeThenEdge() {
        var detector = DoubleTapDetector(interval: 1.0)
        _ = detector.recordTap(target: .node("n1"))
        let second = detector.recordTap(target: .edge("e1"))
        #expect(second == false)
    }

    @Test("Reset clears all state")
    func resetClearsState() {
        var detector = DoubleTapDetector(interval: 1.0)
        _ = detector.recordTap(target: .node("n1"))
        detector.reset()
        #expect(detector.lastTarget == .none)
        #expect(detector.lastTime == nil)
    }

    @Test("Default interval is 0.3 seconds")
    func defaultInterval() {
        let detector = DoubleTapDetector()
        #expect(detector.interval == 0.3)
    }
}
