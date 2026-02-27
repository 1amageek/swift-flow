import SwiftUI

public struct FlowCanvas<
    NodeData: Sendable & Hashable,
    Content: NodeContent
>: View where Content.NodeData == NodeData {

    @Bindable var store: FlowStore<NodeData>
    @Environment(\.colorScheme) private var colorScheme

    public init(store: FlowStore<NodeData>) {
        self.store = store
    }

    // MARK: - Drag State

    @State private var dragMode: CanvasDragMode = .none
    @State private var lastPanTranslation: CGSize = .zero

    // MARK: - Magnify State

    @State private var lastMagnification: CGFloat = 1.0

    public var body: some View {
        GeometryReader { geometry in
            canvasBody(in: geometry.size)
        }
    }

    @ViewBuilder
    private func canvasBody(in size: CGSize) -> some View {
        let canvasView = Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, canvasSize in
            drawBackground(context: &context, canvasSize: canvasSize)
            drawEdges(context: &context, canvasSize: canvasSize)
            drawNodes(context: &context, canvasSize: canvasSize)
            drawSelectionRect(context: &context)
            drawConnectionDraft(context: &context, canvasSize: canvasSize)
        } symbols: {
            ForEach(store.nodes) { node in
                Content(node: node)
                    .tag(node.id)
            }
        }
        .gesture(primaryDragGesture)
        .gesture(selectionGesture)
        .gesture(magnifyGesture)
        .onTapGesture { location in
            handleTap(at: location)
        }

        #if os(macOS)
        CanvasHostView(
            onScroll: { delta, location in
                store.pan(by: delta)
            },
            onMagnify: { magnification, location in
                store.zoom(by: 1 + magnification, anchor: location)
            },
            cursorAt: { location in
                switch dragMode {
                case .pan:
                    return .closedHand
                case .nodeMove:
                    return .closedHand
                case .connection:
                    return .crosshair
                case .none:
                    let canvasPoint = store.viewport.screenToCanvas(location)
                    if store.hitTestHandle(at: canvasPoint) != nil {
                        return .crosshair
                    }
                    if let nodeID = store.hitTestNode(at: canvasPoint),
                       let node = store.nodeLookup[nodeID],
                       node.isDraggable {
                        return .openHand
                    }
                    return .arrow
                }
            }
        ) {
            canvasView
        }
        #else
        canvasView
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

    // MARK: - Drawing: Edges

    private func drawEdges(context: inout GraphicsContext, canvasSize: CGSize) {
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

            let calculator = pathCalculator(for: edge.pathType)
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
            let strokeStyle = StrokeStyle(lineWidth: style.lineWidth, dash: style.animatedDashPattern)
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

        let sortedNodes = store.nodes.sorted { $0.zIndex < $1.zIndex }

        for node in sortedNodes {
            let screenOrigin = viewport.canvasToScreen(node.position)
            let screenSize = CGSize(
                width: node.size.width * viewport.zoom,
                height: node.size.height * viewport.zoom
            )
            let screenRect = CGRect(origin: screenOrigin, size: screenSize)

            // Viewport culling
            let visibleRect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: -margin, dy: -margin)
            guard visibleRect.intersects(screenRect) else { continue }

            if let resolved = context.resolveSymbol(id: node.id) {
                context.draw(resolved, in: screenRect)
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
        let calculator = pathCalculator(for: store.configuration.defaultEdgePathType)
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
                        dragMode = .nodeMove(nodeID: nodeID, startPosition: node.position)
                    } else if store.configuration.panEnabled {
                        dragMode = .pan
                        lastPanTranslation = .zero
                    }
                }

                switch dragMode {
                case .none:
                    break
                case .pan:
                    let delta = CGSize(
                        width: value.translation.width - lastPanTranslation.width,
                        height: value.translation.height - lastPanTranslation.height
                    )
                    store.pan(by: delta)
                    lastPanTranslation = value.translation
                case .nodeMove(let nodeID, let startPosition):
                    let delta = CGSize(
                        width: value.translation.width / store.viewport.zoom,
                        height: value.translation.height / store.viewport.zoom
                    )
                    store.moveNode(nodeID, to: CGPoint(
                        x: startPosition.x + delta.width,
                        y: startPosition.y + delta.height
                    ))
                case .connection:
                    store.updateConnection(to: value.location)
                }
            }
            .onEnded { value in
                switch dragMode {
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
                default:
                    break
                }
                dragMode = .none
                lastPanTranslation = .zero
            }
    }

    #if os(macOS)
    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .modifiers(.shift)
            .onChanged { value in
                guard store.configuration.selectionEnabled,
                      store.configuration.multiSelectionEnabled else { return }
                let canvasStart = store.viewport.screenToCanvas(value.startLocation)
                let canvasCurrent = store.viewport.screenToCanvas(value.location)
                let rect = SelectionRect(
                    origin: canvasStart,
                    size: CGSize(
                        width: canvasCurrent.x - canvasStart.x,
                        height: canvasCurrent.y - canvasStart.y
                    )
                )
                store.selectionRect = rect
                store.selectNodesInRect(rect)
            }
            .onEnded { _ in
                store.selectionRect = nil
            }
    }
    #else
    private var selectionGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 5))
            .onChanged { value in
                guard store.configuration.selectionEnabled,
                      store.configuration.multiSelectionEnabled else { return }
                if case .second(true, let drag?) = value {
                    let canvasStart = store.viewport.screenToCanvas(drag.startLocation)
                    let canvasCurrent = store.viewport.screenToCanvas(drag.location)
                    let rect = SelectionRect(
                        origin: canvasStart,
                        size: CGSize(
                            width: canvasCurrent.x - canvasStart.x,
                            height: canvasCurrent.y - canvasStart.y
                        )
                    )
                    store.selectionRect = rect
                    store.selectNodesInRect(rect)
                }
            }
            .onEnded { _ in
                store.selectionRect = nil
            }
    }
    #endif

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

    private func handleTap(at location: CGPoint) {
        let canvasPoint = store.viewport.screenToCanvas(location)

        if let nodeID = store.hitTestNode(at: canvasPoint) {
            store.selectNode(nodeID)
        } else if let edgeID = store.hitTestEdge(at: canvasPoint) {
            store.selectEdge(edgeID)
        } else {
            store.clearSelection()
        }
    }

    // MARK: - Helpers

    private func transformedPath(_ path: Path, viewport: Viewport) -> Path {
        let transform = CGAffineTransform(scaleX: viewport.zoom, y: viewport.zoom)
            .concatenating(CGAffineTransform(translationX: viewport.offset.x, y: viewport.offset.y))
        return Path(path.cgPath.copy(using: [transform]) ?? path.cgPath)
    }

    private func pathCalculator(for type: EdgePathType) -> any EdgePathCalculating {
        switch type {
        case .bezier: BezierEdgePath()
        case .straight: StraightEdgePath()
        case .smoothStep: SmoothStepEdgePath()
        case .simpleBezier: SimpleBezierEdgePath()
        }
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
    case pan
    case nodeMove(nodeID: String, startPosition: CGPoint)
    case connection(HandleHitResult)
}

// MARK: - Preview

#Preview("FlowCanvas") {
    @Previewable @State var store: FlowStore<String> = {
        let h = [
            HandleDeclaration(id: "target", type: .target, position: .left),
            HandleDeclaration(id: "source", type: .source, position: .right),
        ]
        let store = FlowStore<String>(
            nodes: [
                FlowNode(id: "start", position: CGPoint(x: 30, y: 150), size: CGSize(width: 120, height: 50), data: "Start", handles: h),
                FlowNode(id: "process", position: CGPoint(x: 220, y: 80), size: CGSize(width: 120, height: 50), data: "Process", handles: h),
                FlowNode(id: "condition", position: CGPoint(x: 220, y: 220), size: CGSize(width: 120, height: 50), data: "Condition", handles: h),
                FlowNode(id: "approve", position: CGPoint(x: 420, y: 80), size: CGSize(width: 120, height: 50), data: "Approve", handles: h),
                FlowNode(id: "reject", position: CGPoint(x: 420, y: 220), size: CGSize(width: 120, height: 50), data: "Reject", handles: h),
                FlowNode(id: "end", position: CGPoint(x: 610, y: 150), size: CGSize(width: 120, height: 50), data: "End", handles: h),
            ],
            edges: [
                FlowEdge(id: "e1", sourceNodeID: "start", sourceHandleID: "source", targetNodeID: "process", targetHandleID: "target"),
                FlowEdge(id: "e2", sourceNodeID: "start", sourceHandleID: "source", targetNodeID: "condition", targetHandleID: "target"),
                FlowEdge(id: "e3", sourceNodeID: "process", sourceHandleID: "source", targetNodeID: "approve", targetHandleID: "target"),
                FlowEdge(id: "e4", sourceNodeID: "condition", sourceHandleID: "source", targetNodeID: "reject", targetHandleID: "target", label: "No"),
                FlowEdge(id: "e5", sourceNodeID: "approve", sourceHandleID: "source", targetNodeID: "end", targetHandleID: "target"),
                FlowEdge(id: "e6", sourceNodeID: "reject", sourceHandleID: "source", targetNodeID: "end", targetHandleID: "target"),
            ]
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
    FlowCanvas<String, DefaultNodeContent<String>>(store: store)
        .frame(minWidth: 800, minHeight: 600)
}
