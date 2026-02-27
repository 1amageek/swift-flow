import SwiftUI

@MainActor
@Observable
public final class FlowStore<Data: Sendable & Hashable> {

    // MARK: - Public State

    public private(set) var nodes: [FlowNode<Data>] = []
    public private(set) var edges: [FlowEdge] = []
    public var viewport: Viewport
    public var selectedNodeIDs: Set<String>
    public var selectedEdgeIDs: Set<String>
    public var configuration: FlowConfiguration

    // MARK: - Lookup Tables

    public private(set) var nodeLookup: [String: FlowNode<Data>] = [:]
    public private(set) var connectionLookup: [String: [FlowEdge]] = [:]

    // MARK: - Internal State

    var connectionDraft: ConnectionDraft?
    var selectionRect: SelectionRect?

    // MARK: - Callbacks

    public var onNodesChange: (([NodeChange<Data>]) -> Void)?
    public var onEdgesChange: (([EdgeChange]) -> Void)?
    public var onConnect: ((ConnectionProposal) -> Void)?

    // MARK: - Init

    public init(
        nodes: [FlowNode<Data>] = [],
        edges: [FlowEdge] = [],
        viewport: Viewport = Viewport(),
        configuration: FlowConfiguration = FlowConfiguration()
    ) {
        self.nodes = nodes
        self.edges = edges
        self.viewport = viewport
        self.selectedNodeIDs = []
        self.selectedEdgeIDs = []
        self.configuration = configuration
        rebuildNodeLookup()
        rebuildConnectionLookup()
    }

    // MARK: - Node Operations

    public func addNode(_ node: FlowNode<Data>) {
        nodes.append(node)
        nodeLookup[node.id] = node
        onNodesChange?([.add(node)])
    }

    public func removeNode(_ nodeID: String) {
        nodes.removeAll { $0.id == nodeID }
        nodeLookup.removeValue(forKey: nodeID)

        selectedNodeIDs.remove(nodeID)

        let removedEdges = edges.filter { $0.sourceNodeID == nodeID || $0.targetNodeID == nodeID }
        edges.removeAll { $0.sourceNodeID == nodeID || $0.targetNodeID == nodeID }
        rebuildConnectionLookup()

        for edge in removedEdges {
            selectedEdgeIDs.remove(edge.id)
        }

        onNodesChange?([.remove(nodeID: nodeID)])
        if !removedEdges.isEmpty {
            onEdgesChange?(removedEdges.map { .remove(edgeID: $0.id) })
        }
    }

    public func moveNode(_ nodeID: String, to position: CGPoint) {
        let snapped = configuration.snapped(position)
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        nodes[index].position = snapped
        nodeLookup[nodeID] = nodes[index]
        onNodesChange?([.position(nodeID: nodeID, position: snapped)])
    }

    public func updateNodeSize(_ nodeID: String, size: CGSize) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        nodes[index].size = size
        nodeLookup[nodeID] = nodes[index]
        onNodesChange?([.dimensions(nodeID: nodeID, size: size)])
    }

    // MARK: - Edge Operations

    public func addEdge(_ edge: FlowEdge) {
        edges.append(edge)
        connectionLookup[edge.sourceNodeID, default: []].append(edge)
        connectionLookup[edge.targetNodeID, default: []].append(edge)
        onEdgesChange?([.add(edge)])
    }

    public func removeEdge(_ edgeID: String) {
        edges.removeAll { $0.id == edgeID }
        rebuildConnectionLookup()

        selectedEdgeIDs.remove(edgeID)

        onEdgesChange?([.remove(edgeID: edgeID)])
    }

    // MARK: - Selection

    public func selectNode(_ nodeID: String, exclusive: Bool = true) {
        let shouldExclusive = exclusive || !configuration.multiSelectionEnabled
        if shouldExclusive {
            clearSelection()
        }
        selectedNodeIDs.insert(nodeID)
        if let index = nodes.firstIndex(where: { $0.id == nodeID }) {
            nodes[index].isSelected = true
            nodeLookup[nodeID] = nodes[index]
            onNodesChange?([.select(nodeID: nodeID, isSelected: true)])
        }
    }

    public func deselectNode(_ nodeID: String) {
        selectedNodeIDs.remove(nodeID)
        if let index = nodes.firstIndex(where: { $0.id == nodeID }) {
            nodes[index].isSelected = false
            nodeLookup[nodeID] = nodes[index]
            onNodesChange?([.select(nodeID: nodeID, isSelected: false)])
        }
    }

    public func selectEdge(_ edgeID: String, exclusive: Bool = true) {
        let shouldExclusive = exclusive || !configuration.multiSelectionEnabled
        if shouldExclusive {
            clearSelection()
        }
        selectedEdgeIDs.insert(edgeID)
        if let index = edges.firstIndex(where: { $0.id == edgeID }) {
            edges[index].isSelected = true
            onEdgesChange?([.select(edgeID: edgeID, isSelected: true)])
        }
    }

    public func deselectEdge(_ edgeID: String) {
        selectedEdgeIDs.remove(edgeID)
        if let index = edges.firstIndex(where: { $0.id == edgeID }) {
            edges[index].isSelected = false
            onEdgesChange?([.select(edgeID: edgeID, isSelected: false)])
        }
    }

    public func clearSelection() {
        for nodeID in selectedNodeIDs {
            if let index = nodes.firstIndex(where: { $0.id == nodeID }) {
                nodes[index].isSelected = false
                nodeLookup[nodeID] = nodes[index]
            }
        }
        for edgeID in selectedEdgeIDs {
            if let index = edges.firstIndex(where: { $0.id == edgeID }) {
                edges[index].isSelected = false
            }
        }
        selectedNodeIDs.removeAll()
        selectedEdgeIDs.removeAll()
    }

    public func selectNodesInRect(_ rect: SelectionRect) {
        guard configuration.multiSelectionEnabled else { return }

        let selectionFrame = rect.rect
        var newSelectedNodeIDs = Set<String>()
        for index in nodes.indices {
            let nodeFrame = nodes[index].frame
            let isInSelection = selectionFrame.intersects(nodeFrame)
            nodes[index].isSelected = isInSelection
            nodeLookup[nodes[index].id] = nodes[index]
            if isInSelection {
                newSelectedNodeIDs.insert(nodes[index].id)
            }
        }
        selectedNodeIDs = newSelectedNodeIDs
    }

    // MARK: - Viewport

    public func pan(by delta: CGSize) {
        guard configuration.panEnabled else { return }
        viewport.offset.x += delta.width
        viewport.offset.y += delta.height
    }

    public func zoom(by factor: CGFloat, anchor: CGPoint) {
        guard configuration.zoomEnabled else { return }
        let newZoom = max(
            configuration.minZoom,
            min(configuration.maxZoom, viewport.zoom * factor)
        )
        let oldZoom = viewport.zoom
        viewport.zoom = newZoom
        let scale = newZoom / oldZoom
        viewport.offset.x = anchor.x - (anchor.x - viewport.offset.x) * scale
        viewport.offset.y = anchor.y - (anchor.y - viewport.offset.y) * scale
    }

    public func fitToContent(canvasSize: CGSize, padding: CGFloat = 50) {
        guard !nodes.isEmpty else { return }
        let bounds = nodeBounds()
        let contentWidth = bounds.width + padding * 2
        let contentHeight = bounds.height + padding * 2
        guard contentWidth > 0, contentHeight > 0 else { return }

        viewport.zoom = min(1.0, min(
            canvasSize.width / contentWidth,
            canvasSize.height / contentHeight
        ))
        viewport.offset = CGPoint(
            x: -bounds.minX * viewport.zoom + (canvasSize.width - bounds.width * viewport.zoom) / 2,
            y: -bounds.minY * viewport.zoom + (canvasSize.height - bounds.height * viewport.zoom) / 2
        )
    }

    // MARK: - Connection Draft

    func beginConnection(nodeID: String, handleID: String?, handleType: HandleType, handlePosition: HandlePosition) {
        guard connectionDraft == nil else { return }
        connectionDraft = ConnectionDraft(
            sourceNodeID: nodeID,
            sourceHandleID: handleID,
            sourceHandleType: handleType,
            sourceHandlePosition: handlePosition,
            currentPoint: .zero
        )
    }

    func updateConnection(to point: CGPoint) {
        connectionDraft?.currentPoint = point
    }

    func endConnection(targetNodeID: String, targetHandleID: String?) {
        guard let draft = connectionDraft else { return }
        let proposal: ConnectionProposal
        if draft.sourceHandleType == .source {
            proposal = ConnectionProposal(
                sourceNodeID: draft.sourceNodeID,
                sourceHandleID: draft.sourceHandleID,
                targetNodeID: targetNodeID,
                targetHandleID: targetHandleID
            )
        } else {
            proposal = ConnectionProposal(
                sourceNodeID: targetNodeID,
                sourceHandleID: targetHandleID,
                targetNodeID: draft.sourceNodeID,
                targetHandleID: draft.sourceHandleID
            )
        }
        let validator = configuration.connectionValidator ?? DefaultConnectionValidator()
        if validator.validate(proposal) {
            onConnect?(proposal)
        }
        connectionDraft = nil
    }

    func cancelConnection() {
        connectionDraft = nil
    }

    // MARK: - Handle Info (computed from HandleDeclaration)

    func handleInfo(nodeID: String, handleID: String?) -> HandleInfo? {
        guard let node = nodeLookup[nodeID] else { return nil }

        guard let handleID else {
            return HandleInfo(
                point: CGPoint(x: node.position.x + node.size.width / 2, y: node.position.y + node.size.height / 2),
                position: .right,
                type: .source
            )
        }

        guard let decl = node.handles.first(where: { $0.id == handleID }) else { return nil }
        let point = handlePoint(for: decl.position, in: node)
        return HandleInfo(point: point, position: decl.position, type: decl.type)
    }

    func findNearestHandle(at canvasPoint: CGPoint, excludingNodeID: String, targetType: HandleType, threshold: CGFloat = 20) -> (nodeID: String, handleID: String)? {
        var bestDistance: CGFloat = threshold
        var bestResult: (nodeID: String, handleID: String)?

        for node in nodes {
            guard node.id != excludingNodeID else { continue }
            for handle in node.handles {
                guard handle.type == targetType else { continue }
                let point = handlePoint(for: handle.position, in: node)
                let distance = hypot(canvasPoint.x - point.x, canvasPoint.y - point.y)
                if distance < bestDistance {
                    bestDistance = distance
                    bestResult = (nodeID: node.id, handleID: handle.id)
                }
            }
        }

        return bestResult
    }

    // MARK: - Hit Testing

    func hitTestHandle(at canvasPoint: CGPoint, threshold: CGFloat = 10) -> HandleHitResult? {
        var bestDistance: CGFloat = threshold
        var bestResult: HandleHitResult?

        for node in nodes.reversed() {
            for handle in node.handles {
                let point = handlePoint(for: handle.position, in: node)
                let distance = hypot(canvasPoint.x - point.x, canvasPoint.y - point.y)
                if distance < bestDistance {
                    bestDistance = distance
                    bestResult = HandleHitResult(
                        nodeID: node.id,
                        handleID: handle.id,
                        handleType: handle.type,
                        handlePosition: handle.position
                    )
                }
            }
        }

        return bestResult
    }

    func hitTestNode(at canvasPoint: CGPoint) -> String? {
        for node in nodes.reversed() {
            if node.frame.contains(canvasPoint) {
                return node.id
            }
        }
        return nil
    }

    func hitTestEdge(at canvasPoint: CGPoint, threshold: CGFloat = 5) -> String? {
        for edge in edges.reversed() {
            let sourceInfo = handleInfo(nodeID: edge.sourceNodeID, handleID: edge.sourceHandleID)
            let targetInfo = handleInfo(nodeID: edge.targetNodeID, handleID: edge.targetHandleID)
            guard let source = sourceInfo, let target = targetInfo else { continue }

            if GeometryHelpers.pointOnLine(from: source.point, to: target.point, point: canvasPoint, tolerance: threshold) {
                return edge.id
            }
        }
        return nil
    }

    // MARK: - Query

    public func edgesForNode(_ nodeID: String) -> [FlowEdge] {
        connectionLookup[nodeID] ?? []
    }

    public func nodeBounds() -> CGRect {
        guard let first = nodes.first else { return .zero }
        var minX = first.position.x
        var minY = first.position.y
        var maxX = first.position.x + first.size.width
        var maxY = first.position.y + first.size.height
        for node in nodes.dropFirst() {
            minX = min(minX, node.position.x)
            minY = min(minY, node.position.y)
            maxX = max(maxX, node.position.x + node.size.width)
            maxY = max(maxY, node.position.y + node.size.height)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Private

    private func handlePoint(for position: HandlePosition, in node: FlowNode<Data>) -> CGPoint {
        switch position {
        case .top:    CGPoint(x: node.position.x + node.size.width / 2, y: node.position.y)
        case .bottom: CGPoint(x: node.position.x + node.size.width / 2, y: node.position.y + node.size.height)
        case .left:   CGPoint(x: node.position.x, y: node.position.y + node.size.height / 2)
        case .right:  CGPoint(x: node.position.x + node.size.width, y: node.position.y + node.size.height / 2)
        }
    }

    private func rebuildNodeLookup() {
        nodeLookup = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }

    private func rebuildConnectionLookup() {
        var lookup: [String: [FlowEdge]] = [:]
        for edge in edges {
            lookup[edge.sourceNodeID, default: []].append(edge)
            lookup[edge.targetNodeID, default: []].append(edge)
        }
        connectionLookup = lookup
    }
}

// MARK: - ConnectionDraft

struct ConnectionDraft {
    var sourceNodeID: String
    var sourceHandleID: String?
    var sourceHandleType: HandleType
    var sourceHandlePosition: HandlePosition
    var currentPoint: CGPoint
}

// MARK: - HandleHitResult

struct HandleHitResult {
    let nodeID: String
    let handleID: String
    let handleType: HandleType
    let handlePosition: HandlePosition
}

// MARK: - Document I/O

extension FlowStore where Data: Codable {

    public func export() -> FlowDocument<Data> {
        var exportedNodes = nodes
        for index in exportedNodes.indices {
            exportedNodes[index].isSelected = false
            exportedNodes[index].isDraggable = true
        }
        var exportedEdges = edges
        for index in exportedEdges.indices {
            exportedEdges[index].isSelected = false
        }
        return FlowDocument(
            nodes: exportedNodes,
            edges: exportedEdges,
            viewport: viewport
        )
    }

    public func load(_ document: FlowDocument<Data>) {
        self.nodes = document.nodes
        self.edges = document.edges
        self.viewport = document.viewport
        self.selectedNodeIDs = []
        self.selectedEdgeIDs = []
        rebuildNodeLookup()
        rebuildConnectionLookup()
    }
}
