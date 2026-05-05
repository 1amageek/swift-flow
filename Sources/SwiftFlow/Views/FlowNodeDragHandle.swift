import SwiftUI

/// Marks a region inside a `LiveNode` body as a pass-through drag area.
///
/// `LiveNode` mounts its content live on top of the Canvas so native
/// representables (`WKWebView`, `MKMapView`, `AVPlayerView`) keep their
/// own scrolling and gesture handling. Drags landing on those regions
/// are therefore consumed by the inner view and never reach the Canvas's
/// `primaryDragGesture`. Wrap a dedicated grip — typically a header bar
/// — in `FlowNodeDragHandle` so its area becomes hit-test transparent
/// and the Canvas drag underneath fires instead. The drag is then
/// dispatched through the same code path as a plain `FlowNode` drag, so
/// multi-selection moves, snap-to-grid, and undo behave identically.
///
/// ```swift
/// LiveNode(node: node) {
///     VStack(spacing: 0) {
///         FlowNodeDragHandle {
///             Text(node.data.title)
///                 .frame(maxWidth: .infinity, alignment: .leading)
///                 .padding(6)
///                 .background(.thinMaterial)
///         }
///         WebRepresentable(webView: webView, url: url)
///     }
/// }
/// ```
///
/// `content` defaults to a transparent rectangle so an invisible grip
/// strip can be dropped in with just a frame:
///
/// ```swift
/// FlowNodeDragHandle()
///     .frame(height: 16)
/// ```
///
/// `FlowNodeDragHandle` does **not** install its own gesture — it only
/// renders `content` with `.allowsHitTesting(false)`. The Canvas's
/// `primaryDragGesture` is the single drag implementation; this widget
/// just opens a window for it through the live overlay row.
public struct FlowNodeDragHandle<Content: View>: View {

    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content = { Color.clear }) {
        self.content = content
    }

    public var body: some View {
        content()
            .allowsHitTesting(false)
    }
}
