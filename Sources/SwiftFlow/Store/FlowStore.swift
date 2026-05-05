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
    public private(set) var animatedEdgeIDs: Set<String>
    public private(set) var hoveredNodeID: String?
    public private(set) var dropTargetNodeID: String?
    public private(set) var dropTargetEdgeID: String?
    public var configuration: FlowConfiguration

    /// Rasterized snapshots keyed by node id, used by the Canvas rasterize
    /// path when a node is currently inactive. Written by `LiveNode` (for
    /// SwiftUI content) or by the app (for `.manual` captures of native
    /// views). Not part of undo: this is a rendering cache, not document
    /// state.
    public private(set) var nodeSnapshots: [String: FlowNodeSnapshot] = [:]
    private var snapshotGeneration: Int = 0

    // MARK: - Lookup Tables

    public private(set) var nodeLookup: [String: FlowNode<Data>] = [:]
    public private(set) var connectionLookup: [String: [FlowEdge]] = [:]

    /// Indices into `nodes` sorted by zIndex descending (front-to-back) for hit testing.
    /// Stable: among equal zIndex, later array index (added later) appears first.
    private(set) var nodeIndicesFrontToBack: [Int] = []

    // MARK: - Internal State

    public var connectionDraft: ConnectionDraft?
    var selectionRect: SelectionRect?

    /// Active node-drag session, if any. Captured at begin so end can
    /// register a single multi-node undo entry. Driven by either
    /// `FlowCanvas`'s primary drag gesture or an external drag site
    /// using ``View/flowDragHandle(for:in:)``. Both routes go through
    /// ``beginNodeDrag(_:)`` / ``updateNodeDrag(translation:)`` /
    /// ``endNodeDrag()`` so the dispatch logic is single-sourced.
    private var nodeDragSession: NodeDragSession?

    // MARK: - Animation State

    private var viewportAnimations: (x: PropertyAnimation?, y: PropertyAnimation?, zoom: PropertyAnimation?) = (nil, nil, nil)
    private var zoomAnchorState: (anchor: CGPoint, initialOffset: CGPoint, initialZoom: CGFloat)?
    private var nodePositionAnimations: [String: (x: PropertyAnimation, y: PropertyAnimation)] = [:]
    public private(set) var edgeDashPhase: CGFloat = 0
    private var animationTask: Task<Void, Never>?

    // MARK: - Undo

    public var undoManager: UndoManager?
    private var isUndoRegistrationDisabled = false

    // MARK: - Interactive Updates

    private var isInteractiveUpdateActive = false
    private var pendingNodeChanges: [NodeChange<Data>] = []

    // MARK: - Callbacks

    public var onNodesChange: (([NodeChange<Data>]) -> Void)?
    public var onEdgesChange: (([EdgeChange]) -> Void)?
    public var onConnect: ((ConnectionProposal) -> Void)?
    public var onNodeDoubleTap: ((String) -> Void)?
    public var onEdgeDoubleTap: ((String) -> Void)?
    public var onCanvasDoubleTap: ((CGPoint) -> Void)?
    public var onConnectionRejected: ((ConnectionProposal) -> Void)?

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
        self.animatedEdgeIDs = []
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
        emitNodeChange(.add(node))
        let captured = node
        registerUndo(actionName: "Add") { store in
            store.removeNode(captured.id)
        }
    }

    public func removeNode(_ nodeID: String) {
        nodePositionAnimations.removeValue(forKey: nodeID)
        nodeSnapshots.removeValue(forKey: nodeID)
        let capturedNode = nodeLookup[nodeID]
        let cascadedEdges = edges.filter { $0.sourceNodeID == nodeID || $0.targetNodeID == nodeID }

        nodes.removeAll { $0.id == nodeID }
        nodeLookup.removeValue(forKey: nodeID)
        rebuildSortedNodes()

        selectedNodeIDs.remove(nodeID)
        if hoveredNodeID == nodeID {
            hoveredNodeID = nil
        }
        if dropTargetNodeID == nodeID {
            dropTargetNodeID = nil
        }
        if connectionDraft?.sourceNodeID == nodeID {
            connectionDraft = nil
        } else if connectionDraft?.targetNodeID == nodeID {
            connectionDraft?.targetNodeID = nil
            connectionDraft?.targetHandleID = nil
        }

        edges.removeAll { $0.sourceNodeID == nodeID || $0.targetNodeID == nodeID }
        rebuildConnectionLookup()

        for edge in cascadedEdges {
            selectedEdgeIDs.remove(edge.id)
            animatedEdgeIDs.remove(edge.id)
        }

        emitNodeChange(.remove(nodeID: nodeID))
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
        nodePositionAnimations.removeValue(forKey: nodeID)
        let snapped = configuration.snapped(position)
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        nodes[index].position = snapped
        nodeLookup[nodeID] = nodes[index]
        emitNodeChange(.position(nodeID: nodeID, position: snapped))
    }

    public func updateNode(_ nodeID: String, _ transform: (inout FlowNode<Data>) -> Void) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        let oldZIndex = nodes[index].zIndex
        let oldSize = nodes[index].size
        transform(&nodes[index])
        nodeLookup[nodeID] = nodes[index]
        if nodes[index].zIndex != oldZIndex {
            rebuildSortedNodes()
        }
        if nodes[index].size != oldSize {
            nodeSnapshots.removeValue(forKey: nodeID)
        }
        emitNodeChange(.replace(nodes[index]))
    }

    public func updateNodeSize(_ nodeID: String, size: CGSize) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        let oldSize = nodes[index].size
        nodes[index].size = size
        nodeLookup[nodeID] = nodes[index]
        if size != oldSize {
            nodeSnapshots.removeValue(forKey: nodeID)
        }
        emitNodeChange(.dimensions(nodeID: nodeID, size: size))
    }

    // MARK: - Node Snapshots

    /// Store a rasterized snapshot for a node. Overwrites any prior entry.
    /// Not registered with undo — snapshots are a rendering cache.
    public func setNodeSnapshot(_ snapshot: FlowNodeSnapshot, for nodeID: String) {
        guard nodeLookup[nodeID] != nil else { return }
        nodeSnapshots[nodeID] = snapshot
    }

    /// Current document-generation token for async snapshot writes.
    public func currentSnapshotGeneration() -> Int {
        snapshotGeneration
    }

    /// Store a rasterized snapshot only if it belongs to the current document generation.
    public func setNodeSnapshot(
        _ snapshot: FlowNodeSnapshot,
        for nodeID: String,
        generation: Int
    ) {
        guard generation == snapshotGeneration else { return }
        setNodeSnapshot(snapshot, for: nodeID)
    }

    /// Drop the cached snapshot for a single node.
    public func clearNodeSnapshot(for nodeID: String) {
        nodeSnapshots.removeValue(forKey: nodeID)
    }

    /// Drop every cached snapshot. Useful when bulk-reloading a document.
    public func clearAllNodeSnapshots() {
        nodeSnapshots.removeAll(keepingCapacity: false)
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

    // MARK: - Node Drag Session

    /// True while any drag site is moving nodes through the shared
    /// session API. Read by `FlowCanvas` to gate live-row unmounting and
    /// frame redraw, and by the live overlay so external drag sites
    /// (e.g. ``View/flowDragHandle(for:in:)``) get the same smoothness
    /// as a Canvas-level drag.
    public var isNodeDragging: Bool { nodeDragSession != nil }

    /// Begin a node-move session targeting `nodeID`. Honors the current
    /// multi-selection: if `nodeID` is part of the selection and there
    /// are other selected nodes, all draggable selected nodes are moved
    /// together. Idempotent — overwrites any leaked prior session so a
    /// view that disappeared mid-drag can't poison the next drag.
    public func beginNodeDrag(_ nodeID: String) {
        guard let node = nodeLookup[nodeID], node.isDraggable else {
            nodeDragSession = nil
            return
        }
        var startPositions: [String: CGPoint] = [:]
        if node.isSelected, selectedNodeIDs.count > 1 {
            for id in selectedNodeIDs {
                if let n = nodeLookup[id], n.isDraggable {
                    startPositions[id] = n.position
                }
            }
        } else {
            startPositions[nodeID] = node.position
        }
        nodeDragSession = NodeDragSession(startPositions: startPositions)
    }

    /// Update the active session with a screen-space translation. The
    /// caller passes the gesture's `value.translation` directly; viewport
    /// zoom is applied internally so the same translation produces the
    /// same canvas-space delta regardless of zoom level.
    public func updateNodeDrag(translation: CGSize) {
        guard let session = nodeDragSession else { return }
        let zoom = viewport.zoom
        let dx = translation.width / zoom
        let dy = translation.height / zoom
        for (nodeID, start) in session.startPositions {
            moveNode(nodeID, to: CGPoint(
                x: start.x + dx,
                y: start.y + dy
            ))
        }
    }

    /// Finalize the active session: registers a single multi-node undo
    /// entry via ``completeMoveNodes(from:)`` and clears the session.
    public func endNodeDrag() {
        guard let session = nodeDragSession else { return }
        completeMoveNodes(from: session.startPositions)
        nodeDragSession = nil
    }

    /// Drop the active session without registering undo. Intended for
    /// out-of-band cancellation (e.g. drag interrupted by a modal) — the
    /// gesture's normal end path should call ``endNodeDrag()`` instead.
    public func cancelNodeDrag() {
        nodeDragSession = nil
    }

    // MARK: - Resize Completion (Undo)

    /// Register a single undo entry for a completed resize operation.
    ///
    /// Call this at the end of an interactive resize drag. The snapshot dict maps
    /// nodeID to the node's frame (origin + size) at the start of the drag.
    /// Any combination of position and size differences is captured in a single
    /// undo entry, so corner-drag resizes that move the origin are covered.
    public func completeResizeNodes(from startFrames: [String: CGRect]) {
        var endFrames: [String: CGRect] = [:]
        for (nodeID, _) in startFrames {
            if let node = nodeLookup[nodeID] {
                endFrames[nodeID] = node.frame
            }
        }
        let changed = startFrames.contains { id, rect in endFrames[id] != rect }
        guard changed else { return }
        registerResizeUndo(from: startFrames, to: endFrames)
    }

    private func registerResizeUndo(from: [String: CGRect], to: [String: CGRect]) {
        registerUndo(actionName: "Resize") { store in
            store.withoutUndoRegistration {
                for (nodeID, rect) in from {
                    store.updateNode(nodeID) { node in
                        node.position = rect.origin
                        node.size = rect.size
                    }
                }
            }
            store.registerResizeUndo(from: to, to: from)
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
        guard !edges.contains(where: { $0.id == edge.id }) else { return }
        guard nodeLookup[edge.sourceNodeID] != nil,
              nodeLookup[edge.targetNodeID] != nil else { return }
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
        animatedEdgeIDs.remove(edgeID)

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

    // MARK: - Edge Update

    /// Update a single edge's structural properties in-place.
    /// Undo is registered automatically. Topology-related lookups are rebuilt only when necessary.
    public func updateEdge(_ edgeID: String, _ transform: (inout FlowEdge) -> Void) {
        guard let index = edges.firstIndex(where: { $0.id == edgeID }) else { return }
        let old = edges[index]
        transform(&edges[index])
        let new = edges[index]
        guard old != new else { return }

        if old.sourceNodeID != new.sourceNodeID || old.targetNodeID != new.targetNodeID
            || old.sourceHandleID != new.sourceHandleID || old.targetHandleID != new.targetHandleID {
            rebuildConnectionLookup()
        }

        onEdgesChange?([.replace(new)])

        let capturedOld = old
        registerUndo(actionName: "Update Edge") { store in
            store.updateEdge(edgeID) { $0 = capturedOld }
        }
    }

    /// Update multiple edges in a single batch. Only triggers one lookup rebuild and one callback.
    public func updateEdges(_ transform: (inout FlowEdge) -> Void) {
        var anyTopologyChanged = false
        var changes: [EdgeChange] = []
        var oldSnapshots: [(String, FlowEdge)] = []
        var newSnapshots: [(String, FlowEdge)] = []

        for index in edges.indices {
            let old = edges[index]
            transform(&edges[index])
            let new = edges[index]
            guard old != new else { continue }

            if old.sourceNodeID != new.sourceNodeID || old.targetNodeID != new.targetNodeID
                || old.sourceHandleID != new.sourceHandleID || old.targetHandleID != new.targetHandleID {
                anyTopologyChanged = true
            }
            changes.append(.replace(new))
            oldSnapshots.append((new.id, old))
            newSnapshots.append((new.id, new))
        }

        guard !changes.isEmpty else { return }
        if anyTopologyChanged { rebuildConnectionLookup() }
        onEdgesChange?(changes)

        registerBatchEdgeUndo(restoreTo: oldSnapshots, redoTo: newSnapshots)
    }

    private func registerBatchEdgeUndo(
        restoreTo: [(String, FlowEdge)],
        redoTo: [(String, FlowEdge)]
    ) {
        registerUndo(actionName: "Update Edges") { store in
            store.withoutUndoRegistration {
                for (edgeID, old) in restoreTo {
                    store.updateEdge(edgeID) { $0 = old }
                }
            }
            store.registerBatchEdgeUndo(restoreTo: redoTo, redoTo: restoreTo)
        }
    }

    // MARK: - Edge Animation (side-table, no undo)

    /// Set the animated state for a single edge.
    /// Animation state is managed separately from edge structure and never participates in undo.
    /// No-ops when the edge id does not exist — phantom ids would otherwise
    /// stay in `animatedEdgeIDs` and keep the animation loop alive forever.
    public func setEdgeAnimated(_ edgeID: String, _ animated: Bool) {
        if animated {
            guard edges.contains(where: { $0.id == edgeID }) else { return }
            guard animatedEdgeIDs.insert(edgeID).inserted else { return }
        } else {
            guard animatedEdgeIDs.remove(edgeID) != nil else { return }
        }
        startAnimationLoopIfNeeded()
    }

    /// Replace the entire set of animated edges at once.
    /// This is the most efficient way to synchronize animation state from an external source.
    /// Filters the input down to ids that exist in `edges`, so callers cannot
    /// poison the set with stale or fabricated ids.
    public func setAnimatedEdges(_ edgeIDs: Set<String>) {
        let existingEdgeIDs = Set(edges.map(\.id))
        let filtered = edgeIDs.intersection(existingEdgeIDs)
        guard animatedEdgeIDs != filtered else { return }
        animatedEdgeIDs = filtered
        startAnimationLoopIfNeeded()
    }

    // MARK: - Selection

    public func selectNode(_ nodeID: String, exclusive: Bool = true) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        let shouldExclusive = exclusive || !configuration.multiSelectionEnabled
        if shouldExclusive {
            clearSelection()
        }
        selectedNodeIDs.insert(nodeID)
        nodes[index].isSelected = true
        nodeLookup[nodeID] = nodes[index]
        emitNodeChange(.select(nodeID: nodeID, isSelected: true))
    }

    public func deselectNode(_ nodeID: String) {
        selectedNodeIDs.remove(nodeID)
        if let index = nodes.firstIndex(where: { $0.id == nodeID }) {
            nodes[index].isSelected = false
            nodeLookup[nodeID] = nodes[index]
            emitNodeChange(.select(nodeID: nodeID, isSelected: false))
        }
    }

    public func selectEdge(_ edgeID: String, exclusive: Bool = true) {
        guard let index = edges.firstIndex(where: { $0.id == edgeID }) else { return }
        let shouldExclusive = exclusive || !configuration.multiSelectionEnabled
        if shouldExclusive {
            clearSelection()
        }
        selectedEdgeIDs.insert(edgeID)
        edges[index].isSelected = true
        onEdgesChange?([.select(edgeID: edgeID, isSelected: true)])
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

        if !nodeChanges.isEmpty { emitNodeChanges(nodeChanges) }
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

        if !nodeChanges.isEmpty { emitNodeChanges(nodeChanges) }
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

    public func setDropTargetNode(_ nodeID: String?) {
        guard dropTargetNodeID != nodeID else { return }
        if let oldID = dropTargetNodeID,
           let index = nodes.firstIndex(where: { $0.id == oldID }) {
            nodes[index].isDropTarget = false
            nodeLookup[oldID] = nodes[index]
        }
        if let newID = nodeID,
           let index = nodes.firstIndex(where: { $0.id == newID }) {
            nodes[index].isDropTarget = true
            nodeLookup[newID] = nodes[index]
        }
        dropTargetNodeID = nodeID
    }

    public func setDropTargetEdge(_ edgeID: String?) {
        guard dropTargetEdgeID != edgeID else { return }
        if let oldID = dropTargetEdgeID,
           let index = edges.firstIndex(where: { $0.id == oldID }) {
            edges[index].isDropTarget = false
        }
        if let newID = edgeID,
           let index = edges.firstIndex(where: { $0.id == newID }) {
            edges[index].isDropTarget = true
        }
        dropTargetEdgeID = edgeID
    }

    // MARK: - Viewport

    public func pan(by delta: CGSize) {
        guard configuration.panEnabled else { return }
        viewportAnimations.x = nil
        viewportAnimations.y = nil
        zoomAnchorState = nil
        viewport.offset.x += delta.width
        viewport.offset.y += delta.height
    }

    public func zoom(by factor: CGFloat, anchor: CGPoint) {
        guard configuration.zoomEnabled else { return }
        viewportAnimations = (nil, nil, nil)
        zoomAnchorState = nil
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
        viewportAnimations = (nil, nil, nil)
        zoomAnchorState = nil
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

    // MARK: - Animated API

    /// Sets the viewport with an animation.
    public func setViewport(_ newViewport: Viewport, animation: FlowAnimation) {
        zoomAnchorState = nil
        let timing = animation.timing

        if var anim = viewportAnimations.x {
            anim.retarget(to: newViewport.offset.x)
            viewportAnimations.x = anim
        } else {
            viewportAnimations.x = PropertyAnimation(from: viewport.offset.x, to: newViewport.offset.x, timing: timing)
        }

        if var anim = viewportAnimations.y {
            anim.retarget(to: newViewport.offset.y)
            viewportAnimations.y = anim
        } else {
            viewportAnimations.y = PropertyAnimation(from: viewport.offset.y, to: newViewport.offset.y, timing: timing)
        }

        if var anim = viewportAnimations.zoom {
            anim.retarget(to: newViewport.zoom)
            viewportAnimations.zoom = anim
        } else {
            viewportAnimations.zoom = PropertyAnimation(from: viewport.zoom, to: newViewport.zoom, timing: timing)
        }

        startAnimationLoopIfNeeded()
    }

    /// Zooms by a factor around an anchor point with an animation.
    /// Offset is derived from zoom each frame to keep the anchor point stable.
    public func zoom(by factor: CGFloat, anchor: CGPoint, animation: FlowAnimation) {
        guard configuration.zoomEnabled else { return }
        let oldZoom = viewport.zoom
        guard oldZoom > 0 else { return }
        let newZoom = max(configuration.minZoom, min(configuration.maxZoom, oldZoom * factor))

        // Store anchor context so offset can be derived from zoom each frame
        zoomAnchorState = (anchor: anchor, initialOffset: viewport.offset, initialZoom: oldZoom)

        // Clear independent offset animations — offset will be computed from zoom
        viewportAnimations.x = nil
        viewportAnimations.y = nil

        let timing = animation.timing
        if var anim = viewportAnimations.zoom {
            anim.retarget(to: newZoom)
            viewportAnimations.zoom = anim
        } else {
            viewportAnimations.zoom = PropertyAnimation(from: oldZoom, to: newZoom, timing: timing)
        }

        startAnimationLoopIfNeeded()
    }

    /// Fits the viewport to show all nodes with an animation.
    ///
    /// When zoom changes, offset is derived from zoom each frame (same as
    /// `zoom(by:anchor:animation:)`) to prevent wobble caused by independent
    /// offset/zoom animations settling at different times.
    public func fitToContent(canvasSize: CGSize, padding: CGFloat = 50, animation: FlowAnimation) {
        guard !nodes.isEmpty else { return }
        let bounds = nodeBounds()
        let contentWidth = bounds.width + padding * 2
        let contentHeight = bounds.height + padding * 2
        guard contentWidth > 0, contentHeight > 0 else { return }

        let fitted = min(canvasSize.width / contentWidth, canvasSize.height / contentHeight)
        let targetZoom = max(configuration.minZoom, min(configuration.maxZoom, min(1.0, fitted)))
        let targetOffset = CGPoint(
            x: -bounds.minX * targetZoom + (canvasSize.width - bounds.width * targetZoom) / 2,
            y: -bounds.minY * targetZoom + (canvasSize.height - bounds.height * targetZoom) / 2
        )

        let initialZoom = viewport.zoom
        let ratio = initialZoom > 0 ? targetZoom / initialZoom : 1.0

        if abs(ratio - 1.0) < 1e-9 {
            // Zoom unchanged — animate offset only (no coupling issue)
            let target = Viewport(offset: targetOffset, zoom: targetZoom)
            setViewport(target, animation: animation)
        } else {
            // Derive a virtual anchor so offset tracks zoom each frame.
            // Given: targetOffset = anchor - (anchor - initialOffset) * ratio
            // Solve: anchor = (targetOffset - initialOffset * ratio) / (1 - ratio)
            let initialOffset = viewport.offset
            let anchor = CGPoint(
                x: (targetOffset.x - initialOffset.x * ratio) / (1 - ratio),
                y: (targetOffset.y - initialOffset.y * ratio) / (1 - ratio)
            )

            zoomAnchorState = (anchor: anchor, initialOffset: initialOffset, initialZoom: initialZoom)

            // Clear independent offset animations — offset will be computed from zoom
            viewportAnimations.x = nil
            viewportAnimations.y = nil

            let timing = animation.timing
            if var anim = viewportAnimations.zoom {
                anim.retarget(to: targetZoom)
                viewportAnimations.zoom = anim
            } else {
                viewportAnimations.zoom = PropertyAnimation(from: initialZoom, to: targetZoom, timing: timing)
            }

            startAnimationLoopIfNeeded()
        }
    }

    /// Animates multiple node positions simultaneously.
    public func setNodePositions(_ positions: [String: CGPoint], animation: FlowAnimation) {
        let timing = animation.timing

        for (nodeID, targetPos) in positions {
            let snapped = configuration.snapped(targetPos)
            guard let node = nodeLookup[nodeID] else { continue }

            if var existing = nodePositionAnimations[nodeID] {
                existing.x.retarget(to: snapped.x)
                existing.y.retarget(to: snapped.y)
                nodePositionAnimations[nodeID] = existing
            } else {
                nodePositionAnimations[nodeID] = (
                    x: PropertyAnimation(from: node.position.x, to: snapped.x, timing: timing),
                    y: PropertyAnimation(from: node.position.y, to: snapped.y, timing: timing)
                )
            }
        }

        startAnimationLoopIfNeeded()
    }

    // MARK: - Animation Loop

    /// Whether any animation is currently in progress.
    var isAnimating: Bool {
        viewportAnimations.x != nil || viewportAnimations.y != nil || viewportAnimations.zoom != nil
        || !nodePositionAnimations.isEmpty
        || !animatedEdgeIDs.isEmpty
    }

    private func startAnimationLoopIfNeeded() {
        guard animationTask == nil else { return }
        animationTask = Task { [weak self] in
            var lastTime = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(8))
                guard let self else { return }
                let now = ContinuousClock.now
                let dt = (now - lastTime).timeInterval
                lastTime = now
                self.tickAnimations(dt: dt)
                if !self.isAnimating {
                    break
                }
            }
            guard let self else { return }
            self.animationTask = nil
        }
    }

    private func tickAnimations(dt: TimeInterval) {
        // Clamp dt to prevent numerical instability in spring integration
        // when the main thread stalls or the app returns from background.
        let clampedDT = min(dt, 1.0 / 30.0)
        tickViewportAnimations(dt: clampedDT)
        tickNodePositionAnimations(dt: clampedDT)
        tickEdgeDashPhase(dt: dt)
    }

    private func tickViewportAnimations(dt: TimeInterval) {
        if var anim = viewportAnimations.x {
            anim.tick(dt: dt)
            viewport.offset.x = anim.current
            if anim.settled { viewportAnimations.x = nil } else { viewportAnimations.x = anim }
        }
        if var anim = viewportAnimations.y {
            anim.tick(dt: dt)
            viewport.offset.y = anim.current
            if anim.settled { viewportAnimations.y = nil } else { viewportAnimations.y = anim }
        }
        if var anim = viewportAnimations.zoom {
            anim.tick(dt: dt)
            viewport.zoom = anim.current

            // Derive offset from zoom to keep anchor stable
            if let anchor = zoomAnchorState, anchor.initialZoom > 0 {
                let scale = anim.current / anchor.initialZoom
                viewport.offset.x = anchor.anchor.x - (anchor.anchor.x - anchor.initialOffset.x) * scale
                viewport.offset.y = anchor.anchor.y - (anchor.anchor.y - anchor.initialOffset.y) * scale
            }

            if anim.settled {
                viewportAnimations.zoom = nil
                zoomAnchorState = nil
            } else {
                viewportAnimations.zoom = anim
            }
        }
    }

    private func tickNodePositionAnimations(dt: TimeInterval) {
        var settled: [String] = []
        for (nodeID, var anims) in nodePositionAnimations {
            anims.x.tick(dt: dt)
            anims.y.tick(dt: dt)

            // Lightweight update: skip callbacks, undo, snap-to-grid
            if let index = nodes.firstIndex(where: { $0.id == nodeID }) {
                nodes[index].position = CGPoint(x: anims.x.current, y: anims.y.current)
                nodeLookup[nodeID] = nodes[index]
            }

            if anims.x.settled && anims.y.settled {
                settled.append(nodeID)
            } else {
                nodePositionAnimations[nodeID] = anims
            }
        }
        for nodeID in settled {
            nodePositionAnimations.removeValue(forKey: nodeID)
        }
    }

    private func tickEdgeDashPhase(dt: TimeInterval) {
        guard !animatedEdgeIDs.isEmpty else { return }
        edgeDashPhase += CGFloat(dt) * 30
        let patternLength = configuration.edgeStyle.animatedDashPattern.reduce(0, +)
        if patternLength > 0 {
            edgeDashPhase = edgeDashPhase.truncatingRemainder(dividingBy: patternLength)
        }
    }

    // MARK: - Connection Draft

    func beginConnection(nodeID: String, handleID: String?, handleType: HandleType, handlePosition: HandlePosition) {
        guard connectionDraft == nil else { return }
        connectionDraft = ConnectionDraft(
            sourceNodeID: nodeID,
            sourceHandleID: handleID,
            sourceHandleType: handleType,
            sourceHandlePosition: handlePosition,
            targetNodeID: nil,
            targetHandleID: nil,
            currentPoint: .zero
        )
    }

    func updateConnection(to point: CGPoint, targetNodeID: String? = nil, targetHandleID: String? = nil) {
        connectionDraft?.currentPoint = point
        connectionDraft?.targetNodeID = targetNodeID
        connectionDraft?.targetHandleID = targetHandleID
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
        } else {
            onConnectionRejected?(proposal)
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

    func findNearestHandle(at canvasPoint: CGPoint, excludingNodeID: String, targetType: HandleType, threshold: CGFloat = 40) -> (nodeID: String, handleID: String)? {
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

    func hitTestHandle(at canvasPoint: CGPoint, threshold: CGFloat = 25) -> HandleHitResult? {
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

    public static func pathCalculator(for type: EdgePathType) -> any EdgePathCalculating {
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

    // MARK: - Interactive Updates (Public)

    /// Begin an interactive update session. While active, node change callbacks
    /// (`onNodesChange`) are accumulated instead of fired per-operation. Call
    /// `endInteractiveUpdates()` to flush the accumulated changes as a single
    /// batch. Useful during drag operations that mutate nodes every frame.
    ///
    /// Nested begin/end pairs are not supported; a second `begin` call while
    /// already active simply keeps the session open.
    public func beginInteractiveUpdates() {
        isInteractiveUpdateActive = true
    }

    /// End an interactive update session started with `beginInteractiveUpdates()`.
    /// Fires `onNodesChange` once with all accumulated changes in original order,
    /// then clears the buffer.
    public func endInteractiveUpdates() {
        isInteractiveUpdateActive = false
        guard !pendingNodeChanges.isEmpty else { return }
        let batched = pendingNodeChanges
        pendingNodeChanges.removeAll()
        onNodesChange?(batched)
    }

    private func emitNodeChange(_ change: NodeChange<Data>) {
        if isInteractiveUpdateActive {
            pendingNodeChanges.append(change)
        } else {
            onNodesChange?([change])
        }
    }

    private func emitNodeChanges(_ changes: [NodeChange<Data>]) {
        guard !changes.isEmpty else { return }
        if isInteractiveUpdateActive {
            pendingNodeChanges.append(contentsOf: changes)
        } else {
            onNodesChange?(changes)
        }
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

public struct ConnectionDraft {
    public var sourceNodeID: String
    public var sourceHandleID: String?
    public var sourceHandleType: HandleType
    public var sourceHandlePosition: HandlePosition
    public var targetNodeID: String?
    public var targetHandleID: String?
    public var currentPoint: CGPoint

    public init(
        sourceNodeID: String,
        sourceHandleID: String?,
        sourceHandleType: HandleType,
        sourceHandlePosition: HandlePosition,
        targetNodeID: String? = nil,
        targetHandleID: String? = nil,
        currentPoint: CGPoint
    ) {
        self.sourceNodeID = sourceNodeID
        self.sourceHandleID = sourceHandleID
        self.sourceHandleType = sourceHandleType
        self.sourceHandlePosition = sourceHandlePosition
        self.targetNodeID = targetNodeID
        self.targetHandleID = targetHandleID
        self.currentPoint = currentPoint
    }
}

// MARK: - HandleHitResult

struct HandleHitResult {
    let nodeID: String
    let handleID: String?
    let handleType: HandleType
    let handlePosition: HandlePosition
}

// MARK: - Document I/O

extension FlowStore where Data: Codable {

    public func export() -> FlowDocument<Data> {
        var exportedNodes = nodes.filter { $0.persistence == .persistent }
        for index in exportedNodes.indices {
            exportedNodes[index].isSelected = false
            exportedNodes[index].isHovered = false
            exportedNodes[index].isDraggable = true
        }
        let exportedNodeIDs = Set(exportedNodes.map(\.id))
        var exportedEdges = edges.filter {
            exportedNodeIDs.contains($0.sourceNodeID) && exportedNodeIDs.contains($0.targetNodeID)
        }
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
        animationTask?.cancel()
        animationTask = nil
        viewportAnimations = (nil, nil, nil)
        zoomAnchorState = nil
        nodePositionAnimations.removeAll()
        edgeDashPhase = 0

        // Drop ephemeral state that does not survive a document swap:
        // rendering snapshots are keyed by node id (collisions across
        // documents would briefly show the previous bitmap), the drag
        // session refers to nodes that are about to disappear, and any
        // pending interactive-update batch belongs to the old document.
        snapshotGeneration += 1
        nodeSnapshots.removeAll()
        nodeDragSession = nil
        pendingNodeChanges.removeAll()
        isInteractiveUpdateActive = false

        var loadedNodes = document.nodes
        for index in loadedNodes.indices {
            loadedNodes[index].isSelected = false
            loadedNodes[index].isHovered = false
            loadedNodes[index].isDropTarget = false
        }

        var loadedEdges = document.edges
        for index in loadedEdges.indices {
            loadedEdges[index].isSelected = false
            loadedEdges[index].isDropTarget = false
        }

        self.nodes = loadedNodes
        self.edges = loadedEdges
        self.viewport = document.viewport
        self.selectedNodeIDs = []
        self.selectedEdgeIDs = []
        self.animatedEdgeIDs = []
        self.hoveredNodeID = nil
        self.dropTargetNodeID = nil
        self.dropTargetEdgeID = nil
        self.connectionDraft = nil
        self.selectionRect = nil
        rebuildNodeLookup()

        // Filter out edges with duplicate IDs or dangling node references
        var seenEdgeIDs = Set<String>()
        edges.removeAll { edge in
            if !seenEdgeIDs.insert(edge.id).inserted { return true }
            if nodeLookup[edge.sourceNodeID] == nil { return true }
            if nodeLookup[edge.targetNodeID] == nil { return true }
            return false
        }

        rebuildConnectionLookup()
        undoManager?.removeAllActions()
    }
}

// MARK: - NodeDragSession

/// Snapshot of node positions captured at the moment a node-move drag
/// began. Held by `FlowStore` for the lifetime of the drag and consumed
/// by `endNodeDrag()` to register a single multi-node undo entry.
struct NodeDragSession: Sendable {
    let startPositions: [String: CGPoint]
}
