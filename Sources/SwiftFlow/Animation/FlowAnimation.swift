import Foundation

/// Describes how an animated transition should be timed.
public struct FlowAnimation: Sendable {

    /// Timing curve for the animation.
    public enum Timing: Sendable {
        /// Spring-based timing with configurable response and damping.
        case spring(response: CGFloat = 0.55, dampingFraction: CGFloat = 1.0)
        /// Ease-in-out timing with a fixed duration.
        case easeInOut(duration: TimeInterval)
    }

    /// The timing curve used by this animation.
    public let timing: Timing

    /// Creates an animation with the given timing.
    public init(timing: Timing) {
        self.timing = timing
    }

    // MARK: - Factories

    /// A default animation using a critically-damped spring.
    public static let `default` = FlowAnimation(timing: .spring())

    /// A smooth animation using a longer-response critically-damped spring.
    public static let smooth = FlowAnimation(timing: .spring(response: 0.5, dampingFraction: 1.0))

    /// Creates a spring animation with custom parameters.
    public static func spring(response: CGFloat = 0.55, dampingFraction: CGFloat = 1.0) -> FlowAnimation {
        FlowAnimation(timing: .spring(response: response, dampingFraction: dampingFraction))
    }

    /// Creates an ease-in-out animation with a fixed duration.
    public static func easeInOut(duration: TimeInterval) -> FlowAnimation {
        FlowAnimation(timing: .easeInOut(duration: duration))
    }
}
