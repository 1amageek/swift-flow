import Foundation

/// Cadence at which `LiveNode` captures a snapshot of its live content for
/// the Canvas rasterize path.
///
/// Pick the variant that matches the live content's update rate:
///
/// - ``onDeactivation``: capture once when the node becomes inactive.
///   Suited to mostly static SwiftUI views that only need to be refreshed
///   after edits.
/// - ``periodic(_:)``: capture every `interval` seconds while the node is
///   active. Suited to animated or clock-driven views where the snapshot
///   should reflect a recent frame.
/// - ``manual``: the library never captures. The app is responsible for
///   writing to `FlowStore.setNodeSnapshot(_:for:)`. Required for native
///   views (WKWebView / MKMapView / AVPlayerView) that cannot be rendered
///   off-screen by `ImageRenderer`.
public enum LiveNodeCapture: Sendable, Hashable {
    case onDeactivation
    case periodic(TimeInterval)
    case manual
}
