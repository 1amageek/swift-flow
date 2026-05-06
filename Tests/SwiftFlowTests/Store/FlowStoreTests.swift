import Testing
import Foundation
import CoreGraphics
@testable import SwiftFlow

@Suite("FlowStore Tests")
@MainActor
struct FlowStoreTests {

    @Test("Add and remove nodes")
    func addRemoveNodes() {
        let store = FlowStore<String>()
        let node = FlowNode(id: "n1", position: .zero, data: "Test")
        store.addNode(node)
        #expect(store.nodes.count == 1)
        #expect(store.nodeLookup["n1"] != nil)

        store.removeNode("n1")
        #expect(store.nodes.isEmpty)
        #expect(store.nodeLookup["n1"] == nil)
    }

    @Test("Remove node also removes connected edges")
    func removeNodeCascadesEdges() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))
        store.addNode(FlowNode(id: "n3", position: CGPoint(x: 400, y: 0), data: "C"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        store.addEdge(FlowEdge(id: "e2", sourceNodeID: "n2", targetNodeID: "n3"))

        store.removeNode("n2")
        #expect(store.edges.isEmpty)
    }

    @Test("Move node with snap to grid")
    func moveNodeSnap() {
        var config = FlowConfiguration()
        config.snapToGrid = true
        config.gridSize = 10
        let store = FlowStore<String>(configuration: config)
        store.addNode(FlowNode(id: "n1", position: .zero, data: "Test"))

        store.moveNode("n1", to: CGPoint(x: 13, y: 27))
        #expect(store.nodes[0].position == CGPoint(x: 10, y: 30))
    }

    @Test("Add and remove edges")
    func addRemoveEdges() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))
        let edge = FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2")
        store.addEdge(edge)
        #expect(store.edges.count == 1)
        #expect(store.connectionLookup["n1"]?.count == 1)

        store.removeEdge("e1")
        #expect(store.edges.isEmpty)
    }

    @Test("addEdge rejects duplicate edge ID")
    func addEdgeDuplicateID() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        #expect(store.edges.count == 1)
    }

    @Test("addEdge rejects edge with non-existent source node")
    func addEdgeDanglingSource() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "nonexistent", targetNodeID: "n2"))
        #expect(store.edges.isEmpty)
    }

    @Test("addEdge rejects edge with non-existent target node")
    func addEdgeDanglingTarget() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "nonexistent"))
        #expect(store.edges.isEmpty)
    }

    @Test("Select and deselect nodes")
    func nodeSelection() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 100, y: 0), data: "B"))

        store.selectNode("n1")
        #expect(store.selectedNodeIDs.contains("n1"))
        #expect(store.focusedTarget == .node("n1"))
        #expect(store.nodes[0].isSelected == true)

        store.selectNode("n2")
        #expect(!store.selectedNodeIDs.contains("n1"))
        #expect(store.selectedNodeIDs.contains("n2"))
        #expect(store.focusedTarget == .node("n2"))

        store.deselectNode("n2")
        #expect(store.selectedNodeIDs.isEmpty)
        #expect(store.focusedTarget == nil)
    }

    @Test("Select and deselect edges")
    func edgeSelection() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))

        store.selectEdge("e1")
        #expect(store.selectedEdgeIDs.contains("e1"))
        #expect(store.focusedTarget == .edge("e1"))
        #expect(store.edges[0].isSelected == true)

        store.deselectEdge("e1")
        #expect(store.selectedEdgeIDs.isEmpty)
        #expect(store.focusedTarget == nil)
    }

    @Test("Pointer node selection toggles and replaces consistently")
    func pointerNodeSelection() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 100, y: 0), data: "B"))

        store.selectNodeFromPointer("n1", mode: .toggle)
        #expect(store.selectedNodeIDs == Set(["n1"]))

        store.selectNodeFromPointer("n2", mode: .toggle)
        #expect(store.selectedNodeIDs == Set(["n1", "n2"]))

        store.selectNodeFromPointer("n1", mode: .toggle)
        #expect(store.selectedNodeIDs == Set(["n2"]))

        store.selectNodeFromPointer("n1", mode: .replace)
        #expect(store.selectedNodeIDs == Set(["n1"]))
        #expect(store.focusedTarget == .node("n1"))
    }

    @Test("Pointer edge selection toggles and replaces consistently")
    func pointerEdgeSelection() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))
        store.addNode(FlowNode(id: "n3", position: CGPoint(x: 400, y: 0), data: "C"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        store.addEdge(FlowEdge(id: "e2", sourceNodeID: "n2", targetNodeID: "n3"))

        store.selectEdgeFromPointer("e1", mode: .toggle)
        store.selectEdgeFromPointer("e2", mode: .toggle)
        #expect(store.selectedEdgeIDs == Set(["e1", "e2"]))

        store.selectEdgeFromPointer("e1", mode: .toggle)
        #expect(store.selectedEdgeIDs == Set(["e2"]))

        store.selectEdgeFromPointer("e1", mode: .replace)
        #expect(store.selectedEdgeIDs == Set(["e1"]))
        #expect(store.focusedTarget == .edge("e1"))
    }

    @Test("Pointer canvas selection clears only in replace mode")
    func pointerCanvasSelection() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.selectNodeFromPointer("n1", mode: .replace)

        store.selectCanvasFromPointer(mode: .toggle)
        #expect(store.selectedNodeIDs == Set(["n1"]))

        store.selectCanvasFromPointer(mode: .replace)
        #expect(store.selectedNodeIDs.isEmpty)
        #expect(store.focusedTarget == nil)
    }

    @Test("Pointer drag selection matches node selection")
    func pointerDragSelection() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 100, y: 0), data: "B"))

        let didBeginSingleDrag = store.beginNodeDragFromPointer("n1", mode: .replace)
        #expect(didBeginSingleDrag == true)
        #expect(store.selectedNodeIDs == Set(["n1"]))
        #expect(store.focusedTarget == .node("n1"))
        #expect(store.activeInteraction == .draggingNodes(["n1"]))
        store.endNodeDrag()

        store.selectNodeFromPointer("n2", mode: .toggle)
        let didBeginMultiDrag = store.beginNodeDragFromPointer("n1", mode: .replace)
        #expect(didBeginMultiDrag == true)
        #expect(store.selectedNodeIDs == Set(["n1", "n2"]))
        #expect(store.focusedTarget == .node("n1"))
        #expect(store.activeInteraction == .draggingNodes(["n1", "n2"]))
    }

    @Test("Focus ignores missing targets and clears explicitly")
    func focusLifecycle() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))

        store.focusNode("missing")
        #expect(store.focusedTarget == nil)

        store.focusNode("n1")
        #expect(store.focusedTarget == .node("n1"))

        store.focusEdge("e1")
        #expect(store.focusedTarget == .edge("e1"))

        store.focusEdge("missing")
        #expect(store.focusedTarget == .edge("e1"))

        store.clearFocus()
        #expect(store.focusedTarget == nil)
    }

    @Test("Clear selection")
    func clearSelection() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        store.selectNode("n1", exclusive: false)
        store.selectEdge("e1", exclusive: false)
        #expect(store.selectedNodeIDs.count == 1)
        #expect(store.selectedEdgeIDs.count == 1)

        store.clearSelection()
        #expect(store.selectedNodeIDs.isEmpty)
        #expect(store.selectedEdgeIDs.isEmpty)
        #expect(store.nodes[0].isSelected == false)
        #expect(store.edges[0].isSelected == false)
    }

    // MARK: - Hover

    @Test("Set hovered node updates isHovered and hoveredNodeID")
    func setHoveredNode() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))

        store.setHoveredNode("n1")
        #expect(store.hoveredNodeID == "n1")
        #expect(store.nodes[0].isHovered == true)
        #expect(store.nodeLookup["n1"]?.isHovered == true)
        #expect(store.nodes[1].isHovered == false)
    }

    @Test("Set hovered node clears previous hover")
    func setHoveredNodeClearsPrevious() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))

        store.setHoveredNode("n1")
        store.setHoveredNode("n2")
        #expect(store.hoveredNodeID == "n2")
        #expect(store.nodes[0].isHovered == false)
        #expect(store.nodes[1].isHovered == true)
        #expect(store.nodeLookup["n1"]?.isHovered == false)
        #expect(store.nodeLookup["n2"]?.isHovered == true)
    }

    @Test("Set hovered node to nil clears hover")
    func setHoveredNodeNil() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))

        store.setHoveredNode("n1")
        store.setHoveredNode(nil)
        #expect(store.hoveredNodeID == nil)
        #expect(store.nodes[0].isHovered == false)
    }

    @Test("Set hovered node with same ID is no-op")
    func setHoveredNodeSameID() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))

        store.setHoveredNode("n1")
        store.setHoveredNode("n1")
        #expect(store.hoveredNodeID == "n1")
        #expect(store.nodes[0].isHovered == true)
    }

    @Test("Remove hovered node clears hoveredNodeID")
    func removeHoveredNode() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.setHoveredNode("n1")
        #expect(store.hoveredNodeID == "n1")

        store.removeNode("n1")
        #expect(store.hoveredNodeID == nil)
    }

    @Test("Set hovered node with non-existent ID")
    func setHoveredNodeNonExistent() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))

        store.setHoveredNode("nonexistent")
        #expect(store.hoveredNodeID == "nonexistent")
        #expect(store.nodes[0].isHovered == false)
    }

    @Test("Hover and selection are independent")
    func hoverAndSelectionIndependent() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))

        store.setHoveredNode("n1")
        store.selectNode("n1")
        #expect(store.nodes[0].isHovered == true)
        #expect(store.nodes[0].isSelected == true)

        store.setHoveredNode(nil)
        #expect(store.nodes[0].isHovered == false)
        #expect(store.nodes[0].isSelected == true)

        store.setHoveredNode("n1")
        store.clearSelection()
        #expect(store.nodes[0].isHovered == true)
        #expect(store.nodes[0].isSelected == false)
    }

    @Test("Export resets isHovered")
    func exportResetsHovered() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.setHoveredNode("n1")

        let doc = store.export()
        #expect(doc.nodes.allSatisfy { !$0.isHovered })
    }

    @Test("Export excludes transient nodes and dangling edges")
    func exportExcludesTransientNodes() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(
            id: "draft",
            position: CGPoint(x: 100, y: 0),
            data: "Draft",
            phase: .draft(.neutral),
            persistence: .transient
        ))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "draft"))

        let doc = store.export()
        #expect(doc.nodes.count == 1)
        #expect(doc.nodes.first?.id == "n1")
        #expect(doc.edges.isEmpty)
    }

    @Test("Load resets hoveredNodeID")
    func loadResetsHovered() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.setHoveredNode("n1")

        let doc = store.export()
        store.load(doc)
        #expect(store.hoveredNodeID == nil)
        #expect(store.nodes.allSatisfy { !$0.isHovered })
    }

    @Test("Load clears connection draft")
    func loadClearsConnectionDraft() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 100, y: 0), data: "B"))
        store.connectionDraft = ConnectionDraft(
            sourceNodeID: "n1",
            sourceHandleID: "source",
            sourceHandleType: .source,
            sourceHandlePosition: .right,
            targetNodeID: "n2",
            targetHandleID: "target",
            currentPoint: CGPoint(x: 40, y: 20)
        )

        store.load(store.export())

        #expect(store.connectionDraft == nil)
    }

    @Test("Set node snapshot ignores missing nodes")
    func setNodeSnapshotIgnoresMissingNodes() {
        let store = FlowStore<String>()
        let snapshot = makeSnapshot()

        store.setNodeSnapshot(snapshot, for: "missing")
        #expect(store.nodeSnapshots["missing"] == nil)

        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.setNodeSnapshot(snapshot, for: "n1")
        #expect(store.nodeSnapshots["n1"] == snapshot)

        store.removeNode("n1")
        store.setNodeSnapshot(snapshot, for: "n1")
        #expect(store.nodeSnapshots["n1"] == nil)
    }

    @Test("Snapshot generation rejects stale writes after load")
    func snapshotGenerationRejectsStaleWritesAfterLoad() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "old"))
        let staleGeneration = store.currentSnapshotGeneration()
        let snapshot = makeSnapshot()

        let document = FlowDocument(
            nodes: [FlowNode(id: "n1", position: .zero, data: "new")],
            edges: [],
            viewport: Viewport()
        )
        store.load(document)

        store.setNodeSnapshot(snapshot, for: "n1", generation: staleGeneration)
        #expect(store.nodeSnapshots["n1"] == nil)

        store.setNodeSnapshot(snapshot, for: "n1", generation: store.currentSnapshotGeneration())
        #expect(store.nodeSnapshots["n1"] == snapshot)
    }

    @Test("Load normalizes decoded transient UI state")
    func loadNormalizesDecodedTransientUIState() {
        let store = FlowStore<String>()
        var firstNode = FlowNode(id: "n1", position: .zero, data: "A", isSelected: true)
        firstNode.isHovered = true
        firstNode.isDropTarget = true
        let secondNode = FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B")
        var edge = FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2", isSelected: true)
        edge.isDropTarget = true

        store.load(FlowDocument(
            nodes: [firstNode, secondNode],
            edges: [edge],
            viewport: Viewport()
        ))

        #expect(store.selectedNodeIDs.isEmpty)
        #expect(store.selectedEdgeIDs.isEmpty)
        #expect(store.nodes.allSatisfy { !$0.isSelected && !$0.isHovered && !$0.isDropTarget })
        #expect(store.edges.allSatisfy { !$0.isSelected && !$0.isDropTarget })
    }

    // MARK: - Viewport

    @Test("Viewport pan")
    func viewportPan() {
        let store = FlowStore<String>()
        store.pan(by: CGSize(width: 50, height: -30))
        #expect(store.viewport.offset == CGPoint(x: 50, y: -30))
    }

    @Test("Viewport zoom")
    func viewportZoom() {
        let store = FlowStore<String>()
        store.zoom(by: 2.0, anchor: .zero)
        #expect(store.viewport.zoom == 2.0)
    }

    @Test("Zoom respects min/max bounds")
    func zoomBounds() {
        var config = FlowConfiguration()
        config.minZoom = 0.5
        config.maxZoom = 2.0
        let store = FlowStore<String>(configuration: config)

        store.zoom(by: 0.1, anchor: .zero)
        #expect(store.viewport.zoom >= 0.5)

        store.viewport.zoom = 1.0
        store.zoom(by: 10.0, anchor: .zero)
        #expect(store.viewport.zoom <= 2.0)
    }

    @Test("Node bounds calculation")
    func nodeBounds() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: CGPoint(x: 10, y: 20), size: CGSize(width: 100, height: 50), data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 300), size: CGSize(width: 80, height: 40), data: "B"))

        let bounds = store.nodeBounds()
        #expect(bounds.minX == 10)
        #expect(bounds.minY == 20)
        #expect(bounds.maxX == 280)
        #expect(bounds.maxY == 340)
    }

    @Test("Edges for node query")
    func edgesForNode() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))
        store.addNode(FlowNode(id: "n3", position: CGPoint(x: 400, y: 0), data: "C"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        store.addEdge(FlowEdge(id: "e2", sourceNodeID: "n2", targetNodeID: "n3"))
        store.addEdge(FlowEdge(id: "e3", sourceNodeID: "n3", targetNodeID: "n1"))

        let n1Edges = store.edgesForNode("n1")
        #expect(n1Edges.count == 2)

        let n2Edges = store.edgesForNode("n2")
        #expect(n2Edges.count == 2)
    }

    @Test("Document export and load round-trip")
    func documentRoundTrip() throws {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: CGPoint(x: 10, y: 20), data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 100), data: "B"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        store.selectNode("n1")
        store.viewport.zoom = 1.5

        let doc = store.export()
        #expect(doc.nodes.allSatisfy { !$0.isSelected })

        let jsonData = try doc.encoded()
        let decoded = try FlowDocument<String>.decoded(from: jsonData)
        #expect(decoded.nodes.count == 2)
        #expect(decoded.edges.count == 1)
        #expect(decoded.viewport.zoom == 1.5)

        let store2 = FlowStore<String>()
        store2.load(decoded)
        #expect(store2.nodes.count == 2)
        #expect(store2.edges.count == 1)
        #expect(store2.selectedNodeIDs.isEmpty)
    }

    @Test("Connection validation - default rejects self-loop")
    func connectionValidation() {
        let validator = DefaultConnectionValidator()
        let selfLoop = ConnectionProposal(sourceNodeID: "n1", targetNodeID: "n1")
        #expect(!validator.validate(selfLoop))

        let valid = ConnectionProposal(sourceNodeID: "n1", targetNodeID: "n2")
        #expect(validator.validate(valid))
    }

    // MARK: - Remove Cleanup

    @Test("Remove node cleans up selectedNodeIDs")
    func removeNodeCleansSelection() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 100, y: 0), data: "B"))
        store.selectNode("n1", exclusive: false)
        store.selectNode("n2", exclusive: false)
        #expect(store.selectedNodeIDs.count == 2)

        store.removeNode("n1")
        #expect(!store.selectedNodeIDs.contains("n1"))
        #expect(store.selectedNodeIDs.contains("n2"))
    }

    @Test("Remove node cleans up cascaded edge selection")
    func removeNodeCleansEdgeSelection() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        store.selectEdge("e1")
        #expect(store.selectedEdgeIDs.contains("e1"))

        store.removeNode("n1")
        #expect(!store.selectedEdgeIDs.contains("e1"))
    }

    @Test("Remove edge cleans up selectedEdgeIDs")
    func removeEdgeCleansSelection() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        store.selectEdge("e1")
        #expect(store.selectedEdgeIDs.contains("e1"))

        store.removeEdge("e1")
        #expect(!store.selectedEdgeIDs.contains("e1"))
    }

    // MARK: - HandleInfo (computed from HandleDeclaration)

    @Test("HandleInfo computed from handle declaration")
    func handleInfoFromDeclaration() {
        let store = FlowStore<String>()
        let node = FlowNode(
            id: "n1",
            position: CGPoint(x: 100, y: 200),
            size: CGSize(width: 150, height: 60),
            data: "A",
            handles: [
                HandleDeclaration(id: "out", type: .source, position: .right),
                HandleDeclaration(id: "in", type: .target, position: .top),
            ]
        )
        store.addNode(node)

        let sourceInfo = store.handleInfo(nodeID: "n1", handleID: "out")
        #expect(sourceInfo?.position == .right)
        #expect(sourceInfo?.type == .source)
        #expect(sourceInfo?.point == CGPoint(x: 250, y: 230))

        let targetInfo = store.handleInfo(nodeID: "n1", handleID: "in")
        #expect(targetInfo?.position == .top)
        #expect(targetInfo?.type == .target)
        #expect(targetInfo?.point == CGPoint(x: 175, y: 200))
    }

    @Test("HandleInfo for bottom position")
    func handleInfoBottom() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(
            id: "n1",
            position: CGPoint(x: 0, y: 0),
            size: CGSize(width: 100, height: 50),
            data: "A",
            handles: [HandleDeclaration(id: "src", type: .source, position: .bottom)]
        ))

        let info = store.handleInfo(nodeID: "n1", handleID: "src")
        #expect(info?.point == CGPoint(x: 50, y: 50))
        #expect(info?.position == .bottom)
    }

    @Test("HandleInfo for left position")
    func handleInfoLeft() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(
            id: "n1",
            position: CGPoint(x: 100, y: 100),
            size: CGSize(width: 80, height: 40),
            data: "A",
            handles: [HandleDeclaration(id: "tgt", type: .target, position: .left)]
        ))

        let info = store.handleInfo(nodeID: "n1", handleID: "tgt")
        #expect(info?.point == CGPoint(x: 100, y: 120))
        #expect(info?.position == .left)
    }

    @Test("HandleInfo fallback returns node center")
    func handleInfoFallback() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: CGPoint(x: 100, y: 200), size: CGSize(width: 80, height: 40), data: "A"))

        let info = store.handleInfo(nodeID: "n1", handleID: nil)
        #expect(info?.point == CGPoint(x: 140, y: 220))
    }

    @Test("HandleInfo returns nil for unknown handle ID")
    func handleInfoUnknownHandle() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))

        let info = store.handleInfo(nodeID: "n1", handleID: "nonexistent")
        #expect(info == nil)
    }

    // MARK: - Find Nearest Handle

    @Test("Find nearest handle by distance")
    func findNearestHandle() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(
            id: "n1", position: CGPoint(x: 0, y: 0), size: CGSize(width: 100, height: 50), data: "A",
            handles: [HandleDeclaration(id: "out", type: .source, position: .right)]
        ))
        store.addNode(FlowNode(
            id: "n2", position: CGPoint(x: 150, y: 0), size: CGSize(width: 100, height: 50), data: "B",
            handles: [HandleDeclaration(id: "in", type: .target, position: .left)]
        ))
        store.addNode(FlowNode(
            id: "n3", position: CGPoint(x: 300, y: 0), size: CGSize(width: 100, height: 50), data: "C",
            handles: [HandleDeclaration(id: "in", type: .target, position: .left)]
        ))

        // n2 left handle at (150, 25), n3 left handle at (300, 25)
        let result = store.findNearestHandle(at: CGPoint(x: 155, y: 25), excludingNodeID: "n1", targetType: .target, threshold: 20)
        #expect(result?.nodeID == "n2")
        #expect(result?.handleID == "in")
    }

    @Test("Find nearest handle excludes source node")
    func findNearestHandleExcludesSource() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(
            id: "n1", position: .zero, size: CGSize(width: 100, height: 50), data: "A",
            handles: [HandleDeclaration(id: "in", type: .target, position: .left)]
        ))

        let result = store.findNearestHandle(at: CGPoint(x: 0, y: 25), excludingNodeID: "n1", targetType: .target, threshold: 20)
        #expect(result == nil)
    }

    @Test("Find nearest handle respects threshold")
    func findNearestHandleThreshold() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(
            id: "n2", position: CGPoint(x: 200, y: 0), size: CGSize(width: 100, height: 50), data: "B",
            handles: [HandleDeclaration(id: "in", type: .target, position: .left)]
        ))

        // n2 left handle at (200, 25), far from (0, 0)
        let tooFar = store.findNearestHandle(at: CGPoint(x: 0, y: 0), excludingNodeID: "n1", targetType: .target, threshold: 20)
        #expect(tooFar == nil)
    }

    @Test("Find nearest handle filters by type")
    func findNearestHandleFiltersByType() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(
            id: "n2", position: CGPoint(x: 0, y: 0), size: CGSize(width: 100, height: 50), data: "B",
            handles: [HandleDeclaration(id: "out", type: .source, position: .right)]
        ))

        // Looking for .target but only .source available
        let result = store.findNearestHandle(at: CGPoint(x: 100, y: 25), excludingNodeID: "n1", targetType: .target, threshold: 20)
        #expect(result == nil)
    }

    // MARK: - Hit Testing

    @Test("Hit test node returns topmost")
    func hitTestNode() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: CGPoint(x: 0, y: 0), size: CGSize(width: 100, height: 50), data: "A", zIndex: 0))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 50, y: 25), size: CGSize(width: 100, height: 50), data: "B", zIndex: 1))

        // Point in overlap area — n2 is later in array so hit first (reversed iteration)
        let result = store.hitTestNode(at: CGPoint(x: 75, y: 40))
        #expect(result == "n2")
    }

    @Test("Hit test node returns nil for empty space")
    func hitTestNodeMiss() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: CGPoint(x: 0, y: 0), size: CGSize(width: 100, height: 50), data: "A"))

        let result = store.hitTestNode(at: CGPoint(x: 500, y: 500))
        #expect(result == nil)
    }

    @Test("Hit test handle returns nearest within threshold")
    func hitTestHandle() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(
            id: "n1", position: CGPoint(x: 0, y: 0), size: CGSize(width: 100, height: 50), data: "A",
            handles: [
                HandleDeclaration(id: "tgt", type: .target, position: .top),
                HandleDeclaration(id: "src", type: .source, position: .bottom),
            ]
        ))

        // Top handle at (50, 0)
        let result = store.hitTestHandle(at: CGPoint(x: 52, y: 2), threshold: 10)
        #expect(result?.handleID == "tgt")
        #expect(result?.nodeID == "n1")
    }

    @Test("Hit test handle returns nil when outside threshold")
    func hitTestHandleMiss() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(
            id: "n1", position: CGPoint(x: 0, y: 0), size: CGSize(width: 100, height: 50), data: "A"
        ))

        let result = store.hitTestHandle(at: CGPoint(x: 500, y: 500), threshold: 10)
        #expect(result == nil)
    }

    // MARK: - Fit To Content

    @Test("Fit to content uses canvas size")
    func fitToContentCanvasSize() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: CGPoint(x: 0, y: 0), size: CGSize(width: 100, height: 50), data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 100), size: CGSize(width: 100, height: 50), data: "B"))

        store.fitToContent(canvasSize: CGSize(width: 800, height: 600))
        #expect(store.viewport.zoom > 0)
        #expect(store.viewport.zoom <= 1.0)
    }

    @Test("Fit to content with small canvas zooms out")
    func fitToContentSmallCanvas() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: CGPoint(x: 0, y: 0), size: CGSize(width: 100, height: 50), data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 500, y: 400), size: CGSize(width: 100, height: 50), data: "B"))

        store.fitToContent(canvasSize: CGSize(width: 300, height: 200))
        #expect(store.viewport.zoom < 1.0)
    }

    // MARK: - Multi Selection

    @Test("Multi-selection disabled forces exclusive selection")
    func multiSelectionDisabled() {
        var config = FlowConfiguration()
        config.multiSelectionEnabled = false
        let store = FlowStore<String>(configuration: config)
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 100, y: 0), data: "B"))

        store.selectNode("n1", exclusive: false)
        store.selectNode("n2", exclusive: false)
        #expect(store.selectedNodeIDs.count == 1)
        #expect(store.selectedNodeIDs.contains("n2"))
    }

    @Test("SelectInRect disabled when multiSelection off")
    func selectInRectDisabled() {
        var config = FlowConfiguration()
        config.multiSelectionEnabled = false
        let store = FlowStore<String>(configuration: config)
        store.addNode(FlowNode(id: "n1", position: CGPoint(x: 10, y: 10), size: CGSize(width: 50, height: 50), data: "A"))

        store.selectInRect(SelectionRect(origin: .zero, size: CGSize(width: 100, height: 100)))
        #expect(store.selectedNodeIDs.isEmpty)
        #expect(store.selectedEdgeIDs.isEmpty)
    }

    @Test("SelectInRect selects edges intersecting the rect")
    func selectInRectEdges() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(
            id: "n1", position: CGPoint(x: 0, y: 0),
            size: CGSize(width: 100, height: 50), data: "A",
            handles: [HandleDeclaration(id: "out", type: .source, position: .right)]
        ))
        store.addNode(FlowNode(
            id: "n2", position: CGPoint(x: 300, y: 0),
            size: CGSize(width: 100, height: 50), data: "B",
            handles: [HandleDeclaration(id: "in", type: .target, position: .left)]
        ))
        store.addEdge(FlowEdge(
            id: "e1", sourceNodeID: "n1", sourceHandleID: "out",
            targetNodeID: "n2", targetHandleID: "in"
        ))

        // Selection rect covering the middle area (where the edge passes)
        store.selectInRect(SelectionRect(
            origin: CGPoint(x: 120, y: -20),
            size: CGSize(width: 160, height: 90)
        ))

        #expect(store.selectedEdgeIDs.contains("e1"))
        // Nodes are outside the rect
        #expect(!store.selectedNodeIDs.contains("n1"))
        #expect(!store.selectedNodeIDs.contains("n2"))
    }

    // MARK: - Lookup Consistency

    @Test("NodeLookup stays consistent after multiple operations")
    func lookupConsistency() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 100, y: 0), data: "B"))
        store.addNode(FlowNode(id: "n3", position: CGPoint(x: 200, y: 0), data: "C"))

        store.moveNode("n1", to: CGPoint(x: 50, y: 50))
        #expect(store.nodeLookup["n1"]?.position == CGPoint(x: 50, y: 50))

        store.selectNode("n2")
        #expect(store.nodeLookup["n2"]?.isSelected == true)
        #expect(store.nodeLookup["n1"]?.isSelected == false)

        store.removeNode("n2")
        #expect(store.nodeLookup["n2"] == nil)
        #expect(store.nodeLookup.count == 2)
    }

    // MARK: - Connection Draft

    @Test("Begin connection is idempotent")
    func beginConnectionIdempotent() {
        let store = FlowStore<String>()
        store.beginConnection(nodeID: "n1", handleID: "out", handleType: .source, handlePosition: .right)
        let firstDraft = store.connectionDraft
        #expect(firstDraft != nil)
        #expect(store.activeInteraction == .connecting(sourceNodeID: "n1", sourceHandleID: "out"))

        store.beginConnection(nodeID: "n2", handleID: "in", handleType: .target, handlePosition: .left)
        #expect(store.connectionDraft?.sourceNodeID == "n1")
        #expect(store.activeInteraction == .connecting(sourceNodeID: "n1", sourceHandleID: "out"))
    }

    @Test("Connection draft lifecycle")
    func connectionDraftLifecycle() {
        let store = FlowStore<String>()
        #expect(store.connectionDraft == nil)

        store.beginConnection(nodeID: "n1", handleID: "out", handleType: .source, handlePosition: .right)
        #expect(store.connectionDraft != nil)
        #expect(store.connectionDraft?.sourceHandlePosition == .right)

        store.updateConnection(to: CGPoint(x: 100, y: 100), targetNodeID: "n2", targetHandleID: "in")
        #expect(store.connectionDraft?.currentPoint == CGPoint(x: 100, y: 100))
        #expect(store.connectionDraft?.targetNodeID == "n2")
        #expect(store.connectionDraft?.targetHandleID == "in")

        store.cancelConnection()
        #expect(store.connectionDraft == nil)
        #expect(store.activeInteraction == nil)
    }

    @Test("Active interaction tracks drag resize and selection rect")
    func activeInteractionLifecycle() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))

        store.beginNodeDrag("n1")
        #expect(store.activeInteraction == .draggingNodes(["n1"]))
        store.endNodeDrag()
        #expect(store.activeInteraction == nil)

        store.beginResizeNodes(["n1", "missing"])
        #expect(store.activeInteraction == .resizingNodes(["n1"]))
        store.endResizeNodes()
        #expect(store.activeInteraction == nil)

        store.beginSelectionRect()
        #expect(store.activeInteraction == .selectingRect)
        store.endSelectionRect()
        #expect(store.activeInteraction == nil)
    }

    @Test("Remove node clears focus and active interaction ownership")
    func removeNodeClearsFocusAndActiveInteraction() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))

        store.selectNode("n1")
        store.beginNodeDrag("n1")
        #expect(store.focusedTarget == .node("n1"))
        #expect(store.activeInteraction == .draggingNodes(["n1"]))

        store.removeNode("n1")
        #expect(store.focusedTarget == nil)
        #expect(store.activeInteraction == nil)
        #expect(store.isNodeDragging == false)
    }

    @Test("FlowNode defaults to normal persistent state")
    func flowNodeDefaultPhaseAndPersistence() {
        let node = FlowNode(id: "n1", position: .zero, data: "Test")
        #expect(node.phase == .normal)
        #expect(node.persistence == .persistent)
    }

    // MARK: - HandleDeclaration

    @Test("Default handles are target(top) and source(bottom)")
    func defaultHandles() {
        let node = FlowNode(id: "n1", position: .zero, data: "Test")
        #expect(node.handles.count == 2)
        #expect(node.handles[0].id == "target")
        #expect(node.handles[0].type == .target)
        #expect(node.handles[0].position == .top)
        #expect(node.handles[1].id == "source")
        #expect(node.handles[1].type == .source)
        #expect(node.handles[1].position == .bottom)
    }

    @Test("Custom handles override defaults")
    func customHandles() {
        let node = FlowNode(
            id: "n1", position: .zero, data: "Test",
            handles: [
                HandleDeclaration(id: "left-in", type: .target, position: .left),
                HandleDeclaration(id: "right-out", type: .source, position: .right),
                HandleDeclaration(id: "bottom-out", type: .source, position: .bottom),
            ]
        )
        #expect(node.handles.count == 3)
    }

    // MARK: - Command+Click Toggle Selection

    @Test("Additive select toggles node into selection")
    func additiveSelectNode() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 100, y: 0), data: "B"))

        store.selectNode("n1")
        #expect(store.selectedNodeIDs == Set(["n1"]))

        // Additive: add n2 without clearing n1
        store.selectNode("n2", exclusive: false)
        #expect(store.selectedNodeIDs == Set(["n1", "n2"]))

        // Toggle: deselect n1
        store.deselectNode("n1")
        #expect(store.selectedNodeIDs == Set(["n2"]))
        #expect(store.nodes.first(where: { $0.id == "n1" })?.isSelected == false)
        #expect(store.nodes.first(where: { $0.id == "n2" })?.isSelected == true)
    }

    @Test("Additive select toggles edge into selection")
    func additiveSelectEdge() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))
        store.addNode(FlowNode(id: "n3", position: CGPoint(x: 400, y: 0), data: "C"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        store.addEdge(FlowEdge(id: "e2", sourceNodeID: "n2", targetNodeID: "n3"))

        store.selectEdge("e1")
        #expect(store.selectedEdgeIDs == Set(["e1"]))

        // Additive: add e2 without clearing e1
        store.selectEdge("e2", exclusive: false)
        #expect(store.selectedEdgeIDs == Set(["e1", "e2"]))

        // Toggle: deselect e1
        store.deselectEdge("e1")
        #expect(store.selectedEdgeIDs == Set(["e2"]))
    }

    @Test("Additive select with multiSelection disabled forces exclusive")
    func additiveSelectMultiSelectionDisabled() {
        var config = FlowConfiguration()
        config.multiSelectionEnabled = false
        let store = FlowStore<String>(configuration: config)
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 100, y: 0), data: "B"))

        store.selectNode("n1")
        // Even with exclusive: false, multiSelection disabled forces exclusive
        store.selectNode("n2", exclusive: false)
        #expect(store.selectedNodeIDs.count == 1)
        #expect(store.selectedNodeIDs.contains("n2"))
    }

    // MARK: - EdgeStyle

    @Test("EdgeStyle defaults")
    func edgeStyleDefaults() {
        let style = EdgeStyle()
        #expect(style.lineWidth == 1.5)
        #expect(style.selectedLineWidth == 2.5)
        #expect(style.dashPattern.isEmpty)
    }

    // MARK: - Interactive Updates

    @Test("Interactive batch coalesces onNodesChange callbacks")
    func interactiveBatchCoalesces() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))

        var callCount = 0
        var observedChanges: [NodeChange<String>] = []
        store.onNodesChange = { changes in
            callCount += 1
            observedChanges.append(contentsOf: changes)
        }

        store.beginInteractiveUpdates()
        for i in 0..<10 {
            store.moveNode("n1", to: CGPoint(x: CGFloat(i * 10), y: 0))
        }
        #expect(callCount == 0)
        store.endInteractiveUpdates()
        #expect(callCount == 1)
        #expect(observedChanges.count == 10)
    }

    @Test("Interactive batch with no changes emits nothing")
    func interactiveBatchNoChanges() {
        let store = FlowStore<String>()
        var callCount = 0
        store.onNodesChange = { _ in callCount += 1 }

        store.beginInteractiveUpdates()
        store.endInteractiveUpdates()
        #expect(callCount == 0)
    }

    @Test("Non-interactive mode preserves per-operation callback")
    func nonInteractivePerOperation() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))

        var callCount = 0
        store.onNodesChange = { _ in callCount += 1 }

        for i in 0..<5 {
            store.moveNode("n1", to: CGPoint(x: CGFloat(i), y: 0))
        }
        #expect(callCount == 5)
    }

    private func makeSnapshot() -> FlowNodeSnapshot {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Failed to create test CGContext.")
        }
        guard let image = context.makeImage() else {
            fatalError("Failed to create test CGImage.")
        }
        return FlowNodeSnapshot(cgImage: image, scale: 1, capturedAt: Date(timeIntervalSince1970: 0))
    }
}
