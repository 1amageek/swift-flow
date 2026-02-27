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
    public private(set) var hoveredNodeID: String?
    public var configuration: FlowConfiguration

    // MARK: - Lookup Tables

    public private(set) var nodeLookup: [String: FlowNode<Data>] = [:]
    public private(set) var connectionLookup: [String: [FlowEdge]] = [:]

    /// Indices into `nodes` sorted by zIndex descending (front-to-back) for hit testing.
    /// Stable: among equal zIndex, later array index (added later) appears first.
    private(set) var nodeIndicesFrontToBack: [Int] = []

    // MARK: - Internal State

    var connectionDraft: ConnectionDraft?
    var selectionRect: SelectionRect?

    // MARK: - Undo

    public var undoManager: UndoManager?
    private var isUndoRegistrationDisabled = false

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
        guard nodeLookup[node.id] == nil else { return }
        nodes.append(node)
        nodeLookup[node.id] = node
        rebuildSortedNodes()
        onNodesChange?([.add(node)])
        let captured = node
        registerUndo(actionName: "Add") { store in
            store.removeNode(captured.id)
        }
    }

    public func removeNode(_ nodeID: String) {
        let capturedNode = nodeLookup[nodeID]
        let cascadedEdges = edges.filter { $0.sourceNodeID == nodeID || $0.targetNodeID == nodeID }

        nodes.removeAll { $0.id == nodeID }
        nodeLookup.removeValue(forKey: nodeID)
        rebuildSortedNodes()

        selectedNodeIDs.remove(nodeID)
        if hoveredNodeID == nodeID {
            hoveredNodeID = nil
        }

        edges.removeAll { $0.sourceNodeID == nodeID || $0.targetNodeID == nodeID }
        rebuildConnectionLookup()

        for edge in cascadedEdges {
            selectedEdgeIDs.remove(edge.id)
        }

        onNodesChange?([.remove(nodeID: nodeID)])
        if !cascadedEdges.isEmpty {
            onEdgesChange?(cascadedEdges.map { .remove(edgeID: $0.id) })
        }

        if let capturedNode {
            registerUndo(actionName: "Remove") { store in
                store.withoutUndoRegistration {
                    store.addNode(capturedNode)
                    for edge in cascadedEdges {
                        store.addEdge(edge)
                    }
                }
                store.registerUndo(actionName: "Remove") { store in
                    store.removeNode(nodeID)
                }
            }
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

    // MARK: - Move Completion (Undo)

    public func completeMoveNodes(from startPositions: [String: CGPoint]) {
        var endPositions: [String: CGPoint] = [:]
        for (nodeID, _) in startPositions {
            if let node = nodeLookup[nodeID] {
                endPositions[nodeID] = node.position
            }
        }
        let changed = startPositions.contains { id, pos in endPositions[id] != pos }
        guard changed else { return }
        registerMoveUndo(from: startPositions, to: endPositions)
    }

    private func registerMoveUndo(from: [String: CGPoint], to: [String: CGPoint]) {
        registerUndo(actionName: "Move") { store in
            for (nodeID, pos) in from {
                store.moveNode(nodeID, to: pos)
            }
            store.registerMoveUndo(from: to, to: from)
        }
    }

    // MARK: - Delete Selection

    public func deleteSelection() {
        let selectedNodes = nodes.filter { selectedNodeIDs.contains($0.id) }
        let nodeIDsToRemove = Set(selectedNodes.map(\.id))

        var allEdgeIDsToRemove = selectedEdgeIDs
        for node in selectedNodes {
            for edge in edgesForNode(node.id) {
                allEdgeIDsToRemove.insert(edge.id)
            }
        }
        let allEdgesToRemove = edges.filter { allEdgeIDsToRemove.contains($0.id) }

        guard !selectedNodes.isEmpty || !allEdgesToRemove.isEmpty else { return }

        let savedSelectedNodeIDs = selectedNodeIDs
        let savedSelectedEdgeIDs = selectedEdgeIDs

        withoutUndoRegistration {
            let standaloneEdgeIDs = selectedEdgeIDs.filter { edgeID in
                guard let edge = allEdgesToRemove.first(where: { $0.id == edgeID }) else { return false }
                return !nodeIDsToRemove.contains(edge.sourceNodeID) && !nodeIDsToRemove.contains(edge.targetNodeID)
            }
            for edgeID in standaloneEdgeIDs {
                removeEdge(edgeID)
            }
            for node in selectedNodes {
                removeNode(node.id)
            }
        }

        registerUndo(actionName: "Delete") { store in
            store.withoutUndoRegistration {
                for node in selectedNodes {
                    store.addNode(node)
                }
                for edge in allEdgesToRemove {
                    store.addEdge(edge)
                }
            }
            for nodeID in savedSelectedNodeIDs {
                store.selectNode(nodeID, exclusive: false)
            }
            for edgeID in savedSelectedEdgeIDs {
                store.selectEdge(edgeID, exclusive: false)
            }
            store.registerUndo(actionName: "Delete") { store in
                for nodeID in savedSelectedNodeIDs {
                    store.selectNode(nodeID, exclusive: false)
                }
                for edgeID in savedSelectedEdgeIDs {
                    store.selectEdge(edgeID, exclusive: false)
                }
                store.deleteSelection()
            }
        }
    }

    // MARK: - Edge Operations

    public func addEdge(_ edge: FlowEdge) {
        edges.append(edge)
        connectionLookup[edge.sourceNodeID, default: []].append(edge)
        connectionLookup[edge.targetNodeID, default: []].append(edge)
        onEdgesChange?([.add(edge)])
        let captured = edge
        registerUndo(actionName: "Add Edge") { store in
            store.removeEdge(captured.id)
        }
    }

    public func removeEdge(_ edgeID: String) {
        let capturedEdge = edges.first { $0.id == edgeID }

        edges.removeAll { $0.id == edgeID }
        rebuildConnectionLookup()

        selectedEdgeIDs.remove(edgeID)

        onEdgesChange?([.remove(edgeID: edgeID)])

        if let capturedEdge {
            registerUndo(actionName: "Remove Edge") { store in
                store.withoutUndoRegistration {
                    store.addEdge(capturedEdge)
                }
                store.registerUndo(actionName: "Remove Edge") { store in
                    store.removeEdge(edgeID)
                }
            }
        }
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
        var nodeChanges: [NodeChange<Data>] = []
        var edgeChanges: [EdgeChange] = []

        for nodeID in selectedNodeIDs {
            if let index = nodes.firstIndex(where: { $0.id == nodeID }) {
                nodes[index].isSelected = false
                nodeLookup[nodeID] = nodes[index]
                nodeChanges.append(.select(nodeID: nodeID, isSelected: false))
            }
        }
        for edgeID in selectedEdgeIDs {
            if let index = edges.firstIndex(where: { $0.id == edgeID }) {
                edges[index].isSelected = false
                edgeChanges.append(.select(edgeID: edgeID, isSelected: false))
            }
        }
        selectedNodeIDs.removeAll()
        selectedEdgeIDs.removeAll()

        if !nodeChanges.isEmpty { onNodesChange?(nodeChanges) }
        if !edgeChanges.isEmpty { onEdgesChange?(edgeChanges) }
    }

    public func selectNodesInRect(_ rect: SelectionRect) {
        selectInRect(rect)
    }

    public func selectInRect(_ rect: SelectionRect) {
        guard configuration.multiSelectionEnabled else { return }

        let selectionFrame = rect.rect
        var newSelectedNodeIDs = Set<String>()
        var nodeChanges: [NodeChange<Data>] = []

        for index in nodes.indices {
            let nodeFrame = nodes[index].frame
            let isInSelection = selectionFrame.intersects(nodeFrame)
            let wasSelected = nodes[index].isSelected
            nodes[index].isSelected = isInSelection
            nodeLookup[nodes[index].id] = nodes[index]
            if isInSelection {
                newSelectedNodeIDs.insert(nodes[index].id)
            }
            if wasSelected != isInSelection {
                nodeChanges.append(.select(nodeID: nodes[index].id, isSelected: isInSelection))
            }
        }
        selectedNodeIDs = newSelectedNodeIDs

        var newSelectedEdgeIDs = Set<String>()
        var edgeChanges: [EdgeChange] = []

        for index in edges.indices {
            let edge = edges[index]
            let isInSelection = edgeIntersectsRect(edge, rect: selectionFrame)
            let wasSelected = edges[index].isSelected
            edges[index].isSelected = isInSelection
            if isInSelection {
                newSelectedEdgeIDs.insert(edge.id)
            }
            if wasSelected != isInSelection {
                edgeChanges.append(.select(edgeID: edge.id, isSelected: isInSelection))
            }
        }
        selectedEdgeIDs = newSelectedEdgeIDs

        if !nodeChanges.isEmpty { onNodesChange?(nodeChanges) }
        if !edgeChanges.isEmpty { onEdgesChange?(edgeChanges) }
    }

    private func edgeIntersectsRect(_ edge: FlowEdge, rect: CGRect) -> Bool {
        guard let source = handleInfo(nodeID: edge.sourceNodeID, handleID: edge.sourceHandleID),
              let target = handleInfo(nodeID: edge.targetNodeID, handleID: edge.targetHandleID)
        else { return false }

        let calculator = Self.pathCalculator(for: edge.pathType)
        let edgePath = calculator.path(
            from: source.point, sourcePosition: source.position,
            to: target.point, targetPosition: target.position
        )

        let pathBounds = edgePath.path.boundingRect
        guard rect.intersects(pathBounds) else { return false }

        let strokedPath = edgePath.path.strokedPath(StrokeStyle(lineWidth: 2))
        let rectPath = Path(rect)

        let intersection = strokedPath.intersection(rectPath)
        return !intersection.isEmpty
    }

    // MARK: - Hover

    public func setHoveredNode(_ nodeID: String?) {
        guard hoveredNodeID != nodeID else { return }
        if let oldID = hoveredNodeID,
           let index = nodes.firstIndex(where: { $0.id == oldID }) {
            nodes[index].isHovered = false
            nodeLookup[oldID] = nodes[index]
        }
        if let newID = nodeID,
           let index = nodes.firstIndex(where: { $0.id == newID }) {
            nodes[index].isHovered = true
            nodeLookup[newID] = nodes[index]
        }
        hoveredNodeID = nodeID
    }

    // MARK: - Viewport

    public func pan(by delta: CGSize) {
        guard configuration.panEnabled else { return }
        viewport.offset.x += delta.width
        viewport.offset.y += delta.height
    }

    public func zoom(by factor: CGFloat, anchor: CGPoint) {
        guard configuration.zoomEnabled else { return }
        let oldZoom = viewport.zoom
        guard oldZoom > 0 else { return }
        let newZoom = max(
            configuration.minZoom,
            min(configuration.maxZoom, oldZoom * factor)
        )
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

        let fitted = min(canvasSize.width / contentWidth, canvasSize.height / contentHeight)
        viewport.zoom = max(configuration.minZoom, min(configuration.maxZoom, min(1.0, fitted)))
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

        for index in nodeIndicesFrontToBack {
            let node = nodes[index]
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
        for index in nodeIndicesFrontToBack {
            if nodes[index].frame.contains(canvasPoint) {
                return nodes[index].id
            }
        }
        return nil
    }

    func hitTestEdge(at canvasPoint: CGPoint, threshold: CGFloat = 5) -> String? {
        for edge in edges.reversed() {
            let sourceInfo = handleInfo(nodeID: edge.sourceNodeID, handleID: edge.sourceHandleID)
            let targetInfo = handleInfo(nodeID: edge.targetNodeID, handleID: edge.targetHandleID)
            guard let source = sourceInfo, let target = targetInfo else { continue }

            let calculator = Self.pathCalculator(for: edge.pathType)
            let edgePath = calculator.path(
                from: source.point, sourcePosition: source.position,
                to: target.point, targetPosition: target.position
            )
            if GeometryHelpers.pointOnPath(edgePath.path, point: canvasPoint, tolerance: threshold) {
                return edge.id
            }
        }
        return nil
    }

    private static func pathCalculator(for type: EdgePathType) -> any EdgePathCalculating {
        switch type {
        case .bezier: BezierEdgePath()
        case .straight: StraightEdgePath()
        case .smoothStep: SmoothStepEdgePath()
        case .simpleBezier: SimpleBezierEdgePath()
        }
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

    // MARK: - Undo Helpers

    private func registerUndo(actionName: String, handler: @escaping @MainActor @Sendable (FlowStore) -> Void) {
        guard !isUndoRegistrationDisabled, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { handler(target) }
        }
        undoManager.setActionName(actionName)
    }

    private func withoutUndoRegistration(_ body: () -> Void) {
        let previous = isUndoRegistrationDisabled
        isUndoRegistrationDisabled = true
        body()
        isUndoRegistrationDisabled = previous
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
        var seen = Set<String>()
        var deduped: [FlowNode<Data>] = []
        for node in nodes {
            if seen.insert(node.id).inserted {
                deduped.append(node)
            }
        }
        if deduped.count != nodes.count {
            nodes = deduped
        }
        nodeLookup = Dictionary(uniqueKeysWithValues: deduped.map { ($0.id, $0) })
        rebuildSortedNodes()
    }

    private func rebuildSortedNodes() {
        // Stable sort: among equal zIndex, preserve reversed array order (later = front)
        nodeIndicesFrontToBack = nodes.indices.sorted { lhs, rhs in
            if nodes[lhs].zIndex != nodes[rhs].zIndex {
                return nodes[lhs].zIndex > nodes[rhs].zIndex
            }
            return lhs > rhs
        }
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
            exportedNodes[index].isHovered = false
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
        self.hoveredNodeID = nil
        rebuildNodeLookup()
        rebuildConnectionLookup()
        undoManager?.removeAllActions()
    }
}
