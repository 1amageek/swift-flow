import SwiftUI

/// Hosts live node views (WKWebView, MKMapView, AVPlayerView, etc.)
/// on top of the Canvas.
///
/// Placed in a ZStack above the Canvas so each overlay is a real SwiftUI
/// view rather than a Canvas symbol, letting native representables retain
/// their own rendering loop, scroll views, video decoders, and input
/// handling.
///
/// Re-evaluates the caller-supplied `nodeContent` closure for every node
/// with `flowNodeRenderPhase = .live` injected, so any `LiveNode`
/// declared inside that closure automatically switches from its rasterize
/// branch to its live branch. Nodes that the activation predicate reports
/// as inactive stay mounted here but render at `opacity(0)` with hit
/// testing disabled — this preserves WKWebView / MKMapView identity
/// (page load state, scroll position, JS state, player state) across
/// active↔inactive toggles and eliminates the teardown/reload flicker
/// that happens when the subtree is conditionally removed.
///
/// The overlay layer itself does not paint any background, so empty space
/// between active nodes passes pointer events through to the Canvas
/// underneath.
struct LiveNodeOverlay<NodeData: Sendable & Hashable, Content: View>: View {

    let store: FlowStore<NodeData>
    let canvasSize: CGSize
    let nodeContent: (FlowNode<NodeData>, NodeRenderContext) -> Content
    let renderContext: (FlowNode<NodeData>) -> NodeRenderContext
    let activation: (FlowNode<NodeData>, FlowStore<NodeData>) -> Bool

    var body: some View {
        let viewport = store.viewport
        // Canvas expands each node's draw rect by FlowHandle.diameter / 2
        // so handles sitting on the border are not clipped. The live
        // overlay must mirror that expansion, otherwise the live view
        // and the rasterized view render at different sizes and the
        // active↔inactive transition "pops".
        let handleInset = FlowHandle.diameter / 2
        // Iterate back-to-front so later ZStack children (front-most nodes)
        // end up on top, matching the Canvas draw order. Identify the row
        // by `node.id` rather than the raw z-order index so reordering
        // preserves SwiftUI view identity (and with it, WKWebView /
        // MKMapView / AVPlayer instances already registered for each node).
        let orderedNodes = store.nodeIndicesFrontToBack.reversed().map { store.nodes[$0] }

        ZStack(alignment: .topLeading) {
            ForEach(orderedNodes, id: \.id) { node in
                let isActive = activation(node, store)
                let screenOrigin = viewport.canvasToScreen(node.position)
                nodeContent(node, renderContext(node))
                    .environment(\.flowNodeRenderPhase, .live)
                    .environment(\.flowNodeID, node.id)
                    .environment(\.isFlowNodeActive, isActive)
                    .frame(
                        width: node.size.width + handleInset * 2,
                        height: node.size.height + handleInset * 2
                    )
                    .scaleEffect(viewport.zoom, anchor: .topLeading)
                    .offset(
                        x: screenOrigin.x - handleInset * viewport.zoom,
                        y: screenOrigin.y - handleInset * viewport.zoom
                    )
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    }
}
