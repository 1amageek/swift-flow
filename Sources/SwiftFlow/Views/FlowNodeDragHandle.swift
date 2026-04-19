import SwiftUI

/// A dedicated region a node exposes as its drag-to-move grip.
///
/// When `nodeContent` hosts a view that consumes drags itself — a
/// `WKWebView`, `MKMapView`, `ScrollView`, or any native representable
/// with built-in pan gestures — the active `LiveNodeOverlay` row hands
/// drags to that inner view and the Canvas's node-move gesture never
/// fires. `FlowNodeDragHandle` carves a region (a title bar, an edge
/// strip, a dedicated grip badge) out of that overlay row where hit
/// testing is disabled, so drags fall straight through the overlay to
/// the Canvas underneath and the Canvas's own `primaryDragGesture`
/// moves the node — identical to dragging any plain node.
///
/// ```
/// FlowCanvas(store: store) { node, ctx in
///     VStack(spacing: 0) {
///         FlowNodeDragHandle(node: node, context: ctx) {
///             Text(node.data.title)
///                 .frame(maxWidth: .infinity, alignment: .leading)
///                 .padding(6)
///                 .background(.thinMaterial)
///         }
///         LiveNode(node: node, context: ctx) { MyWebView(url: node.data.url) }
///     }
///     .frame(width: node.size.width, height: node.size.height)
///     .padding(FlowHandle.diameter / 2)
///     .overlay { FlowNodeHandles(node: node, context: ctx) }
/// }
/// ```
///
/// `content` defaults to a transparent rectangle so an invisible grip
/// strip can be dropped in with just a frame:
///
/// ```
/// FlowNodeDragHandle(node: node, context: ctx)
///     .frame(height: 16)
/// ```
///
/// The handle intentionally does **not** implement its own
/// `DragGesture`. All drag behavior — multi-selection moves,
/// viewport-zoom normalization, undo registration — lives on the
/// Canvas side and flows through `FlowStore.moveNode`, so drags
/// triggered via the handle behave exactly like drags on a plain node.
///
/// In the rasterize path the node is drawn by `Canvas` via
/// `resolveSymbol` and SwiftUI gestures on the symbol contents are
/// inert; the Canvas's drag gesture hit-tests the node directly, so
/// move behavior is unchanged. `FlowNodeDragHandle` is therefore a
/// live-path escape hatch; users see the same move behavior in both
/// phases.
public struct FlowNodeDragHandle<NodeData: Sendable & Hashable, Content: View>: View {

    public let node: FlowNode<NodeData>
    public let context: NodeRenderContext
    private let content: () -> Content

    public init(
        node: FlowNode<NodeData>,
        context: NodeRenderContext,
        @ViewBuilder content: @escaping () -> Content = { Color.clear }
    ) {
        self.node = node
        self.context = context
        self.content = content
    }

    public var body: some View {
        // `.allowsHitTesting(false)` makes the handle subtree transparent
        // to hit testing inside the overlay, so drags that land on this
        // region fall through to the Canvas below and the Canvas's own
        // drag gesture handles the move. Content still renders normally.
        content()
            .allowsHitTesting(false)
    }
}
