import SwiftUI

/// A dedicated region a node exposes as its drag-to-move grip.
///
/// When the node content contains its own drag-consuming view — a
/// `WKWebView`, `MKMapView`, `ScrollView`, or any `NSViewRepresentable`
/// / `UIViewRepresentable` with built-in pan gestures — the overlay
/// routes drags to that inner view while the node is active, and the
/// Canvas-level node-move gesture never fires. `FlowNodeDragHandle`
/// gives the caller a surface to carve out a region (a title bar, an
/// edge strip, a dedicated grip badge) whose drags move the node
/// instead, without disturbing the inner view's own gestures.
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
/// If the dragged node is part of a multi-selection the handle moves
/// every selected `isDraggable` node together, matching the
/// Canvas-level drag behavior. Undo is registered on gesture end.
///
/// In the rasterize path the node is drawn by `Canvas` via
/// `resolveSymbol` and gestures on individual SwiftUI views inside
/// that symbol are inert — in that phase the Canvas's own drag
/// gesture already hit-tests the node body, so move behavior is
/// unchanged. `FlowNodeDragHandle` is therefore a live-path escape
/// hatch; users see the same move behavior in both phases.
public struct FlowNodeDragHandle<NodeData: Sendable & Hashable, Content: View>: View {

    public let node: FlowNode<NodeData>
    public let context: NodeRenderContext
    private let content: () -> Content

    @Environment(\.flowNodeDragDispatcher) private var dispatcher
    @State private var startPositions: [String: CGPoint] = [:]

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
        content()
            .contentShape(Rectangle())
            .gesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                guard let dispatcher else { return }
                if startPositions.isEmpty {
                    startPositions = dispatcher.begin(node.id)
                }
                guard !startPositions.isEmpty else { return }
                dispatcher.update(startPositions, value.translation)
            }
            .onEnded { _ in
                guard let dispatcher else { return }
                guard !startPositions.isEmpty else { return }
                dispatcher.end(startPositions)
                startPositions = [:]
            }
    }
}

// MARK: - Dispatcher

/// Bundle of `FlowStore`-backed closures that `FlowNodeDragHandle`
/// invokes across a drag. Extracted so the handle view stays generic
/// over `NodeData` without knowing about `FlowStore`'s data parameter.
struct FlowNodeDragDispatcher {
    /// Snapshot positions of the nodes the drag will move — either
    /// the single dragged node or the full multi-selection if the
    /// dragged node is part of one.
    var begin: @MainActor (String) -> [String: CGPoint]
    /// Apply the current gesture translation (in screen points;
    /// normalized by viewport zoom inside) to every node captured by
    /// `begin`.
    var update: @MainActor ([String: CGPoint], CGSize) -> Void
    /// Finalize the move and register an undo action.
    var end: @MainActor ([String: CGPoint]) -> Void
}

private struct FlowNodeDragDispatcherKey: EnvironmentKey {
    static let defaultValue: FlowNodeDragDispatcher? = nil
}

extension EnvironmentValues {
    /// Closure bundle injected by `FlowCanvas` that lets
    /// `FlowNodeDragHandle` drive node moves through the owning
    /// `FlowStore` without knowing its `Data` generic parameter.
    var flowNodeDragDispatcher: FlowNodeDragDispatcher? {
        get { self[FlowNodeDragDispatcherKey.self] }
        set { self[FlowNodeDragDispatcherKey.self] = newValue }
    }
}
