import SwiftUI

/// Hosts live node views (WKWebView, MKMapView, AVPlayerView, etc.)
/// on top of the Canvas.
///
/// Placed in a ZStack above the Canvas so each active node is a real
/// SwiftUI view rather than a Canvas symbol, letting native representables
/// retain their own rendering loop, scroll views, video decoders, and input
/// handling while visible.
///
/// ## Mount policy
///
/// A row is mounted here only when it is **active** (user is hovering or
/// selecting it) or **warming up** (no snapshot has been captured yet).
/// Everything else falls through to the Canvas `resolveSymbol` path,
/// which draws the stored snapshot image via `FlowNodeSnapshot` — cheap,
/// and the reason large flows with dozens of idle LiveNodes stay
/// responsive during pan/zoom. Mounting every visible LiveNode (even at
/// opacity 0) paid SwiftUI layout, transform, and `TimelineView` tick
/// costs for nodes the user couldn't see.
///
/// The warmup mount is what initially boots native representables —
/// WKWebView starts loading, MKMapView fetches tiles, AVPlayer prepares
/// an item — so their `.manual(capture:)` handler has a surface to pull
/// a snapshot from. Once `context.snapshot` is non-nil the row unmounts
/// and the Canvas takes over drawing.
///
/// Trade-off: WKWebView / MKMapView / AVPlayer identity is **not**
/// preserved by SwiftUI across deactivation — each activation remounts
/// the representable. Callers typically keep the underlying object alive
/// outside SwiftUI (e.g. a bag keyed by node ID) so remount reuses the
/// same instance, preserving page / region / playback state. For
/// SwiftUI-only `LiveNode`s the snapshot captured on deactivation keeps
/// the rasterize frame visually identical, so the swap is seamless.
///
/// ## Intent driver
///
/// The activation predicate is still evaluated for every viewport-visible
/// node (cheap — just a bool per node) and forwarded to the coordinator,
/// so predicate true-edges trigger the mount. Only the heavy subtree —
/// `nodeContent(...)` with `.live` phase injected — is gated on
/// `isRenderedActive`.
///
/// ## Plain-node pass-through
///
/// Not every active row contains a `LiveNode` — callers mix live nodes
/// with plain content (e.g. `.resizable` nodes). Rows that actually host
/// a `LiveNode` publish their ID via ``LiveNodePresenceKey``; rows absent
/// from the aggregated set keep `opacity = 0` and hit testing off, so
/// Canvas-level drag / selection gestures pass through to the node
/// underneath.
///
/// ## Two-phase deactivation
///
/// Activation "rendered" state is owned by
/// ``LiveNodeActivationCoordinator``, not by the raw predicate result.
/// When the predicate flips `true → false` the coordinator awaits the
/// `LiveNode`-registered capture handler before lowering `renderedActive`
/// — so the rasterize path has a fresh snapshot the instant the overlay
/// unmounts. The overlay reads `coordinator.renderedActive` to decide
/// which rows to mount, and feeds each body evaluation back in with
/// `update(...)` so predicate edges trigger the coordinator's transitions.
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
    let isViewportInteracting: Bool

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
        //
        // `.persistent` policy nodes are exempt from the cull once their
        // policy preference has reached the coordinator — keeping the
        // WKWebView / MKMapView mounted while panned off-screen avoids
        // the `removeFromSuperview` → CARemoteLayerClient stall on
        // re-entry. The first activation still has to come through the
        // viewport (the node must mount once to publish its policy), but
        // after that the row stays mounted regardless of viewport
        // position.
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

        let persistentNodeIDs = Set(
            coordinator.liveNodeMountPolicies
                .compactMap { $0.value == .persistent ? $0.key : nil }
        )

        let visibleNodes = store.nodeIndicesFrontToBack
            .reversed()
            .compactMap { idx -> FlowNode<NodeData>? in
                let node = store.nodes[idx]
                if persistentNodeIDs.contains(node.id) { return node }
                let nodeRect = CGRect(origin: node.position, size: node.size)
                    .insetBy(dx: -handleInset, dy: -handleInset)
                return visibleCanvasRect.intersects(nodeRect) ? node : nil
            }

        // Bootstrap gate: skip mounting rows until the coordinator has
        // received at least one preference cycle. Without this, a
        // `.persistent` row would mount on the very first frame
        // (before the registrar pass below has propagated the
        // policy) and its WKWebView would land at opacity 0 — long
        // enough for the WebContent compositor to go dormant.
        // Skipping here costs exactly one frame; on frame two the
        // policy is in hand and the WKWebView opens at opacity 1
        // from the start.
        let bootstrapped = coordinator.hasReceivedFirstPreferenceCycle
        ZStack(alignment: .topLeading) {
            // Registrar pass: walk every node in the store at 0×0 /
            // opacity 0 to drive each LiveNode's outer `.preference`
            // emission. This is the only reliable place to feed the
            // coordinator's presence / mount-policy maps:
            //
            // - The Canvas's `symbols:` block does not propagate
            //   `PreferenceKey` values to its outer modifier scope
            //   (and may not even evaluate symbols whose ID
            //   `drawNodes` doesn't resolve — `.persistent` nodes
            //   short-circuit drawing entirely, so their symbol body
            //   never runs).
            // - The visible-rows ForEach below is viewport-culled and
            //   gated on `bootstrapped`, so it cannot bootstrap
            //   itself.
            //
            // The registrar evaluates `nodeContent` for every node,
            // but at zero size with hit-testing off and opacity 0,
            // so the user's card body, handles, and decorations
            // build their view tree without producing any pixels.
            // LiveNode in `.rasterize` phase renders its snapshot
            // image (or a `FlowDefaultPlaceholder`) — both cheap.
            ForEach(store.nodes) { node in
                let context = renderContext(node)
                nodeContent(node, context)
                    .environment(\.flowNodeRenderPhase, .rasterize)
                    .environment(\.flowNodeID, node.id)
                    .environment(
                        \.liveNodeEnvironment,
                        LiveNodeEnvironment(
                            id: node.id,
                            size: node.size,
                            snapshot: context.snapshot
                        )
                    )
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .allowsHitTesting(false)
                    // Mark this node as evaluated this cycle. The
                    // coordinator pairs the aggregated set with the
                    // presence / policy preferences below so an
                    // evaluated-but-absent id is treated as a *removal*
                    // from `liveNodeIDs` rather than a transient empty
                    // cycle that must be ignored.
                    .preference(key: EvaluatedNodeIDsKey.self, value: [node.id])
            }

            ForEach(bootstrapped ? visibleNodes : [], id: \.id) { node in
                // Evaluate the activation predicate for every visible
                // node (cheap — just a bool) and forward the edge to the
                // coordinator. This is what promotes a node into
                // `renderedActive` on first hover/select. Mutation of
                // `@Observable` state happens inside `.onChange`, never
                // during body, to avoid self-invalidating the render.
                //
                // `displayActive` reads raw intent OR renderedActive —
                // not gated on `liveNodeIDs`, because the presence
                // preference can transiently drop entries during a
                // re-render (LiveNode's outer `if liveNodeEnvironment`
                // branch, ForEach rebuild) and a single empty cycle
                // would tear the row down even though the user still
                // wants the node active.
                //
                // `isLiveNode` gates whether the row mounts at all:
                // plain (non-LiveNode) rows must never mount here
                // because the Canvas `resolveSymbol` path already draws
                // them. Without this guard, plain rows go through the
                // warmup branch (`snapshot == nil` is permanent for
                // them) and end up double-drawn at opacity 1 alongside
                // the Canvas.
                let intent = activation(node, store)
                let renderedActive = coordinator.isRenderedActive(node.id)
                let mountPolicy = coordinator.mountPolicy(for: node.id)
                let displayActive = intent || renderedActive
                let isLiveNode = coordinator.liveNodeIDs.contains(node.id)
                LiveNodeOverlayRow(
                    node: node,
                    viewport: viewport,
                    handleInset: handleInset,
                    isLiveNode: isLiveNode,
                    isRenderedActive: displayActive,
                    shouldShow: displayActive && !isViewportInteracting,
                    isHittable: displayActive && !isViewportInteracting,
                    isViewportInteracting: isViewportInteracting,
                    mountPolicy: mountPolicy,
                    renderContext: renderContext(node),
                    nodeContent: nodeContent
                )
                .onChange(of: intent, initial: true) { _, newIntent in
                    coordinator.update(nodeID: node.id, intent: newIntent)
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .environment(\.liveNodeActivationCoordinator, coordinator)
        // The registrar pass evaluates every node in the store, so this
        // cycle's union is the authoritative scope for the presence /
        // policy reconciliations below. An empty cycle (transient
        // ForEach rebuild) is dropped inside the coordinator so it
        // cannot erase prior decisions.
        .onPreferenceChange(EvaluatedNodeIDsKey.self) { [coordinator, store] evaluated in
            Task { @MainActor in
                let storeNodeIDs = Set(store.nodes.map(\.id))
                coordinator.applyEvaluatedNodeIDs(evaluated, storeNodeIDs: storeNodeIDs)
            }
        }
        .onPreferenceChange(LiveNodePresenceKey.self) { [coordinator, store] ids in
            // Within the latest evaluated scope this cycle's presence
            // set is authoritative — that is what drops a
            // conditionally-disappeared LiveNode from `liveNodeIDs`.
            // Outside the scope prior state carries over, so a partial
            // cycle cannot demote untouched live nodes.
            Task { @MainActor in
                let storeNodeIDs = Set(store.nodes.map(\.id))
                coordinator.applyLiveNodePresence(ids, storeNodeIDs: storeNodeIDs)
            }
        }
        .onPreferenceChange(LiveNodeMountPolicyKey.self) { [coordinator, store] policies in
            // Mirror the presence reconciliation: within scope assign,
            // outside scope keep prior, finally prune to storeNodeIDs.
            Task { @MainActor in
                let storeNodeIDs = Set(store.nodes.map(\.id))
                coordinator.applyLiveNodeMountPolicies(policies, storeNodeIDs: storeNodeIDs)
            }
        }
    }
}

/// One row in the overlay. Mounts `nodeContent` in the `.live` phase for
/// two reasons:
///
/// - **Active**: the coordinator says the user is hovering/selecting this
///   node, so the live view must replace the Canvas snapshot.
/// - **Warmup**: the node has no snapshot yet, so the live view must mount
///   invisibly long enough to produce one — this is the only path that
///   boots up native representables (WKWebView load, MKMapView tile
///   fetch, AVPlayer item setup) whose `.manual(capture:)` handler cannot
///   synthesize a snapshot without the live view being in the view
///   hierarchy. Once `context.snapshot` is populated the row unmounts and
///   the Canvas `resolveSymbol` path takes over drawing.
///
/// Rows that are neither active nor warming collapse to a zero-size
/// spacer, so the Canvas rasterize path is the sole drawer for idle
/// LiveNodes.
private struct LiveNodeOverlayRow<NodeData: Sendable & Hashable, Content: View>: View {

    let node: FlowNode<NodeData>
    let viewport: Viewport
    let handleInset: CGFloat
    /// Whether `nodeContent` actually embeds a `LiveNode`. Sourced from
    /// the coordinator's presence set (registrar pass publishes it via
    /// ``LiveNodePresenceKey``). When `false`, the row never mounts —
    /// the Canvas `resolveSymbol` path is the sole drawer. Without this
    /// gate, the warmup branch (`snapshot == nil` is permanent for plain
    /// rows) would force opacity 1 and produce a double draw on top of
    /// the Canvas.
    let isLiveNode: Bool
    let isRenderedActive: Bool
    let shouldShow: Bool
    /// Whether this row should accept hit tests. Combined with the
    /// per-row warmup gate below, an idle row is always hit-test
    /// transparent and the Canvas is the sole interaction target. For
    /// plain rows the `isLiveNode == false` early return means this is
    /// never consulted.
    let isHittable: Bool
    let isViewportInteracting: Bool
    let mountPolicy: LiveNodeMountPolicy
    let renderContext: NodeRenderContext
    let nodeContent: (FlowNode<NodeData>, NodeRenderContext) -> Content

    /// Mount decision depends on the per-node mount policy:
    ///
    /// - `.onActivation` (default) and `.remountOnActivation`: mount
    ///   while active OR while the node still has no snapshot — the
    ///   latter lets native representables load their content and seed
    ///   the snapshot, after which the row unmounts and the Canvas
    ///   draws from the snapshot instead. Both policies also unmount
    ///   while the user is panning or zooming so the Canvas poster
    ///   takes over for the duration of the gesture; this avoids
    ///   per-frame SwiftUI re-layout for the live subtree.
    /// - `.persistent`: stay mounted regardless of activation OR
    ///   viewport interaction. Required for native representables
    ///   backed by a separate process — their `removeFromSuperview`
    ///   propagates `viewDidMoveToWindow(nil)` into the remote-layer
    ///   subtree and stalls the CARemoteLayerClient / CAMetalLayer
    ///   pipeline; keeping the row mounted avoids that detach entirely.
    ///   While the user is panning or zooming the row's `shouldShow`
    ///   and `isHittable` already drop to `false` from the owning
    ///   overlay, so Canvas takes over drawing/hit-testing without
    ///   tearing down the underlying native view.
    private var shouldMount: Bool {
        // Plain (non-LiveNode) rows never mount: the Canvas symbol pass
        // already draws them, and the warmup branch below would otherwise
        // force a permanent opacity-1 mount because `snapshot == nil` is
        // load-bearing only for LiveNode-backed rows.
        guard isLiveNode else {
            return false
        }

        switch mountPolicy {
        case .onActivation, .remountOnActivation:
            // Unmount during pan/zoom so the live subtree is not subjected
            // to per-frame re-layout — the Canvas poster covers the
            // gesture window.
            if isViewportInteracting {
                return false
            }
            return isRenderedActive || renderContext.snapshot == nil

        case .persistent:
            // The whole point of `.persistent` is to never detach. The
            // body's opacity / hit-testing already collapse during
            // viewport interaction (via shouldShow / isHittable), so
            // Canvas owns the gesture window without disturbing the
            // underlying CARemoteLayer pipeline.
            return true
        }
    }

    var body: some View {
        if shouldMount {
            let screenOrigin = viewport.canvasToScreen(node.position)
            // The warmup window is the only time a `.native` LiveNode
            // gets to seed its first snapshot. Native policies do not
            // self-seed (`seedOnAppear: false`), and the Canvas poster
            // takes over once a snapshot exists — so until one lands
            // we mount the live subtree visibly and treat it as
            // active, which lets `MKMapView` / `WKWebView` kick their
            // tile / load pipeline.
            //
            // The row itself stays hit-test enabled so native
            // representables (`WKWebView`, `MKMapView`, `AVPlayerView`)
            // keep their own scroll / pan / tap handling. To make the
            // node draggable, the caller wraps the grip region (a
            // header bar, etc.) in ``FlowNodeDragHandle``, which marks
            // that region with `.allowsHitTesting(false)` so the
            // Canvas's `primaryDragGesture` underneath captures the
            // drag — the same code path as a plain `FlowNode` drag.
            let isWarmingUp = renderContext.snapshot == nil
            let effectiveActive = isRenderedActive || isWarmingUp
            let effectiveVisible = shouldShow || isWarmingUp
            // Hit testing stays off during warmup so the user can't
            // interact with a node that isn't user-active yet — Canvas
            // gestures (drag-to-move, marquee select) pass through.
            // For non-LiveNode rows `snapshot` is always nil → warmup
            // never ends → row stays hit-test transparent forever, so
            // the Canvas remains the sole drag target for plain nodes.
            let effectiveHittable = isHittable && !isWarmingUp

            nodeContent(node, renderContext)
                .environment(\.flowNodeRenderPhase, .live)
                .environment(\.flowNodeID, node.id)
                .environment(\.isFlowNodeActive, effectiveActive)
                .environment(
                    \.liveNodeEnvironment,
                    LiveNodeEnvironment(
                        id: node.id,
                        size: node.size,
                        snapshot: renderContext.snapshot
                    )
                )
                .frame(
                    width: node.size.width + handleInset * 2,
                    height: node.size.height + handleInset * 2
                )
                .scaleEffect(viewport.zoom, anchor: .topLeading)
                .offset(
                    x: screenOrigin.x - handleInset * viewport.zoom,
                    y: screenOrigin.y - handleInset * viewport.zoom
                )
                .opacity(effectiveVisible ? 1 : 0)
                .allowsHitTesting(effectiveHittable)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }
}
