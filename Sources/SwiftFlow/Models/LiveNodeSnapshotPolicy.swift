import Foundation

/// Combination of *how* `LiveNode` captures a snapshot of its live content
/// (``LiveNodeSnapshotSource``) and *when* it does so
/// (``LiveNodeSnapshotTriggers``).
///
/// Use the static factories (``automatic``, ``native``, ``disabled``,
/// ``automaticPeriodic(_:)``, ``nativePeriodic(_:)``) for the common cases;
/// construct directly only when you need a custom trigger set.
public struct LiveNodeSnapshotPolicy: Sendable, Hashable {
    public var source: LiveNodeSnapshotSource
    public var triggers: LiveNodeSnapshotTriggers

    public init(
        source: LiveNodeSnapshotSource,
        triggers: LiveNodeSnapshotTriggers
    ) {
        self.source = source
        self.triggers = triggers
    }

    /// SwiftUI-only snapshotting via `ImageRenderer`.
    ///
    /// Default behavior:
    ///
    /// - seed an initial snapshot when needed
    /// - capture again right before deactivation / hover-out
    public static let automatic = LiveNodeSnapshotPolicy(
        source: .swiftUI,
        triggers: .automaticDefault
    )

    /// Native snapshotting.
    ///
    /// Default behavior:
    ///
    /// - native view registers a handler used right before deactivation
    ///
    /// Ready-driven snapshot writes are intentionally **off** by default.
    /// High-frequency delegates (e.g. `MKMapViewDelegate.mapViewDidFinishRenderingMap`)
    /// can fire repeatedly, and a snapshot write mutates the store, which
    /// re-renders the native view, which fires the delegate again — a
    /// feedback loop that stalls SwiftUI Preview updates and burns CPU at
    /// runtime. Use ``nativeReadyDriven`` if your delegate is known to
    /// fire once (e.g. `WKNavigationDelegate.didFinish` per navigation).
    ///
    /// This is intended for `UIViewRepresentable` / `NSViewRepresentable`.
    public static let native = LiveNodeSnapshotPolicy(
        source: .native,
        triggers: .nativeDefault
    )

    /// Native snapshotting with ready-driven writes enabled.
    ///
    /// Use only when the native view's "ready" signal fires a bounded
    /// number of times per content change (good: `WKNavigationDelegate.didFinish`;
    /// bad: `MKMapViewDelegate.mapViewDidFinishRenderingMap`).
    public static let nativeReadyDriven = LiveNodeSnapshotPolicy(
        source: .native,
        triggers: .nativeReadyDriven
    )

    /// Native snapshotting with manual capture requests enabled.
    ///
    /// Use when the native view needs to decide itself when a "first
    /// frame is stable" capture is safe — typically after window attach
    /// and a non-zero bounds layout (e.g. `MKMapView` after the tile
    /// pipeline has been kicked). The Representable calls
    /// ``LiveNodeNativeSnapshotContext/requestCapture()`` once it is
    /// satisfied that the native view has produced its first stable
    /// frame; `LiveNode` routes the request through its capture handler
    /// and writes the snapshot.
    public static let nativeManual = LiveNodeSnapshotPolicy(
        source: .native,
        triggers: .nativeManual
    )

    /// No snapshot capture.
    public static let disabled = LiveNodeSnapshotPolicy(
        source: .disabled,
        triggers: .disabled
    )

    /// SwiftUI-only periodic snapshotting.
    public static func automaticPeriodic(_ interval: TimeInterval) -> LiveNodeSnapshotPolicy {
        LiveNodeSnapshotPolicy(
            source: .swiftUI,
            triggers: .automaticPeriodic(interval)
        )
    }

    /// Native periodic snapshotting.
    ///
    /// The native view must register a capture handler through
    /// `liveNodeNativeSnapshotContext`.
    public static func nativePeriodic(_ interval: TimeInterval) -> LiveNodeSnapshotPolicy {
        LiveNodeSnapshotPolicy(
            source: .native,
            triggers: .nativePeriodic(interval)
        )
    }
}

/// How a snapshot is produced when one of the triggers fires.
public enum LiveNodeSnapshotSource: Sendable, Hashable {
    /// Capture by re-rendering the SwiftUI view with `ImageRenderer`.
    case swiftUI

    /// Capture through a native view handler registered from the child view.
    case native

    /// Do not capture.
    case disabled
}

/// Set of conditions under which `LiveNode` triggers a capture.
public struct LiveNodeSnapshotTriggers: Sendable, Hashable {
    public var seedOnAppear: Bool
    public var onActivation: Bool
    public var onDeactivation: Bool
    public var readyDriven: Bool
    public var manual: Bool
    public var periodicInterval: TimeInterval?

    public init(
        seedOnAppear: Bool = false,
        onActivation: Bool = false,
        onDeactivation: Bool = false,
        readyDriven: Bool = false,
        manual: Bool = false,
        periodicInterval: TimeInterval? = nil
    ) {
        self.seedOnAppear = seedOnAppear
        self.onActivation = onActivation
        self.onDeactivation = onDeactivation
        self.readyDriven = readyDriven
        self.manual = manual
        self.periodicInterval = periodicInterval
    }

    /// Default for SwiftUI-only content.
    ///
    /// Gives the rasterize path an initial image and refreshes it when
    /// hover/activation ends.
    public static let automaticDefault = LiveNodeSnapshotTriggers(
        seedOnAppear: true,
        onDeactivation: true
    )

    /// Default for native content.
    ///
    /// Native content usually cannot be captured safely on initial mount.
    /// The view registers a handler for hover-out / deactivation.
    /// Ready-driven writes are off by default — see
    /// ``LiveNodeSnapshotPolicy/native`` for the rationale.
    public static let nativeDefault = LiveNodeSnapshotTriggers(
        seedOnAppear: false,
        onDeactivation: true,
        readyDriven: false
    )

    /// Native content that writes a ready-driven snapshot in addition to
    /// the deactivation capture. Reserved for delegates known to fire a
    /// bounded number of times per content change.
    public static let nativeReadyDriven = LiveNodeSnapshotTriggers(
        seedOnAppear: false,
        onDeactivation: true,
        readyDriven: true
    )

    /// Native content that captures on demand via
    /// ``LiveNodeNativeSnapshotContext/requestCapture()`` plus the usual
    /// hover-out / deactivation capture.
    public static let nativeManual = LiveNodeSnapshotTriggers(
        seedOnAppear: false,
        onDeactivation: true,
        manual: true
    )

    public static let disabled = LiveNodeSnapshotTriggers()

    public static func automaticPeriodic(_ interval: TimeInterval) -> LiveNodeSnapshotTriggers {
        LiveNodeSnapshotTriggers(
            seedOnAppear: true,
            onDeactivation: true,
            periodicInterval: interval
        )
    }

    public static func nativePeriodic(_ interval: TimeInterval) -> LiveNodeSnapshotTriggers {
        LiveNodeSnapshotTriggers(
            seedOnAppear: false,
            onDeactivation: true,
            readyDriven: true,
            periodicInterval: interval
        )
    }
}

extension LiveNodeSnapshotPolicy {
    /// Stable identity used to key `.task(id:)` so the deactivation
    /// registration restarts when a meaningful policy field changes.
    var registrationIdentity: String {
        let periodic = triggers.periodicInterval.map { "\($0)" } ?? "nil"
        let parts: [String] = [
            "source=\(source)",
            "seed=\(triggers.seedOnAppear)",
            "onActivation=\(triggers.onActivation)",
            "onDeactivation=\(triggers.onDeactivation)",
            "readyDriven=\(triggers.readyDriven)",
            "manual=\(triggers.manual)",
            "periodic=\(periodic)"
        ]
        return parts.joined(separator: ",")
    }
}
