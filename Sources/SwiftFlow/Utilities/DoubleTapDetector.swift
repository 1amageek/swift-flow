import Foundation

/// Represents the target of a tap event for double-tap detection.
enum DoubleTapTarget: Equatable, Sendable {
    case none
    case node(String)
    case edge(String)
}

/// Detects double-tap gestures using manual timing comparison.
///
/// SwiftUI's `onTapGesture(count: 2)` delays single-tap recognition by ~300ms,
/// which is unacceptable for canvas interactions. This detector enables immediate
/// single-tap response while still detecting double-taps.
struct DoubleTapDetector: Sendable {

    private(set) var lastTarget: DoubleTapTarget = .none
    private(set) var lastTime: ContinuousClock.Instant?

    /// Maximum interval between two taps to count as a double-tap.
    let interval: TimeInterval

    init(interval: TimeInterval = 0.3) {
        self.interval = interval
    }

    /// Records a tap on the given target and returns whether it constitutes a double-tap.
    ///
    /// Call this after performing the single-tap action. If `true` is returned,
    /// fire the double-tap callback. A `.none` target always resets the tracker.
    mutating func recordTap(target: DoubleTapTarget) -> Bool {
        guard target != .none else {
            reset()
            return false
        }

        let now = ContinuousClock.now
        let isDoubleTap = target == lastTarget
            && lastTime.map { (now - $0) < .seconds(interval) } ?? false

        if isDoubleTap {
            reset()
        } else {
            lastTarget = target
            lastTime = now
        }

        return isDoubleTap
    }

    /// Resets the double-tap tracking state.
    mutating func reset() {
        lastTarget = .none
        lastTime = nil
    }
}
