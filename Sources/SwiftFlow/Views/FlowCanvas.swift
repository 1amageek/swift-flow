import SwiftUI
import UniformTypeIdentifiers

public struct FlowCanvas<
    NodeData: Sendable & Hashable,
    NodeView: View
>: View {

    @Bindable var store: FlowStore<NodeData>
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.undoManager) private var undoManager

    private let nodeContentBuilder: (FlowNode<NodeData>, NodeRenderContext) -> NodeView
    private let edgeContentBuilder: ((FlowEdge, EdgeGeometry) -> AnyView)?
    private var nodeAccessoryBuilder: ((FlowNode<NodeData>) -> AnyView)?
    private var edgeAccessoryBuilder: ((FlowEdge) -> AnyView)?
    private var nodeAccessoryPlacement: (FlowNode<NodeData>) -> AccessoryPlacement = { _ in .top }
    private var edgeAccessoryPlacement: AccessoryPlacement = .top
    private var accessoryAnimation: Animation? = .spring(duration: 0.25, bounce: 0.05)
    private var liveNodeActivationPredicate: (FlowNode<NodeData>, FlowStore<NodeData>) -> Bool = { node, store in
        store.selectedNodeIDs.contains(node.id) || store.hoveredNodeID == node.id
    }
    private var registeredDropTypes: [String] = []
    private var dropHandler: (@MainActor @Sendable (_ event: CanvasDropEvent) -> Bool)? = nil

    // MARK: - Init: Default

    public init(store: FlowStore<NodeData>) where NodeView == DefaultNodeContent<NodeData> {
        self.store = store
        self.nodeContentBuilder = { node, context in
            DefaultNodeContent(node: node, context: context)
        }
        self.edgeContentBuilder = nil
        self.nodeAccessoryBuilder = nil
        self.edgeAccessoryBuilder = nil
    }

    // MARK: - Init: Custom nodes

    public init(
        store: FlowStore<NodeData>,
        @ViewBuilder nodeContent: @escaping (FlowNode<NodeData>, NodeRenderContext) -> NodeView
    ) {
        self.store = store
        self.nodeContentBuilder = nodeContent
        self.edgeContentBuilder = nil
        self.nodeAccessoryBuilder = nil
        self.edgeAccessoryBuilder = nil
    }

    // MARK: - Init: Custom nodes + custom edges

    public init<EdgeView: View>(
        store: FlowStore<NodeData>,
        @ViewBuilder nodeContent: @escaping (FlowNode<NodeData>, NodeRenderContext) -> NodeView,
        @ViewBuilder edgeContent: @escaping (FlowEdge, EdgeGeometry) -> EdgeView
    ) {
        self.store = store
        self.nodeContentBuilder = nodeContent
        self.edgeContentBuilder = { edge, geometry in AnyView(edgeContent(edge, geometry)) }
        self.nodeAccessoryBuilder = nil
        self.edgeAccessoryBuilder = nil
    }

    // MARK: - Init: Default nodes + custom edges

    public init<EdgeView: View>(
        store: FlowStore<NodeData>,
        @ViewBuilder edgeContent: @escaping (FlowEdge, EdgeGeometry) -> EdgeView
    ) where NodeView == DefaultNodeContent<NodeData> {
        self.store = store
        self.nodeContentBuilder = { node, context in
            DefaultNodeContent(node: node, context: context)
        }
        self.edgeContentBuilder = { edge, geometry in AnyView(edgeContent(edge, geometry)) }
        self.nodeAccessoryBuilder = nil
        self.edgeAccessoryBuilder = nil
    }

    // MARK: - Accessory Modifiers

    /// Attaches a view that appears near a selected node.
    ///
    /// The view is shown only when exactly one node is selected and
    /// dismissed automatically when selection clears.
    /// - Parameters:
    ///   - placement: Direction relative to the node center. Flips if clipped.
    ///   - animation: Appear/disappear animation. Pass `nil` to disable.
    ///   - content: A view builder receiving the selected node.
    public func nodeAccessory<A: View>(
        placement: AccessoryPlacement = .top,
        animation: Animation? = .spring(duration: 0.25, bounce: 0.05),
        @ViewBuilder content: @escaping (FlowNode<NodeData>) -> A
    ) -> FlowCanvas {
        var copy = self
        copy.nodeAccessoryBuilder = { node in AnyView(content(node)) }
        copy.nodeAccessoryPlacement = { _ in placement }
        copy.accessoryAnimation = animation
        return copy
    }

    /// Attaches a view that appears near a selected node, with per-node
    /// placement determined by the `placement` closure.
    public func nodeAccessory<A: View>(
        placement: @escaping (FlowNode<NodeData>) -> AccessoryPlacement,
        animation: Animation? = .spring(duration: 0.25, bounce: 0.05),
        @ViewBuilder content: @escaping (FlowNode<NodeData>) -> A
    ) -> FlowCanvas {
        var copy = self
        copy.nodeAccessoryBuilder = { node in AnyView(content(node)) }
        copy.nodeAccessoryPlacement = placement
        copy.accessoryAnimation = animation
        return copy
    }

    /// Attaches a view that appears near a selected edge.
    ///
    /// The view is shown only when exactly one edge is selected and
    /// dismissed automatically when selection clears.
    /// - Parameters:
    ///   - placement: Direction relative to the edge midpoint. Flips if clipped.
    ///   - animation: Appear/disappear animation. Pass `nil` to disable.
    ///   - content: A view builder receiving the selected edge.
    public func edgeAccessory<A: View>(
        placement: AccessoryPlacement = .top,
        animation: Animation? = .spring(duration: 0.25, bounce: 0.05),
        @ViewBuilder content: @escaping (FlowEdge) -> A
    ) -> FlowCanvas {
        var copy = self
        copy.edgeAccessoryBuilder = { edge in AnyView(content(edge)) }
        copy.edgeAccessoryPlacement = placement
        copy.accessoryAnimation = animation
        return copy
    }

    // MARK: - Live Node Activation

    /// Overrides the predicate that decides which nodes are active for the
    /// live overlay layer.
    ///
    /// The default predicate returns `true` when the node is selected or
    /// hovered. Apps that want a different policy (e.g., keep a node live
    /// while a media player is playing, or suspend live rendering during a
    /// connection draft) should supply their own.
    public func liveNodeActivation(
        _ isActive: @escaping (FlowNode<NodeData>, FlowStore<NodeData>) -> Bool
    ) -> FlowCanvas {
        var copy = self
        copy.liveNodeActivationPredicate = isActive
        return copy
    }

    // MARK: - Drop Destination

    /// Configures the canvas as a drop destination.
    ///
    /// - Parameters:
    ///   - types: The UTType identifiers the canvas should accept. On macOS these are
    ///     passed to `registerForDraggedTypes`. Custom UTTypes (declared with `exportedAs`)
    ///     must be listed here explicitly.
    ///   - action: Called for each drag phase. Return `true` to accept the drop target
    ///     (the library highlights the node/edge with `isDropTarget = true`), `false` to reject.
    ///     For `.exited`, the return value is ignored.
    @discardableResult
    public func dropDestination(
        for types: [UTType],
        action: @escaping (_ phase: DropPhase) -> Bool
    ) -> FlowCanvas {
        var copy = self
        copy.registeredDropTypes = types.map(\.identifier)
        let storeRef = self.store
        copy.dropHandler = { event in
            switch event {
            case .updated(let providers, let screenLocation):
                let canvasPoint = storeRef.viewport.screenToCanvas(screenLocation)
                let nodeID = storeRef.hitTestNode(at: canvasPoint)
                let edgeID = nodeID == nil ? storeRef.hitTestEdge(at: canvasPoint) : nil

                let target: DropTarget
                if let nodeID {
                    target = .node(nodeID)
                } else if let edgeID {
                    target = .edge(edgeID)
                } else {
                    target = .canvas
                }

                storeRef.setHoveredNode(nodeID)

                let accepted = action(.updated(providers, canvasPoint, target))
                storeRef.setDropTargetNode(accepted ? nodeID : nil)
                storeRef.setDropTargetEdge(accepted ? edgeID : nil)
                return accepted

            case .exited:
                storeRef.setHoveredNode(nil)
                storeRef.setDropTargetNode(nil)
                storeRef.setDropTargetEdge(nil)
                _ = action(.exited)
                return false

            case .performed(let providers, let screenLocation):
                let canvasPoint = storeRef.viewport.screenToCanvas(screenLocation)
                let nodeID = storeRef.hitTestNode(at: canvasPoint)
                let edgeID = nodeID == nil ? storeRef.hitTestEdge(at: canvasPoint) : nil

                let target: DropTarget
                if let nodeID {
                    target = .node(nodeID)
                } else if let edgeID {
                    target = .edge(edgeID)
                } else {
                    target = .canvas
                }

                storeRef.setDropTargetNode(nil)
                storeRef.setDropTargetEdge(nil)
                return action(.performed(providers, canvasPoint, target))
            }
        }
        return copy
    }

    // MARK: - Drag State

    @State private var dragMode: CanvasDragMode = .none
    #if os(macOS)
    @State private var pushedDragCursor: DragCursorKind?
    #endif

    // MARK: - Magnify State

    @State private var lastMagnification: CGFloat = 1.0

    // MARK: - Double-Tap Detection

    @State private var doubleTapDetector = DoubleTapDetector()

    // MARK: - Live Node Activation Coordinator

    /// Owns the two-phase deactivation state shared by `LiveNode`
    /// (registers capture handlers), `LiveNodeOverlay` (reads
    /// `renderedActive` for opacity/hit testing), and `drawNodes` (skips
    /// drawing nodes whose live overlay is covering them).
    @State private var liveNodeActivationCoordinator = LiveNodeActivationCoordinator()

    // MARK: - Viewport Interaction

    /// Latches `true` while the user is actively panning or zooming the
    /// canvas. While set, `LiveNodeOverlay` unmounts its live rows and
    /// the Canvas's `drawNodes` keeps drawing every node from its
    /// rasterized poster — native representables (`MKMapView`,
    /// `WKWebView`) are spared a tile / re-layout pass per gesture
    /// frame, which is otherwise the dominant cost during pan / zoom.
    @State private var isViewportInteracting = false

    /// Trailing-edge timer that flips `isViewportInteracting` back to
    /// `false` once the gesture stream goes quiet. macOS scroll wheel
    /// and trackpad magnify deliver discrete events with no end signal,
    /// so we drop interaction state after a short idle window.
    @State private var viewportInteractionResetTask: Task<Void, Never>?

    public var body: some View {
        GeometryReader { geometry in
            canvasBody(in: geometry.size)
        }
    }

    @ViewBuilder
    private func canvasBody(in size: CGSize) -> some View {
        let canvasView = Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, canvasSize in
            drawBackground(context: &context, canvasSize: canvasSize)
            if edgeContentBuilder != nil {
                drawEdgesViaSymbols(context: &context, canvasSize: canvasSize)
            } else {
                drawEdgesViaGraphicsContext(context: &context, canvasSize: canvasSize)
            }
            drawNodes(context: &context, canvasSize: canvasSize)
            drawSelectionRect(context: &context)
            drawConnectionDraft(context: &context, canvasSize: canvasSize)
        } symbols: {
            ForEach(store.nodes) { node in
                let context = nodeRenderContext(for: node)
                nodeContentBuilder(node, context)
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
                    .tag(node.id)
            }
            if let edgeContentBuilder {
                ForEach(store.edges) { edge in
                    edgeSymbolView(edge: edge, builder: edgeContentBuilder)
                }
            }
        }
        .gesture(primaryDragGesture)
        #if os(iOS)
        .gesture(magnifyGesture)
        #endif
        #if os(macOS)
        .gesture(
            SpatialTapGesture()
                .modifiers(.command)
                .onEnded { value in
                    handleTap(at: value.location, isAdditive: true)
                }
        )
        #endif
        .onTapGesture { location in
            handleTap(at: location, isAdditive: false)
        }
        .onDisappear {
            viewportInteractionResetTask?.cancel()
            viewportInteractionResetTask = nil
            isViewportInteracting = false
            store.cancelNodeDrag()

            #if os(macOS)
            releaseDragCursorIfNeeded()
            #endif
        }
        .focusable()
        .onAppear {
            store.undoManager = undoManager
        }
        .onChange(of: undoManager) { _, newValue in
            store.undoManager = newValue
        }
        // Preference collection lives inside `LiveNodeOverlay`'s
        // hidden registrar pass — Canvas's `symbols:` block does not
        // reliably propagate PreferenceKey values to this outer
        // scope, and it lazy-skips evaluating symbols that
        // `drawNodes` doesn't resolve, so attaching the listener
        // here would deadlock the bootstrap gate.

        let hasAccessory = nodeAccessoryBuilder != nil || edgeAccessoryBuilder != nil
        let snapshotWriter: @MainActor (String, FlowNodeSnapshot) -> Void = { [store] id, snap in
            store.setNodeSnapshot(snap, for: id)
        }
        #if os(macOS)
        let hostView = CanvasHostView(
            onScroll: { delta, location in
                guard store.configuration.panEnabled else { return }
                beginViewportInteraction()
                store.pan(by: delta)
                scheduleEndViewportInteraction()
            },
            onMagnify: { magnification, location in
                beginViewportInteraction()
                store.zoom(by: 1 + magnification, anchor: location)
                scheduleEndViewportInteraction()
            },
            cursorAt: { location in
                switch dragMode {
                case .nodeMove:
                    return .closedHand
                case .connection:
                    return .crosshair
                case .selection, .none:
                    break
                }

                let canvasPoint = store.viewport.screenToCanvas(location)
                let nodeID = store.hitTestNode(at: canvasPoint)
                store.setHoveredNode(nodeID)

                if store.hitTestHandle(at: canvasPoint) != nil {
                    return .crosshair
                }
                if let nodeID,
                   let node = store.nodeLookup[nodeID],
                   node.isDraggable {
                    return .openHand
                }
                return .arrow
            },
            onMouseExited: {
                store.setHoveredNode(nil)
            },
            registeredDropTypes: registeredDropTypes,
            onDrop: dropHandler,
            onKeyDown: { _ in
                return false
            }
        ) {
            canvasView
        }

        ZStack {
            hostView
            LiveNodeOverlay(
                store: store,
                canvasSize: size,
                nodeContent: nodeContentBuilder,
                renderContext: { node in nodeRenderContext(for: node) },
                activation: liveNodeActivationPredicate,
                coordinator: liveNodeActivationCoordinator,
                isViewportInteracting: isViewportInteracting
            )
            if hasAccessory {
                AccessoryOverlay(
                    store: store,
                    canvasSize: size,
                    nodeAccessoryBuilder: nodeAccessoryBuilder,
                    edgeAccessoryBuilder: edgeAccessoryBuilder,
                    nodeAccessoryPlacement: nodeAccessoryPlacement,
                    edgeAccessoryPlacement: edgeAccessoryPlacement,
                    animation: accessoryAnimation
                )
            }
        }
        .environment(\.flowLiveNodeSnapshotWriter, snapshotWriter)
        #else
        let hostView = CanvasHostView(
            onPan: { delta in
                guard store.configuration.panEnabled else { return }
                beginViewportInteraction()
                store.pan(by: delta)
                scheduleEndViewportInteraction()
            },
            registeredDropTypes: registeredDropTypes,
            onDrop: dropHandler
        ) {
            canvasView
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let canvasPoint = store.viewport.screenToCanvas(location)
                store.setHoveredNode(store.hitTestNode(at: canvasPoint))
            case .ended:
                store.setHoveredNode(nil)
            @unknown default:
                break
            }
        }

        ZStack {
            hostView
            LiveNodeOverlay(
                store: store,
                canvasSize: size,
                nodeContent: nodeContentBuilder,
                renderContext: { node in nodeRenderContext(for: node) },
                activation: liveNodeActivationPredicate,
                coordinator: liveNodeActivationCoordinator,
                isViewportInteracting: isViewportInteracting
            )
            if hasAccessory {
                AccessoryOverlay(
                    store: store,
                    canvasSize: size,
                    nodeAccessoryBuilder: nodeAccessoryBuilder,
                    edgeAccessoryBuilder: edgeAccessoryBuilder,
                    nodeAccessoryPlacement: nodeAccessoryPlacement,
                    edgeAccessoryPlacement: edgeAccessoryPlacement,
                    animation: accessoryAnimation
                )
            }
        }
        .environment(\.flowLiveNodeSnapshotWriter, snapshotWriter)
        #endif
    }

    // MARK: - Drawing: Background

    private func drawBackground(context: inout GraphicsContext, canvasSize: CGSize) {
        let style = store.configuration.backgroundStyle
        guard style.pattern != .none else { return }

        let viewport = store.viewport

        // Multi-scale background: when zoomed out, step up to a coarser spacing
        // so the pattern stays visible at every zoom level.
        let minScreenSpacing: CGFloat = 10
        let scaleStep: CGFloat = 5

        // Find the coarsest level whose screen spacing >= minScreenSpacing
        var levelSpacing = style.spacing
        while levelSpacing * viewport.zoom < minScreenSpacing {
            levelSpacing *= scaleStep
        }

        // Draw two levels: coarse (major) then fine, with crossfade.
        // The coarse level is always fully opaque when visible.
        let coarseSpacing = levelSpacing * scaleStep
        let coarseScreenSpacing = coarseSpacing * viewport.zoom
        if coarseScreenSpacing >= minScreenSpacing {
            drawBackgroundPattern(
                context: &context, canvasSize: canvasSize,
                style: style, viewport: viewport,
                spacing: coarseSpacing, alpha: 1.0
            )
        }

        // Fine level fades in as its screen spacing grows away from the threshold
        let fineScreenSpacing = levelSpacing * viewport.zoom
        let fadeMin: CGFloat = minScreenSpacing
        let fadeMax: CGFloat = minScreenSpacing * 1.5
        let t = min(1.0, max(0.0, (fineScreenSpacing - fadeMin) / (fadeMax - fadeMin)))
        let fineAlpha = 0.4 + 0.6 * t
        if fineAlpha > 0.01 {
            drawBackgroundPattern(
                context: &context, canvasSize: canvasSize,
                style: style, viewport: viewport,
                spacing: levelSpacing, alpha: fineAlpha
            )
        }
    }

    private func drawBackgroundPattern(
        context: inout GraphicsContext,
        canvasSize: CGSize,
        style: BackgroundStyle,
        viewport: Viewport,
        spacing: CGFloat,
        alpha: CGFloat
    ) {
        let topLeft = viewport.screenToCanvas(.zero)
        let bottomRight = viewport.screenToCanvas(CGPoint(x: canvasSize.width, y: canvasSize.height))

        let startX = (topLeft.x / spacing).rounded(.down) * spacing
        let startY = (topLeft.y / spacing).rounded(.down) * spacing
        let endX = (bottomRight.x / spacing).rounded(.up) * spacing
        let endY = (bottomRight.y / spacing).rounded(.up) * spacing

        let color = style.color.opacity(alpha)

        switch style.pattern {
        case .none:
            break

        case .grid:
            var gridPath = Path()

            var x = startX
            while x <= endX {
                let screenX = x * viewport.zoom + viewport.offset.x
                gridPath.move(to: CGPoint(x: screenX, y: 0))
                gridPath.addLine(to: CGPoint(x: screenX, y: canvasSize.height))
                x += spacing
            }

            var y = startY
            while y <= endY {
                let screenY = y * viewport.zoom + viewport.offset.y
                gridPath.move(to: CGPoint(x: 0, y: screenY))
                gridPath.addLine(to: CGPoint(x: canvasSize.width, y: screenY))
                y += spacing
            }

            context.stroke(
                gridPath,
                with: .color(color),
                style: StrokeStyle(lineWidth: style.lineWidth)
            )

        case .dot:
            var dotPath = Path()
            let radius = style.dotRadius

            var x = startX
            while x <= endX {
                var y = startY
                while y <= endY {
                    let screenX = x * viewport.zoom + viewport.offset.x
                    let screenY = y * viewport.zoom + viewport.offset.y
                    dotPath.addEllipse(in: CGRect(
                        x: screenX - radius,
                        y: screenY - radius,
                        width: radius * 2,
                        height: radius * 2
                    ))
                    y += spacing
                }
                x += spacing
            }

            context.fill(dotPath, with: .color(color))
        }
    }

    // MARK: - Drawing: Edges (GraphicsContext batch)

    private func drawEdgesViaGraphicsContext(context: inout GraphicsContext, canvasSize: CGSize) {
        let style = store.configuration.edgeStyle
        let viewport = store.viewport

        var normalPath = Path()
        var selectedPath = Path()
        var animatedPath = Path()
        var dropTargetPath = Path()
        var labelsToDraw: [(String, CGPoint)] = []

        for edge in store.edges {
            let sourceInfo = store.handleInfo(nodeID: edge.sourceNodeID, handleID: edge.sourceHandleID)
            let targetInfo = store.handleInfo(nodeID: edge.targetNodeID, handleID: edge.targetHandleID)
            guard let source = sourceInfo, let target = targetInfo else { continue }

            // Viewport culling (screen space)
            let screenSource = viewport.canvasToScreen(source.point)
            let screenTarget = viewport.canvasToScreen(target.point)
            let margin: CGFloat = 100
            if (screenSource.x < -margin && screenTarget.x < -margin) ||
               (screenSource.x > canvasSize.width + margin && screenTarget.x > canvasSize.width + margin) ||
               (screenSource.y < -margin && screenTarget.y < -margin) ||
               (screenSource.y > canvasSize.height + margin && screenTarget.y > canvasSize.height + margin) {
                continue
            }

            let calculator = FlowStore<NodeData>.pathCalculator(for: edge.pathType)
            let edgePath = calculator.path(
                from: source.point, sourcePosition: source.position,
                to: target.point, targetPosition: target.position
            )

            let transformed = transformedPath(edgePath.path, viewport: viewport)

            if edge.isDropTarget {
                dropTargetPath.addPath(transformed)
            } else if edge.isSelected {
                selectedPath.addPath(transformed)
            } else if store.animatedEdgeIDs.contains(edge.id) {
                animatedPath.addPath(transformed)
            } else {
                normalPath.addPath(transformed)
            }

            if let label = edge.label {
                let screenPos = viewport.canvasToScreen(edgePath.labelPosition)
                labelsToDraw.append((label, screenPos))
            }
        }

        // Batch stroke
        if !normalPath.isEmpty {
            let strokeStyle = StrokeStyle(lineWidth: style.lineWidth, dash: style.dashPattern)
            context.stroke(normalPath, with: .color(style.strokeColor), style: strokeStyle)
        }
        if !animatedPath.isEmpty {
            let strokeStyle = StrokeStyle(lineWidth: style.lineWidth, dash: style.animatedDashPattern, dashPhase: -store.edgeDashPhase)
            context.stroke(animatedPath, with: .color(style.strokeColor), style: strokeStyle)
        }
        if !selectedPath.isEmpty {
            let strokeStyle = StrokeStyle(lineWidth: style.selectedLineWidth)
            context.stroke(selectedPath, with: .color(style.selectedStrokeColor), style: strokeStyle)
        }
        if !dropTargetPath.isEmpty {
            let strokeStyle = StrokeStyle(lineWidth: style.selectedLineWidth + 1)
            context.stroke(dropTargetPath, with: .color(.accentColor), style: strokeStyle)
        }

        // Edge labels (with background for readability)
        for (label, position) in labelsToDraw {
            let resolved = context.resolve(Text(label).font(.caption2).foregroundStyle(.secondary))
            let textSize = resolved.measure(in: CGSize(width: 200, height: 50))
            let padding: CGFloat = 4
            let bgRect = CGRect(
                x: position.x - textSize.width / 2 - padding,
                y: position.y - textSize.height / 2 - padding,
                width: textSize.width + padding * 2,
                height: textSize.height + padding * 2
            )
            let bgPath = Path(roundedRect: bgRect, cornerRadius: 4)
            let bgColor: Color = colorScheme == .dark ? Color(white: 0.2, opacity: 0.95) : Color(white: 1.0, opacity: 0.95)
            context.fill(bgPath, with: .color(bgColor))
            context.draw(resolved, at: position)
        }
    }

    // MARK: - Drawing: Nodes

    private func drawNodes(context: inout GraphicsContext, canvasSize: CGSize) {
        let viewport = store.viewport
        let margin: CGFloat = 100

        // Handle protrusion: resolved symbols include extra space for handles
        // that sit on the node border (half in, half out).
        let handleInset = FlowHandle.diameter / 2

        // Iterate back-to-front (reverse of front-to-back cache) for correct draw order
        for index in store.nodeIndicesFrontToBack.reversed() {
            let node = store.nodes[index]

            // Skip rasterized draw for nodes the overlay is currently
            // drawing (live view visible at opacity 1). Gated on both
            // `renderedActive` *and* live presence — a plain node that
            // becomes "active" on hover has no live view to hand off
            // to, so Canvas must keep drawing it. While the user is
            // mid-pan / mid-zoom we suppress this skip entirely so the
            // Canvas keeps drawing every node from its poster — the
            // overlay's live row is unmounted in that window, and
            // skipping here would briefly drop the node from the
            // canvas.
            if !isViewportInteracting,
               liveNodeActivationCoordinator.overlayIsDrawing(node.id) {
                continue
            }

            let screenOrigin = viewport.canvasToScreen(node.position)

            // Expand draw rect to include handle protrusion
            let drawRect = CGRect(
                x: screenOrigin.x - handleInset * viewport.zoom,
                y: screenOrigin.y - handleInset * viewport.zoom,
                width: (node.size.width + handleInset * 2) * viewport.zoom,
                height: (node.size.height + handleInset * 2) * viewport.zoom
            )

            // Viewport culling
            let visibleRect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: -margin, dy: -margin)
            guard visibleRect.intersects(drawRect) else { continue }

            if let resolved = context.resolveSymbol(id: node.id) {
                context.draw(resolved, in: drawRect)
            }
        }
    }

    // MARK: - Drawing: Selection Rect

    private func drawSelectionRect(context: inout GraphicsContext) {
        guard let selectionRect = store.selectionRect else { return }
        let viewport = store.viewport

        let screenOrigin = viewport.canvasToScreen(selectionRect.rect.origin)
        let screenEnd = viewport.canvasToScreen(
            CGPoint(x: selectionRect.rect.maxX, y: selectionRect.rect.maxY)
        )
        let rect = CGRect(
            x: screenOrigin.x, y: screenOrigin.y,
            width: screenEnd.x - screenOrigin.x,
            height: screenEnd.y - screenOrigin.y
        ).standardized

        let path = Path(rect)
        context.fill(path, with: .color(.blue.opacity(0.1)))
        context.stroke(path, with: .color(.blue.opacity(0.5)), lineWidth: 1)
    }

    // MARK: - Drawing: Connection Draft

    private func drawConnectionDraft(context: inout GraphicsContext, canvasSize: CGSize) {
        guard let draft = store.connectionDraft else { return }
        let viewport = store.viewport

        let sourcePoint = store.handleInfo(nodeID: draft.sourceNodeID, handleID: draft.sourceHandleID)?.point
            ?? store.nodeLookup[draft.sourceNodeID].map {
                CGPoint(x: $0.position.x + $0.size.width / 2, y: $0.position.y + $0.size.height / 2)
            }
            ?? .zero

        let screenFrom = viewport.canvasToScreen(sourcePoint)
        let target = resolvedDraftTarget(for: draft)
        let screenTo = target?.screenPoint ?? draft.currentPoint
        let targetPosition = target?.position ?? inferTargetPosition(from: screenFrom, to: screenTo)
        let calculator = FlowStore<NodeData>.pathCalculator(for: store.configuration.defaultEdgePathType)
        let edgePath = calculator.path(
            from: screenFrom, sourcePosition: draft.sourceHandlePosition,
            to: screenTo, targetPosition: targetPosition
        )

        context.stroke(
            edgePath.path,
            with: .color(.blue.opacity(0.5)),
            style: StrokeStyle(lineWidth: 2, dash: [6, 3])
        )
    }

    // MARK: - Gestures

    private var primaryDragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if case .none = dragMode {
                    let canvasPoint = store.viewport.screenToCanvas(value.startLocation)

                    if let handleHit = store.hitTestHandle(at: canvasPoint) {
                        dragMode = .connection(handleHit)
                        store.beginConnection(
                            nodeID: handleHit.nodeID,
                            handleID: handleHit.handleID,
                            handleType: handleHit.handleType,
                            handlePosition: handleHit.handlePosition
                        )
                    } else if let nodeID = store.hitTestNode(at: canvasPoint) {
                        store.beginNodeDrag(nodeID)
                        guard store.isNodeDragging else {
                            dragMode = .none
                            return
                        }
                        dragMode = .nodeMove
                    } else if store.configuration.selectionEnabled,
                              store.configuration.multiSelectionEnabled {
                        let canvasStart = store.viewport.screenToCanvas(value.startLocation)
                        dragMode = .selection(origin: canvasStart)
                    }
                }

                switch dragMode {
                case .none:
                    break
                case .selection(let origin):
                    let canvasCurrent = store.viewport.screenToCanvas(value.location)
                    let rect = SelectionRect(
                        origin: origin,
                        size: CGSize(
                            width: canvasCurrent.x - origin.x,
                            height: canvasCurrent.y - origin.y
                        )
                    )
                    store.selectionRect = rect
                    store.selectInRect(rect)
                case .nodeMove:
                    store.updateNodeDrag(translation: value.translation)
                case .connection:
                    let canvasPoint = store.viewport.screenToCanvas(value.location)
                    let target = draftConnectionTarget(at: canvasPoint)
                    store.updateConnection(
                        to: value.location,
                        targetNodeID: target?.nodeID,
                        targetHandleID: target?.handleID
                    )
                }

                #if os(macOS)
                syncDragCursor(for: dragMode)
                #endif
            }
            .onEnded { value in
                switch dragMode {
                case .selection:
                    store.selectionRect = nil
                case .nodeMove:
                    store.endNodeDrag()
                case .connection(let handle):
                    let canvasPoint = store.viewport.screenToCanvas(value.location)
                    if let target = draftConnectionTarget(at: canvasPoint, from: handle) {
                        store.endConnection(targetNodeID: target.nodeID, targetHandleID: target.handleID)
                    } else {
                        store.cancelConnection()
                    }
                case .none:
                    break
                }
                dragMode = .none

                #if os(macOS)
                syncDragCursor(for: dragMode)
                #endif
            }
    }


    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard store.configuration.zoomEnabled else { return }
                beginViewportInteraction()
                let factor = value.magnification / lastMagnification
                lastMagnification = value.magnification
                store.zoom(by: factor, anchor: value.startLocation)
            }
            .onEnded { _ in
                lastMagnification = 1.0
                endViewportInteractionImmediately()
            }
    }

    // MARK: - Tap

    private func handleTap(at location: CGPoint, isAdditive: Bool = false) {
        let canvasPoint = store.viewport.screenToCanvas(location)

        // Determine tap target via hit testing
        let currentTarget: DoubleTapTarget
        if let nodeID = store.hitTestNode(at: canvasPoint) {
            currentTarget = .node(nodeID)
        } else if let edgeID = store.hitTestEdge(at: canvasPoint) {
            currentTarget = .edge(edgeID)
        } else {
            currentTarget = .canvas
        }

        // Perform single-tap action immediately (no delay)
        switch currentTarget {
        case .node(let nodeID):
            if isAdditive {
                if store.selectedNodeIDs.contains(nodeID) {
                    store.deselectNode(nodeID)
                } else {
                    store.selectNode(nodeID, exclusive: false)
                }
            } else {
                store.selectNode(nodeID)
            }
        case .edge(let edgeID):
            if isAdditive {
                if store.selectedEdgeIDs.contains(edgeID) {
                    store.deselectEdge(edgeID)
                } else {
                    store.selectEdge(edgeID, exclusive: false)
                }
            } else {
                store.selectEdge(edgeID)
            }
        case .canvas, .none:
            if !isAdditive {
                store.clearSelection()
            }
        }

        // Double-tap detection
        if !isAdditive {
            if doubleTapDetector.recordTap(target: currentTarget) {
                switch currentTarget {
                case .node(let nodeID):
                    store.onNodeDoubleTap?(nodeID)
                case .edge(let edgeID):
                    store.onEdgeDoubleTap?(edgeID)
                case .canvas:
                    store.onCanvasDoubleTap?(canvasPoint)
                case .none:
                    break
                }
            }
        } else {
            doubleTapDetector.reset()
        }
    }

    // MARK: - Cursor (macOS)

    #if os(macOS)
    private func dragCursorKind(for mode: CanvasDragMode) -> DragCursorKind? {
        switch mode {
        case .nodeMove: .closedHand
        case .connection: .crosshair
        case .selection, .none: nil
        }
    }

    private func syncDragCursor(for mode: CanvasDragMode) {
        let desired = dragCursorKind(for: mode)
        if desired != pushedDragCursor {
            if pushedDragCursor != nil {
                NSCursor.pop()
            }
            if let desired {
                desired.cursor.push()
            }
            pushedDragCursor = desired
        }
        if let desired {
            desired.cursor.set()
        }
    }

    private func releaseDragCursorIfNeeded() {
        if pushedDragCursor != nil {
            NSCursor.pop()
            pushedDragCursor = nil
        }
    }

    #endif

    // MARK: - Viewport Interaction

    private func beginViewportInteraction() {
        isViewportInteracting = true
        viewportInteractionResetTask?.cancel()
    }

    private func scheduleEndViewportInteraction(after delay: UInt64 = 120_000_000) {
        viewportInteractionResetTask?.cancel()
        viewportInteractionResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            if !Task.isCancelled {
                isViewportInteracting = false
            }
        }
    }

    private func endViewportInteractionImmediately() {
        viewportInteractionResetTask?.cancel()
        viewportInteractionResetTask = nil
        isViewportInteracting = false
    }

    // MARK: - Drawing: Edges (symbol-based)

    private func drawEdgesViaSymbols(context: inout GraphicsContext, canvasSize: CGSize) {
        let viewport = store.viewport
        let margin: CGFloat = 50

        for edge in store.edges {
            guard let geometry = computeEdgeGeometry(for: edge) else { continue }

            let screenMin = viewport.canvasToScreen(geometry.bounds.origin)
            let screenMax = viewport.canvasToScreen(
                CGPoint(x: geometry.bounds.maxX, y: geometry.bounds.maxY)
            )
            let screenBounds = CGRect(
                x: screenMin.x, y: screenMin.y,
                width: screenMax.x - screenMin.x,
                height: screenMax.y - screenMin.y
            ).standardized

            let visibleRect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: -margin, dy: -margin)
            guard visibleRect.intersects(screenBounds) else { continue }

            if let resolved = context.resolveSymbol(id: EdgeSymbolID(edgeID: edge.id)) {
                context.draw(resolved, in: screenBounds)
            }
        }
    }

    private func computeEdgeGeometry(for edge: FlowEdge) -> EdgeGeometry? {
        guard let source = store.handleInfo(nodeID: edge.sourceNodeID, handleID: edge.sourceHandleID),
              let target = store.handleInfo(nodeID: edge.targetNodeID, handleID: edge.targetHandleID)
        else { return nil }

        let calculator = FlowStore<NodeData>.pathCalculator(for: edge.pathType)
        let edgePath = calculator.path(
            from: source.point, sourcePosition: source.position,
            to: target.point, targetPosition: target.position
        )

        let rawBounds = edgePath.path.boundingRect.insetBy(dx: -20, dy: -20)
        let offset = CGAffineTransform(translationX: -rawBounds.origin.x, y: -rawBounds.origin.y)
        let translatedPath = Path(edgePath.path.cgPath.copy(using: [offset]) ?? edgePath.path.cgPath)

        return EdgeGeometry(
            path: translatedPath,
            sourcePoint: CGPoint(x: source.point.x - rawBounds.origin.x, y: source.point.y - rawBounds.origin.y),
            targetPoint: CGPoint(x: target.point.x - rawBounds.origin.x, y: target.point.y - rawBounds.origin.y),
            sourcePosition: source.position,
            targetPosition: target.position,
            labelPosition: CGPoint(x: edgePath.labelPosition.x - rawBounds.origin.x, y: edgePath.labelPosition.y - rawBounds.origin.y),
            labelAngle: edgePath.labelAngle,
            bounds: rawBounds
        )
    }

    @ViewBuilder
    private func edgeSymbolView(edge: FlowEdge, builder: @escaping (FlowEdge, EdgeGeometry) -> AnyView) -> some View {
        if let geometry = computeEdgeGeometry(for: edge) {
            builder(edge, geometry)
                .frame(width: geometry.bounds.width, height: geometry.bounds.height)
                .tag(EdgeSymbolID(edgeID: edge.id))
        }
    }

    // MARK: - Helpers

    private func transformedPath(_ path: Path, viewport: Viewport) -> Path {
        let transform = CGAffineTransform(scaleX: viewport.zoom, y: viewport.zoom)
            .concatenating(CGAffineTransform(translationX: viewport.offset.x, y: viewport.offset.y))
        return Path(path.cgPath.copy(using: [transform]) ?? path.cgPath)
    }

    private func nodeRenderContext(for node: FlowNode<NodeData>) -> NodeRenderContext {
        let connectedHandleID: String? = {
            guard let draft = store.connectionDraft,
                  draft.targetNodeID == node.id else { return nil }
            return draft.targetHandleID
        }()
        return NodeRenderContext(
            connectedHandleID: connectedHandleID,
            snapshot: store.nodeSnapshots[node.id]
        )
    }

    private func draftConnectionTarget(
        at canvasPoint: CGPoint,
        from handle: HandleHitResult? = nil
    ) -> (nodeID: String, handleID: String)? {
        let sourceHandle = handle ?? connectionSourceHandle()
        guard let sourceHandle else { return nil }
        let targetType: HandleType = sourceHandle.handleType == .source ? .target : .source
        return store.findNearestHandle(
            at: canvasPoint,
            excludingNodeID: sourceHandle.nodeID,
            targetType: targetType,
            threshold: 40
        )
    }

    private func connectionSourceHandle() -> HandleHitResult? {
        guard let draft = store.connectionDraft else { return nil }
        return HandleHitResult(
            nodeID: draft.sourceNodeID,
            handleID: draft.sourceHandleID,
            handleType: draft.sourceHandleType,
            handlePosition: draft.sourceHandlePosition
        )
    }

    private func resolvedDraftTarget(for draft: ConnectionDraft) -> (screenPoint: CGPoint, position: HandlePosition)? {
        guard let targetNodeID = draft.targetNodeID else { return nil }
        if let targetHandleID = draft.targetHandleID,
           let handleInfo = store.handleInfo(nodeID: targetNodeID, handleID: targetHandleID) {
            return (
                screenPoint: store.viewport.canvasToScreen(handleInfo.point),
                position: handleInfo.position
            )
        }
        guard let node = store.nodeLookup[targetNodeID] else { return nil }
        let center = CGPoint(x: node.position.x + node.size.width / 2, y: node.position.y + node.size.height / 2)
        let screenCenter = store.viewport.canvasToScreen(center)
        let sourceScreenPoint = store.viewport.canvasToScreen(
            store.handleInfo(nodeID: draft.sourceNodeID, handleID: draft.sourceHandleID)?.point ?? center
        )
        return (
            screenPoint: screenCenter,
            position: inferTargetPosition(from: sourceScreenPoint, to: screenCenter)
        )
    }


    private func inferTargetPosition(from source: CGPoint, to target: CGPoint) -> HandlePosition {
        let dx = target.x - source.x
        let dy = target.y - source.y
        if abs(dx) > abs(dy) {
            return dx > 0 ? .left : .right
        } else {
            return dy > 0 ? .top : .bottom
        }
    }
}

// MARK: - CanvasDragMode

private enum CanvasDragMode {
    case none
    case selection(origin: CGPoint)
    /// Active node-move drag. The session payload (start positions,
    /// multi-select expansion) lives on `FlowStore.nodeDragSession` so
    /// every drag site — Canvas-level and external `flowDragHandle`
    /// modifier alike — funnels through the same dispatch.
    case nodeMove
    case connection(HandleHitResult)
}

private struct EdgeSymbolID: Hashable {
    let edgeID: String
}

#if os(macOS)
private enum DragCursorKind: Equatable {
    case closedHand
    case crosshair

    var cursor: NSCursor {
        switch self {
        case .closedHand: .closedHand
        case .crosshair: .crosshair
        }
    }
}
#endif

