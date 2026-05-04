import Foundation

/// Strategy `LiveNode` uses to produce a snapshot of its live content.
///
/// `.auto` — the default — re-renders the SwiftUI body via `ImageRenderer`.
/// This works only for pure SwiftUI content; native views wrapped in
/// `UIViewRepresentable` / `NSViewRepresentable` (`WKWebView`, `MKMapView`,
/// `AVPlayerView`) are not part of SwiftUI's render tree as far as
/// `ImageRenderer` is concerned and will rasterize as opaque background.
///
/// `.custom` lets the developer supply an async closure that returns a
/// `FlowNodeSnapshot`. The developer typically owns the underlying native
/// view through `@State` and captures it in the closure:
///
/// ```swift
/// @State private var webView = WKWebView()
///
/// LiveNode(
///     node: node,
///     mount: .persistent,
///     capture: .custom { await webView.makeFlowNodeSnapshot() }
/// ) {
///     WebRepresentable(webView: webView, url: url)
/// }
/// ```
///
/// `.disabled` skips capture entirely; the rasterize path falls back to
/// the placeholder.
public enum LiveNodeCapture: Sendable {

    /// Use `ImageRenderer` to capture the SwiftUI body. Suitable for pure
    /// SwiftUI content. Native views render as background.
    case auto

    /// Use a developer-supplied closure to produce the snapshot. The
    /// closure is invoked on `MainActor` whenever `LiveNode` decides a
    /// capture is needed (per ``LiveNodeSnapshotPolicy``).
    ///
    /// The closure is `@Sendable` so it can be carried across actor
    /// boundaries inside `LiveNodeConfiguration`. Captures of
    /// `@MainActor`-isolated values (e.g. an `ObservableObject` ref
    /// holder annotated `@MainActor`) are themselves `Sendable` and
    /// remain valid.
    case custom(@Sendable @MainActor () async -> FlowNodeSnapshot?)

    /// Skip snapshot capture entirely.
    case disabled
}
