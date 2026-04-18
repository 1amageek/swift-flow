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
/// inside the viewport with `flowNodeRenderPhase = .live` injected, so
/// any `LiveNode` declared inside that closure automatically switches
/// from its rasterize branch to its live branch. Nodes the overlay
/// considers inactive stay mounted at `opacity(0)` with hit testing
/// disabled — this preserves WKWebView / MKMapView identity (page load
/// state, scroll position, JS state, player state) across active↔inactive
/// toggles and eliminates the teardown/reload flicker that happens when
/// the subtree is conditionally removed.
///
/// ## Two-phase deactivation
///
/// Activation "rendered" state is owned by
/// ``LiveNodeActivationCoordinator``, not by the raw predicate result.
/// When the predicate flips `true → false` the coordinator awaits the
/// `LiveNode`-registered capture handler before lowering `renderedActive`
/// — so the rasterize path has a fresh snapshot the instant the overlay
/// fades. The overlay reads `coordinator.renderedActive` for opacity / hit
/// testing, and feeds each body evaluation back in with `update(...)` so
/// predicate edges trigger the coordinator's transitions.
///
/// Off-screen nodes are culled from the overlay so we don't pay for
/// WKWebView page loads, SwiftUI subtree work, or capture costs that
/// nobody can see. Nodes scrolled back into view remount fresh and
/// re-seed their snapshot via `LiveNode`'s mount-time capture.
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
    let coordinator: LiveNodeActivationCoordinator

    /// Screen-pixel inflation applied to the visible canvas rect so nodes
    /// a short pan away are pre-mounted for smooth scroll-in.
    private static var preloadMargin: CGFloat { 200 }

    var body: some View {
        let viewport = store.viewport
        // Canvas expands each node's draw rect by FlowHandle.diameter / 2
        // so handles sitting on the border are not clipped. The live
        // overlay must mirror that expansion, otherwise the live view
        // and the rasterized view render at different sizes and the
        // active↔inactive transition "pops".
        let handleInset = FlowHandle.diameter / 2

        // Viewport cull: compute the canvas-coord rect currently on screen
        // (plus a preload margin), then keep only nodes whose frame
        // intersects it. Iterate back-to-front so later ZStack children
        // (front-most nodes) end up on top, matching the Canvas draw order.
        // Identify the row by `node.id` rather than the raw z-order index
        // so reordering preserves SwiftUI view identity (and with it,
        // WKWebView / MKMapView / AVPlayer instances already registered
        // for each node).
        let margin = Self.preloadMargin
        let topLeft = viewport.screenToCanvas(CGPoint(x: -margin, y: -margin))
        let bottomRight = viewport.screenToCanvas(
            CGPoint(x: canvasSize.width + margin, y: canvasSize.height + margin)
        )
        let visibleCanvasRect = CGRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )

        let visibleNodes = store.nodeIndicesFrontToBack
            .reversed()
            .compactMap { idx -> FlowNode<NodeData>? in
                let node = store.nodes[idx]
                let nodeRect = CGRect(origin: node.position, size: node.size)
                    .insetBy(dx: -handleInset, dy: -handleInset)
                return visibleCanvasRect.intersects(nodeRect) ? node : nil
            }

        ZStack(alignment: .topLeading) {
            ForEach(visibleNodes, id: \.id) { node in
                // Read the predicate as a read-only signal during body.
                // Mutation of `coordinator.renderedActive` happens only
                // inside `.onChange` below — writing to `@Observable`
                // state during body evaluation would invalidate our own
                // read of `renderedActive` and loop the render.
                let intent = activation(node, store)
                let isActive = coordinator.isRenderedActive(node.id)
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
                    .onChange(of: intent, initial: true) { _, newIntent in
                        coordinator.update(nodeID: node.id, intent: newIntent)
                    }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .environment(\.liveNodeActivationCoordinator, coordinator)
    }
}
