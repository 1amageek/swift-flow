import Foundation

/// Whether `LiveNode` keeps its live subtree mounted across interaction
/// transitions or mounts it only on demand.
///
/// SwiftUI-only views rebuild their state cheaply on each interaction, so
/// the default ``onInteraction`` minimizes idle work. Native
/// representables backed by a renderer with meaningful view identity
/// (`WKWebView`, `MKMapView`, `AVPlayerView`) should use ``persistent``.
public enum LiveNodeMountPolicy: Sendable, Hashable {
    /// Mount the live subtree only while the node is interactive.
    ///
    /// This is the default. It minimizes SwiftUI update cost while
    /// panning, zooming, or interacting with non-interactive nodes.
    case onInteraction

    /// Keep the live subtree mounted while the node is present.
    ///
    /// Useful for views that are expensive or fragile to recreate,
    /// especially native renderers such as `WKWebView` and `MKMapView`.
    /// Keeping their view identity avoids detach/reattach side effects.
    case persistent
}
