import Foundation

/// Controls *when* `LiveNode` performs a snapshot capture.
///
/// *How* the capture is produced is controlled separately by
/// ``LiveNodeCapture`` (passed as an init argument to `LiveNode`).
///
/// Use the static factories (``automatic``, ``onDeactivation``,
/// ``disabled``, ``periodic(_:)``) for the common cases.
public struct LiveNodeSnapshotPolicy: Sendable, Hashable {

    public var when: When
    public var seedOnAppear: Bool

    public init(when: When, seedOnAppear: Bool) {
        self.when = when
        self.seedOnAppear = seedOnAppear
    }

    /// Triggers that fire a capture.
    public enum When: Sendable, Hashable {
        /// Never capture.
        case never
        /// Capture once, right before the node deactivates / hover-out.
        case onDeactivation
        /// Capture both when the node first activates and again on
        /// deactivation. Useful for live content whose first frame
        /// differs from its idle state.
        case onActivationAndDeactivation
        /// Capture continuously at the given interval (seconds), in
        /// addition to deactivation.
        case periodic(TimeInterval)
    }

    /// Default. Seeds an initial snapshot when no snapshot exists, then
    /// recaptures on each deactivation.
    public static let automatic = Self(
        when: .onDeactivation,
        seedOnAppear: true
    )

    /// Capture only on deactivation. The first activation runs without a
    /// seed snapshot — the rasterize path falls back to the placeholder
    /// until the first capture lands.
    public static let onDeactivation = Self(
        when: .onDeactivation,
        seedOnAppear: false
    )

    /// No snapshot capture.
    public static let disabled = Self(
        when: .never,
        seedOnAppear: false
    )

    /// Periodic snapshotting plus capture on deactivation.
    public static func periodic(_ interval: TimeInterval) -> Self {
        Self(
            when: .periodic(interval),
            seedOnAppear: true
        )
    }
}

extension LiveNodeSnapshotPolicy {
    /// Stable identity used to key `.task(id:)` so the deactivation
    /// registration restarts when a meaningful policy field changes.
    var registrationIdentity: String {
        let whenKey: String
        switch when {
        case .never:
            whenKey = "never"
        case .onDeactivation:
            whenKey = "onDeactivation"
        case .onActivationAndDeactivation:
            whenKey = "onActivationAndDeactivation"
        case let .periodic(interval):
            whenKey = "periodic(\(interval))"
        }
        return "when=\(whenKey),seed=\(seedOnAppear)"
    }

    var seedsOnAppear: Bool { seedOnAppear }
    var triggersOnActivation: Bool {
        if case .onActivationAndDeactivation = when { return true }
        return false
    }
    var triggersOnDeactivation: Bool {
        switch when {
        case .never:
            return false
        case .onDeactivation, .onActivationAndDeactivation, .periodic:
            return true
        }
    }
    var periodicInterval: TimeInterval? {
        if case let .periodic(interval) = when { return interval }
        return nil
    }
}
