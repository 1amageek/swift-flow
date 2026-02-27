import Foundation
import CoreGraphics
import Testing
@testable import SwiftFlow

@Suite("PropertyAnimation")
struct PropertyAnimationTests {

    // MARK: - Spring

    @Test("Spring settles at target")
    func springSettlesAtTarget() {
        var anim = PropertyAnimation(from: 0, to: 100, timing: .spring())
        let dt: TimeInterval = 1.0 / 120.0

        for _ in 0..<1000 {
            if anim.settled { break }
            anim.tick(dt: dt)
        }

        #expect(anim.settled)
        #expect(anim.current == 100)
    }

    @Test("Spring retarget preserves velocity")
    func springRetargetPreservesVelocity() {
        var anim = PropertyAnimation(from: 0, to: 100, timing: .spring())
        let dt: TimeInterval = 1.0 / 120.0

        // Advance partway
        for _ in 0..<30 {
            anim.tick(dt: dt)
        }

        let velocityBeforeRetarget = anim.velocity
        #expect(!anim.settled)
        #expect(velocityBeforeRetarget != 0)

        // Retarget
        anim.retarget(to: 200)
        #expect(anim.velocity == velocityBeforeRetarget)
        #expect(anim.target == 200)

        // Should eventually settle at new target
        for _ in 0..<2000 {
            if anim.settled { break }
            anim.tick(dt: dt)
        }
        #expect(anim.settled)
        #expect(anim.current == 200)
    }

    @Test("Underdamped spring overshoots then settles")
    func underdampedSpringOvershoots() {
        var anim = PropertyAnimation(from: 0, to: 100, timing: .spring(response: 0.55, dampingFraction: 0.5))
        let dt: TimeInterval = 1.0 / 120.0
        var maxValue: CGFloat = 0

        for _ in 0..<2000 {
            if anim.settled { break }
            anim.tick(dt: dt)
            maxValue = max(maxValue, anim.current)
        }

        #expect(maxValue > 100) // Overshoot
        #expect(anim.settled)
        #expect(anim.current == 100)
    }

    @Test("No displacement = already settled")
    func noDisplacementAlreadySettled() {
        let anim = PropertyAnimation(from: 50, to: 50, timing: .spring())
        #expect(anim.settled)
        #expect(anim.current == 50)
    }

    // MARK: - EaseInOut

    @Test("EaseInOut settles after duration")
    func easeInOutSettlesAfterDuration() {
        var anim = PropertyAnimation(from: 0, to: 100, timing: .easeInOut(duration: 0.3))
        let dt: TimeInterval = 1.0 / 120.0

        for _ in 0..<1000 {
            if anim.settled { break }
            anim.tick(dt: dt)
        }

        #expect(anim.settled)
        #expect(anim.current == 100)
    }

    @Test("EaseInOut midpoint approximately 50%")
    func easeInOutMidpoint() {
        var anim = PropertyAnimation(from: 0, to: 100, timing: .easeInOut(duration: 1.0))
        let dt: TimeInterval = 1.0 / 120.0

        // Advance to approximately the midpoint (0.5 seconds)
        let halfSteps = Int(0.5 / dt)
        for _ in 0..<halfSteps {
            anim.tick(dt: dt)
        }

        // Smoothstep at t=0.5 should give s = 0.5² * (3 - 2*0.5) = 0.25 * 2 = 0.5
        #expect(abs(anim.current - 50) < 5)
    }

    @Test("Zero duration doesn't crash")
    func zeroDurationDoesNotCrash() {
        var anim = PropertyAnimation(from: 0, to: 100, timing: .easeInOut(duration: 0))
        anim.tick(dt: 1.0 / 120.0)

        #expect(anim.settled)
        #expect(anim.current == 100)
    }

    @Test("Zero spring response doesn't crash")
    func zeroSpringResponseDoesNotCrash() {
        var anim = PropertyAnimation(from: 0, to: 100, timing: .spring(response: 0, dampingFraction: 1.0))
        anim.tick(dt: 1.0 / 120.0)

        #expect(anim.settled)
        #expect(anim.current == 100)
    }
}
