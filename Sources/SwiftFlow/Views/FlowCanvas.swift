import SwiftUI
import UniformTypeIdentifiers
#if canImport(WebKit)
import WebKit
#endif

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
                nodeContentBuilder(node, nodeRenderContext(for: node))
                    .environment(\.flowNodeRenderPhase, .rasterize)
                    .environment(\.flowNodeID, node.id)
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

        let hasAccessory = nodeAccessoryBuilder != nil || edgeAccessoryBuilder != nil
        let snapshotWriter: @MainActor (String, FlowNodeSnapshot) -> Void = { [store] id, snap in
            store.setNodeSnapshot(snap, for: id)
        }

        #if os(macOS)
        let hostView = CanvasHostView(
            onScroll: { delta, location in
                guard store.configuration.panEnabled else { return }
                store.pan(by: delta)
            },
            onMagnify: { magnification, location in
                store.zoom(by: 1 + magnification, anchor: location)
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
                coordinator: liveNodeActivationCoordinator
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
                store.pan(by: delta)
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
                coordinator: liveNodeActivationCoordinator
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
            // rendering. Keyed on the coordinator's `renderedActive`
            // state — not the raw predicate — so nodes mid-deactivation
            // (overlay still at opacity 1, capture in flight) don't have
            // the stale snapshot bleeding through underneath while we
            // wait for the fresh one to land.
            if liveNodeActivationCoordinator.isRenderedActive(node.id) {
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
                    } else if let nodeID = store.hitTestNode(at: canvasPoint),
                              let node = store.nodeLookup[nodeID],
                              node.isDraggable {
                        var startPositions: [String: CGPoint] = [:]
                        if node.isSelected, store.selectedNodeIDs.count > 1 {
                            for selectedID in store.selectedNodeIDs {
                                if let n = store.nodeLookup[selectedID], n.isDraggable {
                                    startPositions[selectedID] = n.position
                                }
                            }
                        } else {
                            startPositions[nodeID] = node.position
                        }
                        dragMode = .nodeMove(startPositions: startPositions)
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
                case .nodeMove(let startPositions):
                    let delta = CGSize(
                        width: value.translation.width / store.viewport.zoom,
                        height: value.translation.height / store.viewport.zoom
                    )
                    for (nodeID, startPosition) in startPositions {
                        store.moveNode(nodeID, to: CGPoint(
                            x: startPosition.x + delta.width,
                            y: startPosition.y + delta.height
                        ))
                    }
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
                case .nodeMove(let startPositions):
                    store.completeMoveNodes(from: startPositions)
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
                let factor = value.magnification / lastMagnification
                lastMagnification = value.magnification
                store.zoom(by: factor, anchor: value.startLocation)
            }
            .onEnded { _ in
                lastMagnification = 1.0
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
    case nodeMove(startPositions: [String: CGPoint])
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

// MARK: - Preview

/// Data model for preview nodes.
private struct PreviewNodeData: Sendable, Hashable, Codable {
    let title: String
    let category: String
    let icon: String
    var badge: String?
    var subtitle: String?
}

/// Unified draggable payload. Uses `public.json` (a well-known system UTType)
/// so that the pasteboard, registerForDraggedTypes, and NSItemProvider all
/// work without custom UTType registration in Info.plist.
/// The `kind` field discriminates the three item categories.
private struct DragPayload: Sendable, Hashable, Codable, Transferable {
    enum Kind: String, Codable {
        case nodeTemplate
        case nodeAttribute
        case edgeAttribute
    }

    let kind: Kind
    let title: String
    let subtitle: String?
    let icon: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

private struct PreviewNode: View {

    let node: FlowNode<PreviewNodeData>
    let context: NodeRenderContext
    static var handleInset: CGFloat { FlowHandle.diameter / 2 }

    init(node: FlowNode<PreviewNodeData>, context: NodeRenderContext) {
        self.node = node
        self.context = context
    }

    var body: some View {
        let inset = Self.handleInset

        ZStack {
            card.padding(inset)

            ForEach(node.handles, id: \.id) { handle in
                FlowHandle(handle.id, type: handle.type, position: handle.position)
                    .overlay {
                        if context.connectedHandleID == handle.id {
                            Circle()
                                .strokeBorder(handleHighlightColor, lineWidth: 2)
                                .padding(-4)
                        }
                    }
                    .scaleEffect(context.connectedHandleID == handle.id ? 1.15 : 1.0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: handleAlignment(handle.position))
            }
        }
        .frame(width: node.size.width + inset * 2, height: node.size.height + inset * 2)
        .opacity(cardOpacity)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(cardFillStyle)
            .shadow(color: baseShadowColor, radius: 1, y: 1)
            .shadow(
                color: focusShadowColor,
                radius: focusShadowRadius,
                y: focusShadowYOffset
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(borderColor, style: StrokeStyle(lineWidth: borderLineWidth, dash: borderDash))
            }
            .overlay(alignment: .leading) { cardContent }
            .scaleEffect(node.isDropTarget ? 1.04 : 1.0)
            .animation(.spring(duration: 0.2), value: node.isDropTarget)
    }

    @ViewBuilder
    private var cardContent: some View {
        switch node.data.category {
        case "Trigger":
            triggerContent
        case "Logic":
            logicContent
        case "Network":
            networkContent
        case "Output":
            outputContent
        default:
            standardContent
        }
    }

    private var triggerContent: some View {
        HStack(spacing: 10) {
            iconView
            Text(node.data.title)
                .font(.system(.subheadline, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
                .overlay { Circle().stroke(.green.opacity(0.4), lineWidth: 2) }
        }
        .padding(.horizontal, 10)
    }

    private var logicContent: some View {
        VStack(spacing: 2) {
            Image(systemName: node.data.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(categoryColor)
            Text(node.data.title)
                .font(.system(.caption, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var networkContent: some View {
        HStack(spacing: 10) {
            iconView
            VStack(alignment: .leading, spacing: 1) {
                Text(node.data.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if let subtitle = node.data.subtitle {
                    Text(subtitle)
                        .font(.system(.caption2, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let badge = node.data.badge {
                Text(badge)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(categoryColor, in: Capsule())
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
    }

    private var outputContent: some View {
        HStack(spacing: 10) {
            iconView
            Text(node.data.title)
                .font(.system(.subheadline, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            if let badge = node.data.badge {
                Text(badge)
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(categoryColor, in: Circle())
            }
        }
        .padding(.horizontal, 10)
    }

    private var standardContent: some View {
        HStack(spacing: 10) {
            iconView
            VStack(alignment: .leading, spacing: 1) {
                Text(node.data.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(node.data.subtitle ?? node.data.category)
                    .font(.system(.caption2))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
    }

    private var iconView: some View {
        Image(systemName: node.data.icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(categoryColor, in: RoundedRectangle(cornerRadius: 7))
    }

    private var categoryColor: Color {
        switch node.data.category {
        case "Trigger":   .orange
        case "Security":  .red
        case "Logic":     .pink
        case "Data":      .blue
        case "Transform": .teal
        case "Storage":   .indigo
        case "Network":   .cyan
        case "Queue":     .brown
        case "Output":    .green
        default:          .gray
        }
    }

    private var cardFillStyle: AnyShapeStyle {
        switch node.phase {
        case .normal:
            return node.isDropTarget
                ? AnyShapeStyle(Color.accentColor.opacity(0.08))
                : AnyShapeStyle(.background)
        case .draft(.neutral):
            return AnyShapeStyle(categoryColor.opacity(0.08))
        case .draft(.valid):
            return AnyShapeStyle(Color.accentColor.opacity(0.12))
        case .draft(.invalid):
            return AnyShapeStyle(Color.red.opacity(0.1))
        }
    }

    private var baseShadowColor: Color {
        switch node.phase {
        case .normal:
            return .black.opacity(0.06)
        case .draft:
            return .clear
        }
    }

    private var focusShadowColor: Color {
        switch node.phase {
        case .normal:
            if node.isDropTarget { return Color.accentColor.opacity(0.5) }
            if node.isSelected { return Color.accentColor.opacity(0.4) }
            if node.isHovered { return .black.opacity(0.14) }
            return .black.opacity(0.08)
        case .draft(.neutral):
            return categoryColor.opacity(0.18)
        case .draft(.valid):
            return Color.accentColor.opacity(0.26)
        case .draft(.invalid):
            return Color.red.opacity(0.22)
        }
    }

    private var focusShadowRadius: CGFloat {
        switch node.phase {
        case .normal:
            if node.isDropTarget { return 10 }
            if node.isSelected { return 8 }
            if node.isHovered { return 5 }
            return 3
        case .draft:
            return 0
        }
    }

    private var focusShadowYOffset: CGFloat {
        switch node.phase {
        case .normal:
            if node.isDropTarget || node.isSelected { return 0 }
            if node.isHovered { return 1 }
            return 2
        case .draft:
            return 0
        }
    }

    private var borderColor: Color {
        switch node.phase {
        case .normal:
            if node.isDropTarget || node.isSelected { return .accentColor }
            if node.isHovered { return Color.primary.opacity(0.25) }
            return Color.primary.opacity(0.1)
        case .draft(.neutral):
            return categoryColor.opacity(0.5)
        case .draft(.valid):
            return Color.accentColor.opacity(0.85)
        case .draft(.invalid):
            return Color.red.opacity(0.85)
        }
    }

    private var borderLineWidth: CGFloat {
        switch node.phase {
        case .normal:
            if node.isDropTarget { return 2.0 }
            if node.isSelected { return 1.5 }
            if node.isHovered { return 0.75 }
            return 0.5
        case .draft:
            return 1.25
        }
    }

    private var borderDash: [CGFloat] {
        switch node.phase {
        case .normal:
            return []
        case .draft:
            return [7, 4]
        }
    }

    private var cardOpacity: CGFloat {
        switch node.phase {
        case .normal:
            return 1
        case .draft(.neutral):
            return 0.78
        case .draft(.valid):
            return 0.92
        case .draft(.invalid):
            return 0.86
        }
    }

    private var handleHighlightColor: Color {
        switch node.phase {
        case .draft(.invalid):
            return .red
        case .draft(.neutral), .draft(.valid), .normal:
            return .accentColor
        }
    }

    private func handleAlignment(_ position: HandlePosition) -> Alignment {
        switch position {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }
}

@MainActor
@Observable
private final class PreviewInteractionState {
    var lastEvent: String = "Double-tap the canvas, drag into Notify to reject, or inject a draft node."
    var lastCanvasDoubleTap: String = "Not yet"
    var lastRejectedConnection: String = "Drag any output into Notify"
    var draftStatus: String = "Hidden"
    var draftTarget: String = "No target"
    var edgePathStyle: String = "Bezier"
}

private struct PreviewConnectionValidator: ConnectionValidating {
    func validate(_ proposal: ConnectionProposal) -> Bool {
        guard DefaultConnectionValidator().validate(proposal) else { return false }
        return proposal.targetNodeID != "notify" || proposal.sourceNodeID == "format"
    }
}

private struct PreviewStatusPanel: View {
    let interaction: PreviewInteractionState
    let toggleDraft: () -> Void
    let cycleDraftState: () -> Void
    let toggleDraftTarget: () -> Void
    let commitDraft: () -> Void
    let cycleEdgePathStyle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview Checks")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Text(interaction.lastEvent)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(3)

            statusRow("Canvas Double-Tap", interaction.lastCanvasDoubleTap)
            statusRow("Rejected Connection", interaction.lastRejectedConnection)
            statusRow("Draft Node", interaction.draftStatus)
            statusRow("Draft Target", interaction.draftTarget)
            statusRow("Edge Path", interaction.edgePathStyle)

            HStack(spacing: 6) {
                Button(action: toggleDraft) {
                    Label(
                        interaction.draftStatus == "Hidden" ? "Inject" : "Clear",
                        systemImage: interaction.draftStatus == "Hidden" ? "plus.circle" : "xmark.circle"
                    )
                    .font(.caption2)
                }
                .buttonStyle(.bordered)

                Button(action: cycleDraftState) {
                    Label("State", systemImage: "paintpalette")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .disabled(interaction.draftStatus == "Hidden")

                Button(action: toggleDraftTarget) {
                    Label("Target", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .disabled(interaction.draftStatus == "Hidden")
            }
            .controlSize(.small)

            Button(action: commitDraft) {
                Label("Commit", systemImage: "checkmark.circle")
                    .font(.caption2)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(interaction.draftStatus == "Hidden" || interaction.draftStatus.hasPrefix("Normal"))

            Button(action: cycleEdgePathStyle) {
                Label("Path", systemImage: "arrow.triangle.swap")
                    .font(.caption2)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            statusRow("Handle", "\(Int(FlowHandle.diameter))pt")
            statusRow("Platform", platformNote)
        }
        .padding(10)
        .frame(width: 220, alignment: .leading)
    }

    private var platformNote: String {
        #if os(macOS)
        "Command-click multi-select available"
        #else
        "iOS build excludes command-click path"
        #endif
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
    }
}

private func previewPointText(_ point: CGPoint) -> String {
    "x: \(Int(point.x.rounded())), y: \(Int(point.y.rounded()))"
}

private func previewProposalText(_ proposal: ConnectionProposal) -> String {
    "\(proposal.sourceNodeID) -> \(proposal.targetNodeID)"
}

private let previewDraftNodeID = "draft-preview"

private func previewDraftPhaseText(_ phase: FlowNodePhase?) -> String {
    guard let phase else { return "Hidden" }
    switch phase {
    case .normal:
        return "Normal"
    case .draft(.neutral):
        return "Neutral"
    case .draft(.valid):
        return "Valid"
    case .draft(.invalid):
        return "Invalid"
    }
}

private func previewDraftTargetText(_ targetHandleID: String?) -> String {
    if let targetHandleID {
        return "Handle \(targetHandleID)"
    }
    return "Free point"
}

private func previewDraftStatusText(_ node: FlowNode<PreviewNodeData>?) -> String {
    guard let node else { return "Hidden" }
    let scope = node.persistence == .persistent ? "Persistent" : "Transient"
    return "\(previewDraftPhaseText(node.phase)) · \(scope)"
}

private func previewEdgePathStyleText(_ pathType: EdgePathType) -> String {
    switch pathType {
    case .bezier:
        return "Bezier"
    case .straight:
        return "Straight"
    case .smoothStep:
        return "Right Angle"
    case .simpleBezier:
        return "Simple Bezier"
    }
}

private func previewNextEdgePathType(after pathType: EdgePathType) -> EdgePathType {
    switch pathType {
    case .bezier:
        return .straight
    case .straight:
        return .smoothStep
    case .smoothStep:
        return .simpleBezier
    case .simpleBezier:
        return .bezier
    }
}

private func makePreviewDraftNode(phase: FlowNodePhase) -> FlowNode<PreviewNodeData> {
    FlowNode(
        id: previewDraftNodeID,
        position: CGPoint(x: 660, y: 430),
        size: CGSize(width: 160, height: 50),
        data: PreviewNodeData(
            title: "Review Draft",
            category: "Network",
            icon: "wand.and.stars",
            badge: "TMP",
            subtitle: "Transient node"
        ),
        phase: phase,
        persistence: .transient,
        handles: [
            HandleDeclaration(id: "in", type: .target, position: .left),
            HandleDeclaration(id: "out", type: .source, position: .right),
        ]
    )
}

#Preview("FlowCanvas") {
    @Previewable @State var store: FlowStore<PreviewNodeData> = {
        let hOut: [HandleDeclaration] = [
            HandleDeclaration(id: "out", type: .source, position: .right),
        ]
        let hIn: [HandleDeclaration] = [
            HandleDeclaration(id: "in", type: .target, position: .left),
        ]
        let hLR: [HandleDeclaration] = [
            HandleDeclaration(id: "in", type: .target, position: .left),
            HandleDeclaration(id: "out", type: .source, position: .right),
        ]

        let s = CGSize(width: 160, height: 50)

        func n(_ id: String, x: CGFloat, y: CGFloat, title: String, category: String, icon: String, handles: [HandleDeclaration] = hLR, badge: String? = nil, subtitle: String? = nil) -> FlowNode<PreviewNodeData> {
            FlowNode(id: id, position: CGPoint(x: x, y: y), size: s, data: PreviewNodeData(title: title, category: category, icon: icon, badge: badge, subtitle: subtitle), handles: handles)
        }

        let store = FlowStore<PreviewNodeData>(
            nodes: [
                // Entry
                n("webhook", x: 30,   y: 200, title: "Webhook",   category: "Trigger",   icon: "bolt.fill",             handles: hOut),
                n("auth",    x: 240,  y: 200, title: "Auth",      category: "Security",  icon: "lock.fill",             subtitle: "OAuth 2.0"),
                n("router",  x: 450,  y: 200, title: "Router",    category: "Logic",     icon: "arrow.triangle.branch"),
                // Top branch
                n("parse",     x: 660,  y: 60,  title: "Parse",     category: "Data",      icon: "doc.text.fill",       subtitle: "JSON"),
                n("transform", x: 870,  y: 60,  title: "Transform", category: "Transform", icon: "wand.and.stars",      subtitle: "Map fields"),
                n("dbwrite",   x: 1080, y: 60,  title: "DB Write",  category: "Storage",   icon: "internaldrive.fill",  subtitle: "PostgreSQL"),
                // Middle branch
                n("validate", x: 660,  y: 200, title: "Validate",  category: "Logic",     icon: "checkmark.shield.fill"),
                n("enrich",   x: 870,  y: 200, title: "Enrich",    category: "Data",      icon: "plus.magnifyingglass", subtitle: "Metadata"),
                n("apicall",  x: 1080, y: 200, title: "API Call",  category: "Network",   icon: "network",              badge: "POST", subtitle: "api.example.com"),
                // Bottom branch
                n("cache",  x: 660,  y: 340, title: "Cache",  category: "Storage", icon: "tray.full.fill",         subtitle: "Redis"),
                n("queue",  x: 870,  y: 340, title: "Queue",  category: "Queue",   icon: "list.bullet",            subtitle: "3 pending"),
                n("retry",  x: 1080, y: 340, title: "Retry",  category: "Logic",   icon: "arrow.counterclockwise"),
                // Exit
                n("merge",  x: 1290, y: 200, title: "Merge",  category: "Logic",     icon: "arrow.triangle.merge"),
                n("format", x: 1500, y: 200, title: "Format", category: "Transform", icon: "text.alignleft",       subtitle: "Template"),
                n("notify", x: 1710, y: 200, title: "Notify", category: "Output",    icon: "bell.fill",            handles: hIn, badge: "3"),
            ],
            edges: [
                // Entry (animated to show dash phase)
                FlowEdge(id: "e01", sourceNodeID: "webhook", sourceHandleID: "out", targetNodeID: "auth",     targetHandleID: "in"),
                FlowEdge(id: "e02", sourceNodeID: "auth",    sourceHandleID: "out", targetNodeID: "router",   targetHandleID: "in"),
                // Fan-out from router
                FlowEdge(id: "e03", sourceNodeID: "router",  sourceHandleID: "out", targetNodeID: "parse",    targetHandleID: "in", label: "JSON"),
                FlowEdge(id: "e04", sourceNodeID: "router",  sourceHandleID: "out", targetNodeID: "validate", targetHandleID: "in"),
                FlowEdge(id: "e05", sourceNodeID: "router",  sourceHandleID: "out", targetNodeID: "cache",    targetHandleID: "in", label: "Static"),
                // Top branch
                FlowEdge(id: "e06", sourceNodeID: "parse",     sourceHandleID: "out", targetNodeID: "transform", targetHandleID: "in"),
                FlowEdge(id: "e07", sourceNodeID: "transform", sourceHandleID: "out", targetNodeID: "dbwrite",   targetHandleID: "in"),
                FlowEdge(id: "e08", sourceNodeID: "dbwrite",   sourceHandleID: "out", targetNodeID: "merge",     targetHandleID: "in"),
                // Middle branch
                FlowEdge(id: "e09", sourceNodeID: "validate", sourceHandleID: "out", targetNodeID: "enrich",  targetHandleID: "in"),
                FlowEdge(id: "e10", sourceNodeID: "enrich",   sourceHandleID: "out", targetNodeID: "apicall", targetHandleID: "in"),
                FlowEdge(id: "e11", sourceNodeID: "apicall",  sourceHandleID: "out", targetNodeID: "merge",   targetHandleID: "in"),
                // Bottom branch
                FlowEdge(id: "e12", sourceNodeID: "cache", sourceHandleID: "out", targetNodeID: "queue", targetHandleID: "in"),
                FlowEdge(id: "e13", sourceNodeID: "queue", sourceHandleID: "out", targetNodeID: "retry", targetHandleID: "in"),
                FlowEdge(id: "e14", sourceNodeID: "retry", sourceHandleID: "out", targetNodeID: "merge", targetHandleID: "in"),
                // Exit
                FlowEdge(id: "e15", sourceNodeID: "merge",  sourceHandleID: "out", targetNodeID: "format", targetHandleID: "in"),
                FlowEdge(id: "e16", sourceNodeID: "format", sourceHandleID: "out", targetNodeID: "notify", targetHandleID: "in"),
            ],
            configuration: FlowConfiguration(
                backgroundStyle: BackgroundStyle(pattern: .dot),
                connectionValidator: PreviewConnectionValidator()
            )
        )
        // Animate entry edges to show dash phase
        store.setAnimatedEdges(["e01", "e02"])
        store.onConnect = { [weak store] proposal in
            guard let store else { return }
            let edge = FlowEdge(
                id: "e-\(UUID().uuidString.prefix(8))",
                sourceNodeID: proposal.sourceNodeID,
                sourceHandleID: proposal.sourceHandleID,
                targetNodeID: proposal.targetNodeID,
                targetHandleID: proposal.targetHandleID,
                pathType: store.configuration.defaultEdgePathType
            )
            store.addEdge(edge)
        }
        return store
    }()
    @Previewable @State var interaction = PreviewInteractionState()
    GeometryReader { geometry in
        let previewDraftPoint = store.viewport.canvasToScreen(CGPoint(x: 760, y: 455))

        ZStack {
            FlowCanvas(store: store) { node, context in
                PreviewNode(node: node, context: context)
            }
            .nodeAccessory(placement: { node in
                switch node.data.category {
                case "Trigger", "Data", "Transform":
                    return .bottom
                default:
                    return .top
                }
            }) { node in
                VStack(alignment: .leading, spacing: 6) {
                    Text(node.data.title)
                        .font(.headline)
                    Text(node.data.category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    HStack(spacing: 12) {
                        Button {
                        } label: {
                            Label("Edit", systemImage: "pencil")
                                .font(.caption)
                        }
                        Button(role: .destructive) {
                            store.removeNode(node.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                                .font(.caption)
                        }
                    }
                }
                .padding(12)
                .frame(width: 180)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            }
            .edgeAccessory { edge in
                HStack(spacing: 8) {
                    if let label = edge.label {
                        Text(label)
                            .font(.caption.bold())
                    } else {
                        Text("Edge")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        store.removeEdge(edge.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            }
            .dropDestination(for: [UTType.json]) { phase in
                switch phase {
                case .updated(_, _, let target):
                    // All items use .json — accept all targets during hover.
                    // Kind-based filtering happens on performed.
                    switch target {
                    case .canvas, .node, .edge:
                        return true
                    }

                case .performed(let providers, let location, let target):
                    let jsonType = UTType.json.identifier
                    for provider in providers {
                        provider.loadDataRepresentation(forTypeIdentifier: jsonType) { data, error in
                            guard let data else { return }
                            let payload: DragPayload
                            do {
                                payload = try JSONDecoder().decode(DragPayload.self, from: data)
                            } catch {
                                return
                            }
                            Task { @MainActor in
                                switch (payload.kind, target) {
                                case (.nodeTemplate, .canvas):
                                    let id = "new-\(UUID().uuidString.prefix(8))"
                                    let node = FlowNode(
                                        id: id,
                                        position: location,
                                        size: CGSize(width: 160, height: 50),
                                        data: PreviewNodeData(
                                            title: payload.title,
                                            category: payload.subtitle ?? "Default",
                                            icon: payload.icon
                                        ),
                                        handles: [
                                            HandleDeclaration(id: "in", type: .target, position: .left),
                                            HandleDeclaration(id: "out", type: .source, position: .right),
                                        ]
                                    )
                                    store.addNode(node)

                                case (.nodeAttribute, .node(let nodeID)):
                                    store.updateNode(nodeID) { node in
                                        node.data.badge = payload.title
                                        node.data.subtitle = payload.subtitle
                                    }

                                case (.edgeAttribute, .edge(let edgeID)):
                                    store.updateEdge(edgeID) { edge in
                                        edge.label = payload.title
                                    }

                                default:
                                    break
                                }
                            }
                        }
                    }
                    return true

                case .exited:
                    return false
                }
            }

            DragPalette()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)

            PreviewStatusPanel(
                interaction: interaction,
                toggleDraft: {
                    if store.nodeLookup[previewDraftNodeID] == nil {
                        store.addNode(makePreviewDraftNode(phase: .draft(.neutral)))
                        store.connectionDraft = ConnectionDraft(
                            sourceNodeID: "router",
                            sourceHandleID: "out",
                            sourceHandleType: .source,
                            sourceHandlePosition: .right,
                            targetNodeID: previewDraftNodeID,
                            targetHandleID: "in",
                            currentPoint: previewDraftPoint
                        )
                        interaction.draftStatus = previewDraftStatusText(store.nodeLookup[previewDraftNodeID])
                        interaction.draftTarget = previewDraftTargetText("in")
                        interaction.lastEvent = "Injected a transient draft node with a snapped draft edge."
                    } else {
                        store.connectionDraft = nil
                        store.removeNode(previewDraftNodeID)
                        interaction.draftStatus = "Hidden"
                        interaction.draftTarget = "No target"
                        interaction.lastEvent = "Cleared the transient draft node."
                    }
                },
                cycleDraftState: {
                    guard let node = store.nodeLookup[previewDraftNodeID] else { return }
                    let nextState: DraftPresentationState
                    switch node.phase {
                    case .draft(.neutral):
                        nextState = .valid
                    case .draft(.valid):
                        nextState = .invalid
                    case .draft(.invalid), .normal:
                        nextState = .neutral
                    }
                    store.updateNode(previewDraftNodeID) { draftNode in
                        draftNode.phase = .draft(nextState)
                    }
                    interaction.draftStatus = previewDraftStatusText(store.nodeLookup[previewDraftNodeID])
                    interaction.lastEvent = "Draft node switched to \(previewDraftPhaseText(.draft(nextState)).lowercased())."
                },
                toggleDraftTarget: {
                    guard store.nodeLookup[previewDraftNodeID] != nil else { return }
                    if store.connectionDraft == nil {
                        store.connectionDraft = ConnectionDraft(
                            sourceNodeID: "router",
                            sourceHandleID: "out",
                            sourceHandleType: .source,
                            sourceHandlePosition: .right,
                            currentPoint: previewDraftPoint
                        )
                    }
                    let nextTargetHandleID: String? =
                        store.connectionDraft?.targetHandleID == nil ? "in" : nil
                    store.connectionDraft?.targetNodeID = nextTargetHandleID == nil ? nil : previewDraftNodeID
                    store.connectionDraft?.targetHandleID = nextTargetHandleID
                    store.connectionDraft?.currentPoint = previewDraftPoint
                    interaction.draftTarget = previewDraftTargetText(nextTargetHandleID)
                    interaction.lastEvent =
                        nextTargetHandleID == nil
                        ? "Draft edge released from the node and now points at a free location."
                        : "Draft edge snapped to the draft node handle."
                },
                commitDraft: {
                    guard store.nodeLookup[previewDraftNodeID] != nil else { return }

                    if let draft = store.connectionDraft,
                       let targetNodeID = draft.targetNodeID,
                       targetNodeID == previewDraftNodeID {
                        let proposal: ConnectionProposal
                        if draft.sourceHandleType == .source {
                            proposal = ConnectionProposal(
                                sourceNodeID: draft.sourceNodeID,
                                sourceHandleID: draft.sourceHandleID,
                                targetNodeID: targetNodeID,
                                targetHandleID: draft.targetHandleID
                            )
                        } else {
                            proposal = ConnectionProposal(
                                sourceNodeID: targetNodeID,
                                sourceHandleID: draft.targetHandleID,
                                targetNodeID: draft.sourceNodeID,
                                targetHandleID: draft.sourceHandleID
                            )
                        }

                        let validator = store.configuration.connectionValidator ?? DefaultConnectionValidator()
                        if validator.validate(proposal) {
                            store.onConnect?(proposal)
                        } else {
                            store.onConnectionRejected?(proposal)
                        }
                    }

                    store.updateNode(previewDraftNodeID) { draftNode in
                        draftNode.phase = .normal
                        draftNode.persistence = .persistent
                    }
                    store.connectionDraft = nil
                    interaction.draftStatus = previewDraftStatusText(store.nodeLookup[previewDraftNodeID])
                    interaction.draftTarget = "No target"
                    interaction.lastEvent = "Committed the draft node and cleared the draft edge."
                },
                cycleEdgePathStyle: {
                    let nextPathType = previewNextEdgePathType(after: store.configuration.defaultEdgePathType)
                    store.configuration.defaultEdgePathType = nextPathType
                    store.updateEdges { edge in
                        edge.pathType = nextPathType
                    }
                    interaction.edgePathStyle = previewEdgePathStyleText(nextPathType)
                    interaction.lastEvent = "Switched all edges to \(previewEdgePathStyleText(nextPathType))."
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(12)

            VStack(alignment: .trailing, spacing: 8) {
                MiniMap(store: store, canvasSize: geometry.size)

                AnimationToolbar(store: store, canvasSize: geometry.size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(12)
        }
        .onAppear {
            store.onConnect = { [weak store, interaction] proposal in
                guard let store else { return }
                interaction.lastEvent = "Connected \(previewProposalText(proposal))."
                let edge = FlowEdge(
                    id: "e-\(UUID().uuidString.prefix(8))",
                    sourceNodeID: proposal.sourceNodeID,
                    sourceHandleID: proposal.sourceHandleID,
                    targetNodeID: proposal.targetNodeID,
                    targetHandleID: proposal.targetHandleID,
                    pathType: store.configuration.defaultEdgePathType
                )
                store.addEdge(edge)
            }
            store.onCanvasDoubleTap = { [interaction] point in
                interaction.lastCanvasDoubleTap = previewPointText(point)
                interaction.lastEvent = "Canvas double-tapped at \(previewPointText(point))."
            }
            store.onConnectionRejected = { [interaction] proposal in
                interaction.lastRejectedConnection = previewProposalText(proposal)
                interaction.lastEvent = "Rejected \(previewProposalText(proposal))."
            }
            if let draft = store.nodeLookup[previewDraftNodeID] {
                interaction.draftStatus = previewDraftStatusText(draft)
            }
            interaction.draftTarget =
                store.connectionDraft == nil
                ? "No target"
                : previewDraftTargetText(store.connectionDraft?.targetHandleID)
            interaction.edgePathStyle = previewEdgePathStyleText(store.configuration.defaultEdgePathType)
            store.fitToContent(canvasSize: geometry.size)
        }
    }
    .frame(minWidth: 800, minHeight: 600)
}

private struct AnimationToolbar: View {

    let store: FlowStore<PreviewNodeData>
    let canvasSize: CGSize

    @State private var isScattered = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                store.fitToContent(canvasSize: canvasSize, animation: .smooth)
            } label: {
                Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
            }

            Button {
                store.zoom(by: 1.5, anchor: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2), animation: .spring())
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
                    .font(.caption)
            }

            Button {
                store.zoom(by: 0.67, anchor: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2), animation: .spring())
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
                    .font(.caption)
            }

            Button {
                if isScattered {
                    // Restore original layout
                    var positions: [String: CGPoint] = [:]
                    let originalPositions: [(String, CGFloat, CGFloat)] = [
                        ("webhook", 30, 200), ("auth", 240, 200), ("router", 450, 200),
                        ("parse", 660, 60), ("transform", 870, 60), ("dbwrite", 1080, 60),
                        ("validate", 660, 200), ("enrich", 870, 200), ("apicall", 1080, 200),
                        ("cache", 660, 340), ("queue", 870, 340), ("retry", 1080, 340),
                        ("merge", 1290, 200), ("format", 1500, 200), ("notify", 1710, 200),
                    ]
                    for (id, x, y) in originalPositions {
                        positions[id] = CGPoint(x: x, y: y)
                    }
                    store.setNodePositions(positions, animation: .spring(response: 0.6, dampingFraction: 0.8))
                } else {
                    // Scatter nodes randomly
                    var positions: [String: CGPoint] = [:]
                    for node in store.nodes {
                        positions[node.id] = CGPoint(
                            x: CGFloat.random(in: 0...1500),
                            y: CGFloat.random(in: 0...600)
                        )
                    }
                    store.setNodePositions(positions, animation: .spring(response: 0.6, dampingFraction: 0.8))
                }
                isScattered.toggle()
            } label: {
                Label(isScattered ? "Restore" : "Scatter", systemImage: isScattered ? "arrow.uturn.backward" : "sparkles")
                    .font(.caption)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DragPalette: View {

    static let nodeTemplates: [DragPayload] = [
        DragPayload(kind: .nodeTemplate, title: "HTTP", subtitle: "Trigger", icon: "globe"),
        DragPayload(kind: .nodeTemplate, title: "Filter", subtitle: "Logic", icon: "line.3.horizontal.decrease"),
        DragPayload(kind: .nodeTemplate, title: "Map", subtitle: "Transform", icon: "arrow.left.arrow.right"),
        DragPayload(kind: .nodeTemplate, title: "Storage", subtitle: "Storage", icon: "cylinder"),
    ]

    static let nodeAttributes: [DragPayload] = [
        DragPayload(kind: .nodeAttribute, title: "Auth", subtitle: "Bearer Token", icon: "lock.shield"),
        DragPayload(kind: .nodeAttribute, title: "Cache", subtitle: "TTL 60s", icon: "clock.arrow.circlepath"),
        DragPayload(kind: .nodeAttribute, title: "Retry", subtitle: "Max 3", icon: "arrow.counterclockwise"),
    ]

    static let edgeAttributes: [DragPayload] = [
        DragPayload(kind: .edgeAttribute, title: "Success", subtitle: "solid", icon: "checkmark.circle"),
        DragPayload(kind: .edgeAttribute, title: "Error", subtitle: "dashed", icon: "xmark.circle"),
        DragPayload(kind: .edgeAttribute, title: "Async", subtitle: "animated", icon: "arrow.triangle.swap"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            paletteSection(title: "Nodes", color: .blue) {
                ForEach(Self.nodeTemplates, id: \.title) { item in
                    paletteDragRow(icon: item.icon, label: item.title, color: .blue)
                        .draggable(item) { dragPreview(icon: item.icon, label: item.title, color: .blue) }
                }
            }

            paletteSection(title: "Node Attrs", color: .orange) {
                ForEach(Self.nodeAttributes, id: \.title) { item in
                    paletteDragRow(icon: item.icon, label: item.title, color: .orange)
                        .draggable(item) { dragPreview(icon: item.icon, label: item.title, color: .orange) }
                }
            }

            paletteSection(title: "Edge Attrs", color: .green) {
                ForEach(Self.edgeAttributes, id: \.title) { item in
                    paletteDragRow(icon: item.icon, label: item.title, color: .green)
                        .draggable(item) { dragPreview(icon: item.icon, label: item.title, color: .green) }
                }
            }
        }
        .padding(8)
        .frame(width: 130)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func paletteSection<Content: View>(
        title: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func paletteDragRow(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 16)
            Text(label)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func dragPreview(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 16)
            Text(label)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Resize Preview

private struct ResizablePreviewData: Sendable, Hashable, Codable {
    var title: String
    var color: String
}

private enum ResizeCorner {
    case topLeft, topRight, bottomLeft, bottomRight

    func apply(startFrame: CGRect, canvasDelta: CGSize, minSize: CGSize) -> CGRect {
        var x = startFrame.minX
        var y = startFrame.minY
        var w = startFrame.width
        var h = startFrame.height
        switch self {
        case .topLeft:
            x = min(startFrame.minX + canvasDelta.width, startFrame.maxX - minSize.width)
            y = min(startFrame.minY + canvasDelta.height, startFrame.maxY - minSize.height)
            w = max(minSize.width, startFrame.width - canvasDelta.width)
            h = max(minSize.height, startFrame.height - canvasDelta.height)
        case .topRight:
            y = min(startFrame.minY + canvasDelta.height, startFrame.maxY - minSize.height)
            w = max(minSize.width, startFrame.width + canvasDelta.width)
            h = max(minSize.height, startFrame.height - canvasDelta.height)
        case .bottomLeft:
            x = min(startFrame.minX + canvasDelta.width, startFrame.maxX - minSize.width)
            w = max(minSize.width, startFrame.width - canvasDelta.width)
            h = max(minSize.height, startFrame.height + canvasDelta.height)
        case .bottomRight:
            w = max(minSize.width, startFrame.width + canvasDelta.width)
            h = max(minSize.height, startFrame.height + canvasDelta.height)
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

private struct ResizeHandleOverlay<Data: Sendable & Hashable>: View {
    let store: FlowStore<Data>
    let nodeID: String

    private let handleSize: CGFloat = 10
    private let minSize = CGSize(width: 40, height: 30)

    @State private var startFrame: CGRect?

    var body: some View {
        if let node = store.nodeLookup[nodeID] {
            let frameOnScreen = CGRect(
                origin: store.viewport.canvasToScreen(node.position),
                size: CGSize(
                    width: node.size.width * store.viewport.zoom,
                    height: node.size.height * store.viewport.zoom
                )
            )

            ZStack {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .frame(width: frameOnScreen.width, height: frameOnScreen.height)
                    .position(x: frameOnScreen.midX, y: frameOnScreen.midY)
                    .allowsHitTesting(false)

                handle(at: CGPoint(x: frameOnScreen.minX, y: frameOnScreen.minY), corner: .topLeft)
                handle(at: CGPoint(x: frameOnScreen.maxX, y: frameOnScreen.minY), corner: .topRight)
                handle(at: CGPoint(x: frameOnScreen.minX, y: frameOnScreen.maxY), corner: .bottomLeft)
                handle(at: CGPoint(x: frameOnScreen.maxX, y: frameOnScreen.maxY), corner: .bottomRight)
            }
        }
    }

    @ViewBuilder
    private func handle(at point: CGPoint, corner: ResizeCorner) -> some View {
        Rectangle()
            .fill(Color.white)
            .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5))
            .frame(width: handleSize, height: handleSize)
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard let node = store.nodeLookup[nodeID] else { return }
                        if startFrame == nil {
                            startFrame = node.frame
                            store.beginInteractiveUpdates()
                        }
                        guard let start = startFrame else { return }
                        let zoom = store.viewport.zoom
                        let canvasDelta = CGSize(
                            width: value.translation.width / zoom,
                            height: value.translation.height / zoom
                        )
                        let newFrame = corner.apply(
                            startFrame: start,
                            canvasDelta: canvasDelta,
                            minSize: minSize
                        )
                        store.updateNode(nodeID) { n in
                            n.position = newFrame.origin
                            n.size = newFrame.size
                        }
                    }
                    .onEnded { _ in
                        guard let start = startFrame else { return }
                        startFrame = nil
                        store.endInteractiveUpdates()
                        store.completeResizeNodes(from: [nodeID: start])
                    }
            )
    }
}

private struct ResizablePreviewNode: View {
    let node: FlowNode<ResizablePreviewData>
    let context: NodeRenderContext

    var body: some View {
        let inset = FlowHandle.diameter / 2
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(color.opacity(0.4), lineWidth: 1)
                )
                .overlay {
                    VStack(spacing: 4) {
                        Text(node.data.title)
                            .font(.headline)
                        Text("\(Int(node.size.width)) × \(Int(node.size.height))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(inset)

            FlowNodeHandles(node: node, context: context)
        }
        .frame(width: node.size.width + inset * 2, height: node.size.height + inset * 2)
    }

    private var color: Color {
        switch node.data.color {
        case "blue":   return .blue
        case "orange": return .orange
        case "green":  return .green
        default:       return .gray
        }
    }
}

private struct ResizableFlowPreview: View {
    @State private var store: FlowStore<ResizablePreviewData> = {
        let s = FlowStore<ResizablePreviewData>(
            nodes: [
                FlowNode(
                    id: "a",
                    position: CGPoint(x: 60, y: 80),
                    size: CGSize(width: 180, height: 100),
                    data: ResizablePreviewData(title: "Input", color: "blue")
                ),
                FlowNode(
                    id: "b",
                    position: CGPoint(x: 340, y: 140),
                    size: CGSize(width: 220, height: 140),
                    data: ResizablePreviewData(title: "Chart", color: "orange")
                ),
                FlowNode(
                    id: "c",
                    position: CGPoint(x: 660, y: 100),
                    size: CGSize(width: 160, height: 80),
                    data: ResizablePreviewData(title: "Output", color: "green")
                ),
            ],
            edges: [
                FlowEdge(id: "e1", sourceNodeID: "a", sourceHandleID: "source", targetNodeID: "b", targetHandleID: "target"),
                FlowEdge(id: "e2", sourceNodeID: "b", sourceHandleID: "source", targetNodeID: "c", targetHandleID: "target"),
            ]
        )
        return s
    }()

    @State private var undoManager = UndoManager()
    @State private var batchCount = 0
    @State private var lastBatchSize = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            FlowCanvas(store: store) { node, ctx in
                ResizablePreviewNode(node: node, context: ctx)
            }
            .overlay {
                ForEach(Array(store.selectedNodeIDs), id: \.self) { id in
                    ResizeHandleOverlay(store: store, nodeID: id)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Interactive Resize Demo").font(.headline)
                Text("1. Click a node to select  ")
                Text("2. Drag any corner handle to resize")
                Divider()
                HStack(spacing: 12) {
                    Text("onNodesChange batches: \(batchCount)")
                    Text("last batch size: \(lastBatchSize)")
                }
                .font(.caption.monospaced())
                HStack(spacing: 8) {
                    Button("Undo") { undoManager.undo() }
                        .disabled(!undoManager.canUndo)
                    Button("Redo") { undoManager.redo() }
                        .disabled(!undoManager.canRedo)
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
        }
        .onAppear {
            store.undoManager = undoManager
            store.onNodesChange = { changes in
                batchCount += 1
                lastBatchSize = changes.count
            }
        }
    }
}

#Preview("FlowCanvas - Resize API") {
    ResizableFlowPreview()
}

// MARK: - Live Node Preview (WKWebView)

#if canImport(WebKit)

private struct WebPreviewData: Sendable, Hashable {
    let url: URL
    let title: String
}

/// Holds the WKWebView instances that back the live overlay nodes so the
/// preview can call `takeSnapshot` on them independently of SwiftUI's
/// view lifecycle. Once a node's overlay appears, its WKWebView lands in
/// here and survives subsequent activation toggles.
@MainActor
@Observable
private final class WebViewBag {
    var webViews: [String: WKWebView] = [:]
}

#if os(iOS)
private struct WebNodeRepresentable: UIViewRepresentable {
    let nodeID: String
    let url: URL
    let cornerRadius: CGFloat
    let bag: WebViewBag

    func makeUIView(context: Context) -> WKWebView {
        let wv: WKWebView
        if let existing = bag.webViews[nodeID] {
            existing.removeFromSuperview()
            wv = existing
        } else {
            wv = WKWebView()
            wv.load(URLRequest(url: url))
            bag.webViews[nodeID] = wv
        }
        wv.layer.cornerRadius = cornerRadius
        wv.layer.masksToBounds = true
        wv.scrollView.layer.cornerRadius = cornerRadius
        wv.scrollView.layer.masksToBounds = true
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.layer.cornerRadius = cornerRadius
        uiView.scrollView.layer.cornerRadius = cornerRadius
    }
}
#elseif os(macOS)
private struct WebNodeRepresentable: NSViewRepresentable {
    let nodeID: String
    let url: URL
    let cornerRadius: CGFloat
    let bag: WebViewBag

    func makeNSView(context: Context) -> WKWebView {
        let wv: WKWebView
        if let existing = bag.webViews[nodeID] {
            existing.removeFromSuperview()
            wv = existing
        } else {
            wv = WKWebView()
            wv.load(URLRequest(url: url))
            bag.webViews[nodeID] = wv
        }
        wv.wantsLayer = true
        wv.layer?.cornerRadius = cornerRadius
        wv.layer?.masksToBounds = true
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.layer?.cornerRadius = cornerRadius
    }
}
#endif

private struct LiveOverlayFlowPreview: View {

    @State private var bag = WebViewBag()
    @State private var store: FlowStore<WebPreviewData> = {
        FlowStore<WebPreviewData>(
            nodes: [
                FlowNode(
                    id: "apple",
                    position: CGPoint(x: 60, y: 80),
                    size: CGSize(width: 360, height: 240),
                    data: WebPreviewData(
                        url: URL(string: "https://www.apple.com")!,
                        title: "apple.com"
                    )
                ),
                FlowNode(
                    id: "developer",
                    position: CGPoint(x: 520, y: 140),
                    size: CGSize(width: 360, height: 240),
                    data: WebPreviewData(
                        url: URL(string: "https://developer.apple.com")!,
                        title: "developer.apple.com"
                    )
                ),
            ],
            edges: [
                FlowEdge(
                    id: "e1",
                    sourceNodeID: "apple",
                    sourceHandleID: "source",
                    targetNodeID: "developer",
                    targetHandleID: "target"
                ),
            ]
        )
    }()

    var body: some View {
        ZStack(alignment: .topLeading) {
            // `.manual` capture: WKWebView cannot be rendered off-screen
            // by ImageRenderer, so the app takes WKWebView snapshots
            // itself and writes them to the store.
            FlowCanvas(store: store) { node, ctx in
                let inset = FlowHandle.diameter / 2
                let cornerRadius: CGFloat = 12
                let nodeID = node.id
                LiveNode(
                    node: node,
                    context: ctx,
                    capture: .manual(capture: { await captureSnapshot(nodeID: nodeID) })
                ) {
                    WebNodeRepresentable(
                        nodeID: nodeID,
                        url: node.data.url,
                        cornerRadius: cornerRadius,
                        bag: bag
                    )
                    .task(id: nodeID) {
                        await snapshotLoop(nodeID: nodeID)
                    }
                } placeholder: {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(node.data.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.08))
                }
                .frame(width: node.size.width, height: node.size.height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                .padding(inset)
                .overlay { FlowNodeHandles(node: node, context: ctx) }
            }
            .liveNodeActivation { node, store in
                store.selectedNodeIDs.contains(node.id)
                    || store.hoveredNodeID == node.id
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("WebView Live Node").font(.headline)
                Text("Hover or select a node to activate the live WKWebView.")
                Text("Snapshots are captured every second while active; the rasterized path replays the last one.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
        }
    }

    @MainActor
    private func snapshotLoop(nodeID: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            await captureSnapshot(nodeID: nodeID)
        }
    }

    @MainActor
    private func captureSnapshot(nodeID: String) async {
        guard let webView = bag.webViews[nodeID] else { return }
        let config = WKSnapshotConfiguration()
        do {
            let image = try await webView.takeSnapshot(configuration: config)
            #if os(iOS)
            guard let cgImage = image.cgImage else { return }
            let scale = image.scale
            #elseif os(macOS)
            var rect = CGRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
            let scale = CGFloat(cgImage.width) / max(image.size.width, 1)
            #endif
            store.setNodeSnapshot(
                FlowNodeSnapshot(cgImage: cgImage, scale: scale),
                for: nodeID
            )
        } catch {
            // snapshot failed (e.g., view not yet ready); skip this tick
        }
    }
}

#Preview("FlowCanvas - Live Node (WKWebView)") {
    LiveOverlayFlowPreview()
}

#endif

// MARK: - Live Node Preview (MKMapView)

#if canImport(MapKit)

import MapKit

private struct MapPreviewData: Sendable, Hashable {
    let latitude: Double
    let longitude: Double
    let title: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Retains MKMapView instances across overlay remount (viewport culling,
/// scroll-out → scroll-in) so panning / zooming state isn't lost when the
/// node briefly leaves the visible rect.
@MainActor
@Observable
private final class MapViewBag {
    var mapViews: [String: MKMapView] = [:]
}

#if os(iOS)
private struct MapNodeRepresentable: UIViewRepresentable {
    let nodeID: String
    let initialCoordinate: CLLocationCoordinate2D
    let cornerRadius: CGFloat
    let bag: MapViewBag

    func makeUIView(context: Context) -> MKMapView {
        let mv: MKMapView
        if let existing = bag.mapViews[nodeID] {
            existing.removeFromSuperview()
            mv = existing
        } else {
            mv = MKMapView()
            mv.setRegion(
                MKCoordinateRegion(
                    center: initialCoordinate,
                    latitudinalMeters: 3000,
                    longitudinalMeters: 3000
                ),
                animated: false
            )
            bag.mapViews[nodeID] = mv
        }
        mv.layer.cornerRadius = cornerRadius
        mv.layer.masksToBounds = true
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        if mv.layer.cornerRadius != cornerRadius {
            mv.layer.cornerRadius = cornerRadius
        }
    }
}
#elseif os(macOS)
private struct MapNodeRepresentable: NSViewRepresentable {
    let nodeID: String
    let initialCoordinate: CLLocationCoordinate2D
    let cornerRadius: CGFloat
    let bag: MapViewBag

    func makeNSView(context: Context) -> MKMapView {
        let mv: MKMapView
        if let existing = bag.mapViews[nodeID] {
            existing.removeFromSuperview()
            mv = existing
        } else {
            mv = MKMapView()
            mv.setRegion(
                MKCoordinateRegion(
                    center: initialCoordinate,
                    latitudinalMeters: 3000,
                    longitudinalMeters: 3000
                ),
                animated: false
            )
            bag.mapViews[nodeID] = mv
        }
        mv.wantsLayer = true
        mv.layer?.cornerRadius = cornerRadius
        mv.layer?.masksToBounds = true
        return mv
    }

    func updateNSView(_ mv: MKMapView, context: Context) {
        if mv.layer?.cornerRadius != cornerRadius {
            mv.layer?.cornerRadius = cornerRadius
        }
    }
}
#endif

/// Only mounts `MapNodeRepresentable` while the node is rendered active.
///
/// The overlay applies `opacity(0)` to inactive nodes, which pauses the
/// `CAMetalLayer` tile pipeline used by `MKMapView` — when the ancestor
/// opacity later flips back to `1` the Metal drawable never resumes and
/// the live map shows blank. Keeping the representable out of the view
/// tree while inactive sidesteps the issue entirely; the `MKMapView`
/// instance itself is retained in `MapViewBag` so pan / zoom state is
/// preserved across mount cycles.
///
/// Snapshot refresh is driven by the `LiveNode` coordinator via the
/// `.manual(capture:)` handler registered at the call site — no
/// `onChange(isActive)` trigger is needed here.
private struct MapNodeLive: View {
    let nodeID: String
    let initialCoordinate: CLLocationCoordinate2D
    let cornerRadius: CGFloat
    let bag: MapViewBag
    let seedSnapshot: () async -> Void

    @Environment(\.isFlowNodeActive) private var isActive

    var body: some View {
        Group {
            if isActive {
                MapNodeRepresentable(
                    nodeID: nodeID,
                    initialCoordinate: initialCoordinate,
                    cornerRadius: cornerRadius,
                    bag: bag
                )
            } else {
                Color.clear
            }
        }
        .task(id: nodeID) {
            await seedSnapshot()
        }
    }
}

/// Applies a drop shadow only on the rasterize pass. SwiftUI `.shadow`
/// forces an offscreen compositing group that `CAMetalLayer` drawables
/// don't participate in, so the live MKMapView keeps only its `CALayer`
/// cornerRadius and forgoes the shadow.
private struct PhaseGatedShadow: ViewModifier {
    @Environment(\.flowNodeRenderPhase) private var phase

    func body(content: Content) -> some View {
        switch phase {
        case .rasterize:
            content.shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        case .live:
            content
        }
    }
}

private struct MapOverlayFlowPreview: View {

    @State private var bag = MapViewBag()
    @State private var store: FlowStore<MapPreviewData> = {
        FlowStore<MapPreviewData>(
            nodes: [
                FlowNode(
                    id: "tokyo",
                    position: CGPoint(x: 60, y: 80),
                    size: CGSize(width: 360, height: 240),
                    data: MapPreviewData(
                        latitude: 35.6812,
                        longitude: 139.7671,
                        title: "Tokyo Station"
                    )
                ),
                FlowNode(
                    id: "kyoto",
                    position: CGPoint(x: 520, y: 140),
                    size: CGSize(width: 360, height: 240),
                    data: MapPreviewData(
                        latitude: 35.0116,
                        longitude: 135.7681,
                        title: "Kyoto"
                    )
                ),
                FlowNode(
                    id: "osaka",
                    position: CGPoint(x: 300, y: 420),
                    size: CGSize(width: 360, height: 240),
                    data: MapPreviewData(
                        latitude: 34.6937,
                        longitude: 135.5023,
                        title: "Osaka"
                    )
                ),
            ],
            edges: [
                FlowEdge(
                    id: "e1",
                    sourceNodeID: "tokyo",
                    sourceHandleID: "source",
                    targetNodeID: "kyoto",
                    targetHandleID: "target"
                ),
                FlowEdge(
                    id: "e2",
                    sourceNodeID: "kyoto",
                    sourceHandleID: "source",
                    targetNodeID: "osaka",
                    targetHandleID: "target"
                ),
            ]
        )
    }()

    var body: some View {
        ZStack(alignment: .topLeading) {
            // MKMapView can't be captured via ImageRenderer (Metal-backed),
            // so we use `.manual` capture and write snapshots from an
            // off-screen MKMapSnapshotter mirroring the live view's region.
            FlowCanvas(store: store) { node, ctx in
                let inset = FlowHandle.diameter / 2
                let cornerRadius: CGFloat = 12
                LiveNode(
                    node: node,
                    context: ctx,
                    capture: .manual(capture: { await captureMapSnapshot(for: node) })
                ) {
                    MapNodeLive(
                        nodeID: node.id,
                        initialCoordinate: node.data.coordinate,
                        cornerRadius: cornerRadius,
                        bag: bag,
                        seedSnapshot: { await captureMapSnapshot(for: node) }
                    )
                } placeholder: {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(node.data.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.08))
                }
                .frame(width: node.size.width, height: node.size.height)
                .modifier(PhaseGatedShadow())
                .padding(inset)
                .overlay { FlowNodeHandles(node: node, context: ctx) }
            }
            .liveNodeActivation { node, store in
                store.selectedNodeIDs.contains(node.id)
                    || store.hoveredNodeID == node.id
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("MKMapView Live Node").font(.headline)
                Text("Hover or select a node to pan and zoom the live map.")
                Text("Off-screen nodes are culled; scroll-in remounts and reseeds the snapshot.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
        }
    }

    @MainActor
    private func captureMapSnapshot(for node: FlowNode<MapPreviewData>) async {
        let options = MKMapSnapshotter.Options()
        // Use the live mapView's current region if available so user pans /
        // zooms show up in the rasterize path; fall back to the node's
        // initial coordinate until the view first mounts.
        if let mv = bag.mapViews[node.id] {
            options.region = mv.region
        } else {
            options.region = MKCoordinateRegion(
                center: node.data.coordinate,
                latitudinalMeters: 3000,
                longitudinalMeters: 3000
            )
        }
        options.size = node.size
        #if os(iOS)
        options.scale = 2
        #endif

        let snapshotter = MKMapSnapshotter(options: options)
        do {
            let snap = try await snapshotter.start()
            #if os(iOS)
            guard let cgImage = snap.image.cgImage else { return }
            let scale = snap.image.scale
            #elseif os(macOS)
            var rect = CGRect(origin: .zero, size: snap.image.size)
            guard let cgImage = snap.image.cgImage(
                forProposedRect: &rect,
                context: nil,
                hints: nil
            ) else { return }
            let scale = CGFloat(cgImage.width) / max(snap.image.size.width, 1)
            #endif
            store.setNodeSnapshot(
                FlowNodeSnapshot(cgImage: cgImage, scale: scale),
                for: node.id
            )
        } catch {
            // Snapshot failed (transient); next iteration will retry.
        }
    }
}

#Preview("FlowCanvas - Live Node (MKMapView)") {
    MapOverlayFlowPreview()
}

#endif
