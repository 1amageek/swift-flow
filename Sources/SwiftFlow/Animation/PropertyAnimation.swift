import Foundation

extension Duration {
    /// Converts a `Duration` to `TimeInterval` (seconds).
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) * 1e-18
    }
}

/// Tracks interpolation state for a single CGFloat component.
///
/// Supports spring (semi-implicit Euler) and ease-in-out (smoothstep) timing.
/// Call `tick(dt:)` each frame to advance the animation and check `settled`.
struct PropertyAnimation {

    /// Current interpolated value.
    var current: CGFloat

    /// Target value the animation is converging toward.
    var target: CGFloat

    /// Current velocity (units per second). Only meaningful for spring timing.
    var velocity: CGFloat

    /// Timing parameters for this animation.
    let timing: FlowAnimation.Timing

    // MARK: - EaseInOut State

    /// The value at the start of the current ease-in-out segment.
    private var easeStart: CGFloat

    /// Elapsed time since the current ease-in-out segment began.
    private var easeElapsed: TimeInterval

    /// Whether the animation has reached its target and come to rest.
    var settled: Bool

    // MARK: - Init

    init(from: CGFloat, to: CGFloat, timing: FlowAnimation.Timing) {
        self.current = from
        self.target = to
        self.velocity = 0
        self.timing = timing
        self.easeStart = from
        self.easeElapsed = 0
        self.settled = (from == to)
    }

    // MARK: - Tick

    /// Advances the animation by `dt` seconds.
    /// Returns the updated value and whether the animation has settled.
    @discardableResult
    mutating func tick(dt: TimeInterval) -> (value: CGFloat, settled: Bool) {
        guard !settled else { return (current, true) }

        switch timing {
        case .spring(let response, let dampingFraction):
            tickSpring(dt: dt, response: response, dampingFraction: dampingFraction)
        case .easeInOut(let duration):
            tickEaseInOut(dt: dt, duration: duration)
        }

        return (current, settled)
    }

    /// Retargets the animation to a new value, preserving current velocity for smooth interruption.
    mutating func retarget(to newTarget: CGFloat) {
        guard newTarget != target else { return }
        target = newTarget
        settled = false

        switch timing {
        case .spring:
            // Velocity is preserved automatically for spring animations.
            break
        case .easeInOut:
            // Restart the ease-in-out curve from the current position.
            easeStart = current
            easeElapsed = 0
        }
    }

    // MARK: - Spring (Semi-implicit Euler)

    private mutating func tickSpring(dt: TimeInterval, response: CGFloat, dampingFraction: CGFloat) {
        let dt = CGFloat(dt)
        guard response > 0 else {
            current = target
            velocity = 0
            settled = true
            return
        }

        let omega = 2 * CGFloat.pi / response
        let zeta = dampingFraction
        let displacement = current - target

        let acceleration = -omega * omega * displacement - 2 * zeta * omega * velocity
        velocity += acceleration * dt
        current += velocity * dt

        // Settle detection — threshold must be small enough for zoom values (~0.1–4.0)
        if abs(current - target) < 0.1 && abs(velocity) < 0.1 {
            current = target
            velocity = 0
            settled = true
        }
    }

    // MARK: - EaseInOut (Smoothstep)

    private mutating func tickEaseInOut(dt: TimeInterval, duration: TimeInterval) {
        guard duration > 0 else {
            current = target
            velocity = 0
            settled = true
            return
        }

        easeElapsed += dt
        let t = min(CGFloat(easeElapsed / duration), 1.0)
        let s = t * t * (3 - 2 * t) // smoothstep

        current = easeStart + s * (target - easeStart)

        if t >= 1.0 {
            current = target
            velocity = 0
            settled = true
        }
    }
}
