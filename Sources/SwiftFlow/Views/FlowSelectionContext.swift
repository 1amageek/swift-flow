import SwiftUI

public struct FlowSelectionContext<NodeData: Sendable & Hashable>: Sendable {

    public let selectedNodeIDs: Set<String>
    public let selectedEdgeIDs: Set<String>
    public let nodes: [FlowNode<NodeData>]
    public let edges: [FlowEdge]
    public let nodeFramesInCanvas: [String: CGRect]
    public let nodeFramesInScreen: [String: CGRect]
    public let edgeFramesInCanvas: [String: CGRect]
    public let edgeFramesInScreen: [String: CGRect]
    public let boundsInCanvas: CGRect?
    public let boundsInScreen: CGRect?
    public let viewport: Viewport
    public let canvasSize: CGSize

    public init(
        selectedNodeIDs: Set<String>,
        selectedEdgeIDs: Set<String>,
        nodes: [FlowNode<NodeData>],
        edges: [FlowEdge],
        nodeFramesInCanvas: [String: CGRect],
        nodeFramesInScreen: [String: CGRect],
        edgeFramesInCanvas: [String: CGRect],
        edgeFramesInScreen: [String: CGRect],
        boundsInCanvas: CGRect?,
        boundsInScreen: CGRect?,
        viewport: Viewport,
        canvasSize: CGSize
    ) {
        self.selectedNodeIDs = selectedNodeIDs
        self.selectedEdgeIDs = selectedEdgeIDs
        self.nodes = nodes
        self.edges = edges
        self.nodeFramesInCanvas = nodeFramesInCanvas
        self.nodeFramesInScreen = nodeFramesInScreen
        self.edgeFramesInCanvas = edgeFramesInCanvas
        self.edgeFramesInScreen = edgeFramesInScreen
        self.boundsInCanvas = boundsInCanvas
        self.boundsInScreen = boundsInScreen
        self.viewport = viewport
        self.canvasSize = canvasSize
    }

    public var isEmpty: Bool {
        selectedNodeIDs.isEmpty && selectedEdgeIDs.isEmpty
    }
}

public enum SelectionDecorationLayer: Sendable, Hashable {
    case background
    case overlay
}

public enum SelectionAccessoryLayer: Sendable, Hashable {
    case background
    case overlay
}

struct SelectionDecorationDrawer<NodeData: Sendable & Hashable> {
    let layer: SelectionDecorationLayer
    let draw: (inout GraphicsContext, FlowSelectionContext<NodeData>) -> Void
}

struct SelectionAccessoryBuilder<NodeData: Sendable & Hashable> {
    let layer: SelectionAccessoryLayer
    let content: (FlowSelectionContext<NodeData>) -> AnyView
}

enum SelectionContextResolver {

    @MainActor
    static func resolve<NodeData: Sendable & Hashable>(
        store: FlowStore<NodeData>,
        canvasSize: CGSize
    ) -> FlowSelectionContext<NodeData>? {
        guard !store.selectedNodeIDs.isEmpty || !store.selectedEdgeIDs.isEmpty else {
            return nil
        }

        let selectedNodes = store.nodes.filter { store.selectedNodeIDs.contains($0.id) }
        let selectedEdges = store.edges.filter { store.selectedEdgeIDs.contains($0.id) }

        var nodeFramesInCanvas: [String: CGRect] = [:]
        var nodeFramesInScreen: [String: CGRect] = [:]
        var edgeFramesInCanvas: [String: CGRect] = [:]
        var edgeFramesInScreen: [String: CGRect] = [:]
        var framesInCanvas: [CGRect] = []

        for node in selectedNodes {
            let canvasFrame = node.frame
            let screenFrame = screenRect(from: canvasFrame, viewport: store.viewport)
            nodeFramesInCanvas[node.id] = canvasFrame
            nodeFramesInScreen[node.id] = screenFrame
            framesInCanvas.append(canvasFrame)
        }

        for edge in selectedEdges {
            guard let canvasFrame = edgeFrameInCanvas(edge: edge, store: store) else { continue }
            let screenFrame = screenRect(from: canvasFrame, viewport: store.viewport)
            edgeFramesInCanvas[edge.id] = canvasFrame
            edgeFramesInScreen[edge.id] = screenFrame
            framesInCanvas.append(canvasFrame)
        }

        let boundsInCanvas = union(framesInCanvas)
        let boundsInScreen = boundsInCanvas.map { screenRect(from: $0, viewport: store.viewport) }

        return FlowSelectionContext(
            selectedNodeIDs: store.selectedNodeIDs,
            selectedEdgeIDs: store.selectedEdgeIDs,
            nodes: selectedNodes,
            edges: selectedEdges,
            nodeFramesInCanvas: nodeFramesInCanvas,
            nodeFramesInScreen: nodeFramesInScreen,
            edgeFramesInCanvas: edgeFramesInCanvas,
            edgeFramesInScreen: edgeFramesInScreen,
            boundsInCanvas: boundsInCanvas,
            boundsInScreen: boundsInScreen,
            viewport: store.viewport,
            canvasSize: canvasSize
        )
    }

    @MainActor
    private static func edgeFrameInCanvas<NodeData: Sendable & Hashable>(
        edge: FlowEdge,
        store: FlowStore<NodeData>
    ) -> CGRect? {
        guard let source = store.handleInfo(nodeID: edge.sourceNodeID, handleID: edge.sourceHandleID),
              let target = store.handleInfo(nodeID: edge.targetNodeID, handleID: edge.targetHandleID)
        else {
            return nil
        }

        let calculator = FlowStore<NodeData>.pathCalculator(for: edge.pathType)
        let edgePath = calculator.path(
            from: source.point,
            sourcePosition: source.position,
            to: target.point,
            targetPosition: target.position
        )
        let sourceFrame = pointFrame(source.point)
        let targetFrame = pointFrame(target.point)
        let pathFrame = edgePath.path.boundingRect

        let baseFrame = pathFrame.isEmpty
            ? sourceFrame.union(targetFrame)
            : pathFrame.union(sourceFrame).union(targetFrame)
        return baseFrame.insetBy(dx: -1, dy: -1)
    }

    private static func pointFrame(_ point: CGPoint) -> CGRect {
        CGRect(x: point.x, y: point.y, width: 0, height: 0)
    }

    private static func screenRect(from canvasRect: CGRect, viewport: Viewport) -> CGRect {
        let origin = viewport.canvasToScreen(canvasRect.origin)
        let farPoint = viewport.canvasToScreen(CGPoint(x: canvasRect.maxX, y: canvasRect.maxY))
        return CGRect(
            x: min(origin.x, farPoint.x),
            y: min(origin.y, farPoint.y),
            width: abs(farPoint.x - origin.x),
            height: abs(farPoint.y - origin.y)
        )
    }

    private static func union(_ frames: [CGRect]) -> CGRect? {
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { partial, frame in
            partial.union(frame)
        }
    }
}
