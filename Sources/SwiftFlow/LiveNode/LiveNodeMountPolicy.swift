import Foundation

/// Whether `LiveNode` keeps its live subtree mounted across activation
/// transitions, mounts it only on demand, or recreates it from scratch on
/// every activation.
///
/// The choice is dictated by the live content's tolerance for SwiftUI
/// remount cycles. SwiftUI-only views rebuild their state cheaply on each
/// remount, so the default ``onActivation`` minimizes idle work. Native
/// representables backed by an out-of-process renderer (`WKWebView`,
/// `MKMapView`, `AVPlayerView`) need different handling — see the cases
/// for guidance.
public enum LiveNodeMountPolicy: Sendable, Hashable {
    /// Mount the live subtree only while the node is active.
    ///
    /// This is the default. It minimizes SwiftUI update cost while
    /// panning, zooming, or interacting with inactive nodes.
    case onActivation

    /// Keep the live subtree mounted while the node is present.
    ///
    /// Useful for views that are expensive or fragile to remount,
    /// especially `WKWebView` — its WebContent process goes dormant when
    /// the view detaches and does not reliably wake on reattach.
    case persistent

    /// Recreate the live subtree every time the node becomes active.
    ///
    /// Useful for views whose renderer may not recover cleanly after
    /// becoming inactive, especially `MKMapView`.
    case remountOnActivation
}
