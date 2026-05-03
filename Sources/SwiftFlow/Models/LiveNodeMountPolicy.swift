import Foundation

/// Whether the overlay row hosting a ``LiveNode`` is allowed to unmount
/// while the node is inactive, or must stay in the SwiftUI view tree as
/// long as it is in viewport.
///
/// The default ``onActivation`` matches `LiveNodeOverlay`'s baseline
/// policy: a row is mounted only while the activation predicate is true
/// (the user is hovering / selecting it) or while a snapshot is still
/// being warmed up. Once both conditions go false the row is replaced
/// by a zero-size spacer, the ``LiveNode`` subtree leaves the view
/// tree, and the Canvas rasterize path takes over drawing.
///
/// SwiftUI-only content tolerates that lifecycle — its state rebuilds
/// from scratch on each remount and the captured snapshot fills the
/// rasterize gap. Native representables backed by a separate process —
/// `WKWebView`, `MKMapView`, `AVPlayerView` — do **not** tolerate it.
/// The `removeFromSuperview` step propagates `viewDidMoveToWindow(nil)`
/// into the remote-layer subtree, which puts the WebContent / map tile
/// / player processes into a dormant state. Reattachment does not
/// reliably wake the CARemoteLayerClient / CAMetalLayer pipeline, so
/// the surface stays blank from the second activation onward.
///
/// ``persistent`` keeps the row mounted continuously while the node is
/// in viewport. The activation predicate then only toggles the row's
/// `opacity` and hit-testing — the underlying native view never
/// detaches, its compositor never stalls, and URL / scroll / pan / zoom
/// / playback state survives without any save/restore plumbing.
///
/// The cost of ``persistent`` is that the WebContent / map / player
/// process keeps running while the node is in viewport even when the
/// user is not interacting with it; pick it only for native nodes that
/// need it, and leave SwiftUI-only ``LiveNode``s on the default
/// ``onActivation``.
public enum LiveNodeMountPolicy: Sendable, Hashable {
    /// Default. The row mounts only while the activation predicate is
    /// true or while warming up the first snapshot. Suitable for
    /// SwiftUI-only content.
    case onActivation

    /// The row stays mounted continuously while the node is in
    /// viewport. The activation predicate drives `opacity` and
    /// hit-testing only. Required for native representables backed by
    /// a separate process (`WKWebView`, `MKMapView`, `AVPlayerView`).
    case persistent
}
