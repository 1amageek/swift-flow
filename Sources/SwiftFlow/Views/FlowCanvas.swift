import SwiftUI

public struct FlowCanvas<
    NodeData: Sendable & Hashable,
    NodeView: View
>: View {

    @Bindable var store: FlowStore<NodeData>
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.undoManager) private var undoManager

    private let nodeContentBuilder: (FlowNode<NodeData>) -> NodeView
    private let edgeContentBuilder: ((FlowEdge, EdgeGeometry) -> AnyView)?

    // MARK: - Init: Default

    public init(store: FlowStore<NodeData>) where NodeView == DefaultNodeContent<NodeData> {
        self.store = store
        self.nodeContentBuilder = { node in DefaultNodeContent(node: node) }
        self.edgeContentBuilder = nil
    }

    // MARK: - Init: Custom nodes

    public init(
        store: FlowStore<NodeData>,
        @ViewBuilder nodeContent: @escaping (FlowNode<NodeData>) -> NodeView
    ) {
        self.store = store
        self.nodeContentBuilder = nodeContent
        self.edgeContentBuilder = nil
    }

    // MARK: - Init: Custom nodes + custom edges

    public init<EdgeView: View>(
        store: FlowStore<NodeData>,
        @ViewBuilder nodeContent: @escaping (FlowNode<NodeData>) -> NodeView,
        @ViewBuilder edgeContent: @escaping (FlowEdge, EdgeGeometry) -> EdgeView
    ) {
        self.store = store
        self.nodeContentBuilder = nodeContent
        self.edgeContentBuilder = { edge, geometry in AnyView(edgeContent(edge, geometry)) }
    }

    // MARK: - Init: Default nodes + custom edges

    public init<EdgeView: View>(
        store: FlowStore<NodeData>,
        @ViewBuilder edgeContent: @escaping (FlowEdge, EdgeGeometry) -> EdgeView
    ) where NodeView == DefaultNodeContent<NodeData> {
        self.store = store
        self.nodeContentBuilder = { node in DefaultNodeContent(node: node) }
        self.edgeContentBuilder = { edge, geometry in AnyView(edgeContent(edge, geometry)) }
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
                nodeContentBuilder(node)
                    .tag(node.id)
            }
            if let edgeContentBuilder {
                ForEach(store.edges) { edge in
                    edgeSymbolView(edge: edge, builder: edgeContentBuilder)
                }
            }
        }
        .gesture(primaryDragGesture)
        .gesture(magnifyGesture)
        .gesture(
            SpatialTapGesture()
                .modifiers(.command)
                .onEnded { value in
                    handleTap(at: value.location, isAdditive: true)
                }
        )
        .onTapGesture { location in
            handleTap(at: location, isAdditive: false)
        }
        .onDisappear {
            #if os(macOS)
            releaseDragCursorIfNeeded()
            #endif
        }
        .focusable()
        .onKeyPress(.delete) {
            store.deleteSelection()
            return .handled
        }
        .onKeyPress(.deleteForward) {
            store.deleteSelection()
            return .handled
        }
        .onAppear {
            store.undoManager = undoManager
        }
        .onChange(of: undoManager) { _, newValue in
            store.undoManager = newValue
        }

        #if os(macOS)
        CanvasHostView(
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
            }
        ) {
            canvasView
        }
        #else
        CanvasHostView(
            onPan: { delta in
                guard store.configuration.panEnabled else { return }
                store.pan(by: delta)
            }
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
        #endif
    }

    // MARK: - Drawing: Background

    private func drawBackground(context: inout GraphicsContext, canvasSize: CGSize) {
        let style = store.configuration.backgroundStyle
        guard style.pattern != .none else { return }

        let viewport = store.viewport
        let spacing = style.spacing * viewport.zoom

        // Avoid drawing when spacing is too small to be visible
        guard spacing > 2 else { return }

        // Calculate visible canvas range and snap to grid lines
        let topLeft = viewport.screenToCanvas(.zero)
        let bottomRight = viewport.screenToCanvas(CGPoint(x: canvasSize.width, y: canvasSize.height))

        let startX = (topLeft.x / style.spacing).rounded(.down) * style.spacing
        let startY = (topLeft.y / style.spacing).rounded(.down) * style.spacing
        let endX = (bottomRight.x / style.spacing).rounded(.up) * style.spacing
        let endY = (bottomRight.y / style.spacing).rounded(.up) * style.spacing

        switch style.pattern {
        case .none:
            break

        case .grid:
            var gridPath = Path()

            // Vertical lines
            var x = startX
            while x <= endX {
                let screenX = x * viewport.zoom + viewport.offset.x
                gridPath.move(to: CGPoint(x: screenX, y: 0))
                gridPath.addLine(to: CGPoint(x: screenX, y: canvasSize.height))
                x += style.spacing
            }

            // Horizontal lines
            var y = startY
            while y <= endY {
                let screenY = y * viewport.zoom + viewport.offset.y
                gridPath.move(to: CGPoint(x: 0, y: screenY))
                gridPath.addLine(to: CGPoint(x: canvasSize.width, y: screenY))
                y += style.spacing
            }

            context.stroke(
                gridPath,
                with: .color(style.color),
                style: StrokeStyle(lineWidth: style.lineWidth)
            )

        case .dot:
            var dotPath = Path()

            var x = startX
            while x <= endX {
                var y = startY
                while y <= endY {
                    let screenX = x * viewport.zoom + viewport.offset.x
                    let screenY = y * viewport.zoom + viewport.offset.y
                    dotPath.addEllipse(in: CGRect(
                        x: screenX - style.dotRadius,
                        y: screenY - style.dotRadius,
                        width: style.dotRadius * 2,
                        height: style.dotRadius * 2
                    ))
                    y += style.spacing
                }
                x += style.spacing
            }

            context.fill(dotPath, with: .color(style.color))
        }
    }

    // MARK: - Drawing: Edges (GraphicsContext batch)

    private func drawEdgesViaGraphicsContext(context: inout GraphicsContext, canvasSize: CGSize) {
        let style = store.configuration.edgeStyle
        let viewport = store.viewport

        var normalPath = Path()
        var selectedPath = Path()
        var animatedPath = Path()
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

            if edge.isSelected {
                selectedPath.addPath(transformed)
            } else if edge.isAnimated {
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
        let screenTo = draft.currentPoint

        let targetPosition = inferTargetPosition(from: screenFrom, to: screenTo)
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
                    store.updateConnection(to: value.location)
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
                    let targetType: HandleType = (handle.handleType == .source) ? .target : .source
                    if let target = store.findNearestHandle(
                        at: canvasPoint, excludingNodeID: handle.nodeID,
                        targetType: targetType, threshold: 20
                    ) {
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
            currentTarget = .none
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
        case .none:
            if !isAdditive {
                store.clearSelection()
            }
        }

        // Double-tap detection (only for non-additive taps on actual targets)
        if !isAdditive, currentTarget != .none {
            if doubleTapDetector.recordTap(target: currentTarget) {
                switch currentTarget {
                case .node(let nodeID):
                    store.onNodeDoubleTap?(nodeID)
                case .edge(let edgeID):
                    store.onEdgeDoubleTap?(edgeID)
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

private struct PreviewNodeData: Sendable, Hashable {
    let title: String
    let category: String
    let icon: String
    var badge: String?
    var subtitle: String?
}

private struct PreviewNode: View {

    let node: FlowNode<PreviewNodeData>
    static var handleInset: CGFloat { FlowHandle.diameter / 2 }

    init(_ node: FlowNode<PreviewNodeData>) {
        self.node = node
    }

    var body: some View {
        let inset = Self.handleInset

        ZStack {
            card.padding(inset)

            ForEach(node.handles, id: \.id) { handle in
                FlowHandle(handle.id, type: handle.type, position: handle.position)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: handleAlignment(handle.position))
            }
        }
        .frame(width: node.size.width + inset * 2, height: node.size.height + inset * 2)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.background)
            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
            .shadow(
                color: node.isSelected ? Color.accentColor.opacity(0.4)
                     : node.isHovered ? .black.opacity(0.14)
                     : .black.opacity(0.08),
                radius: node.isSelected ? 8 : node.isHovered ? 5 : 3,
                y: node.isSelected ? 0 : node.isHovered ? 1 : 2
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        node.isSelected ? Color.accentColor
                          : node.isHovered ? Color.primary.opacity(0.25)
                          : Color.primary.opacity(0.1),
                        lineWidth: node.isSelected ? 1.5 : node.isHovered ? 0.75 : 0.5
                    )
            }
            .overlay(alignment: .leading) { cardContent }
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
        case "Logic":     .purple
        case "Data":      .blue
        case "Transform": .teal
        case "Storage":   .indigo
        case "Network":   .cyan
        case "Queue":     .brown
        case "Output":    .green
        default:          .gray
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
                FlowEdge(id: "e01", sourceNodeID: "webhook", sourceHandleID: "out", targetNodeID: "auth",     targetHandleID: "in", isAnimated: true),
                FlowEdge(id: "e02", sourceNodeID: "auth",    sourceHandleID: "out", targetNodeID: "router",   targetHandleID: "in", isAnimated: true),
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
                backgroundStyle: BackgroundStyle(pattern: .dot)
            )
        )
        store.onConnect = { [weak store] proposal in
            guard let store else { return }
            let edge = FlowEdge(
                id: "e-\(UUID().uuidString.prefix(8))",
                sourceNodeID: proposal.sourceNodeID,
                sourceHandleID: proposal.sourceHandleID,
                targetNodeID: proposal.targetNodeID,
                targetHandleID: proposal.targetHandleID
            )
            store.addEdge(edge)
        }
        return store
    }()
    GeometryReader { geometry in
        ZStack(alignment: .bottomTrailing) {
            FlowCanvas(store: store) { node in
                PreviewNode(node)
            }

            VStack(alignment: .trailing, spacing: 8) {
                MiniMap(store: store, canvasSize: geometry.size)

                AnimationToolbar(store: store, canvasSize: geometry.size)
            }
            .padding(12)
        }
        .onAppear {
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
