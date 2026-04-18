import Foundation

/// Cadence at which `LiveNode` captures a snapshot of its live content for
/// the Canvas rasterize path.
///
/// Pick the variant that matches the live content's update rate:
///
/// - ``onDeactivation``: capture once when the node starts deactivating.
///   Suited to mostly static SwiftUI views that only need to be refreshed
///   after edits. The library uses `ImageRenderer` off-screen.
/// - ``periodic(_:)``: capture every `interval` seconds while the node is
///   active, and once more when it starts deactivating. Suited to
///   animated or clock-driven views.
/// - ``manual(capture:)``: the app supplies an async closure that writes
///   a fresh snapshot to `FlowStore.setNodeSnapshot(_:for:)`. Required
///   for native views (WKWebView / MKMapView / AVPlayerView) that
///   `ImageRenderer` cannot rasterize off-screen.
///
/// Regardless of the variant, the Canvas does **not** flip back to the
/// rasterize path until after the capture handler returns — so the new
/// snapshot is always the first frame the user sees when the live view
/// hides. This eliminates the "old thumbnail flash" that would otherwise
/// appear between deactivation and snapshot completion.
public enum LiveNodeCapture: Sendable {
    case onDeactivation
    case periodic(TimeInterval)
    case manual(capture: @MainActor @Sendable () async -> Void)
}
