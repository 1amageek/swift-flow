import Testing
import Foundation
@testable import SwiftFlow

@Suite("FlowStore Undo Tests")
@MainActor
struct FlowStoreUndoTests {

    private func makeStore() -> (FlowStore<String>, UndoManager) {
        let store = FlowStore<String>()
        let undoManager = UndoManager()
        store.undoManager = undoManager
        return (store, undoManager)
    }

    // MARK: - addNode Undo/Redo

    @Test("Undo addNode removes the node")
    func undoAddNode() {
        let (store, undoManager) = makeStore()
        let node = FlowNode(id: "n1", position: .zero, data: "A")
        store.addNode(node)
        #expect(store.nodes.count == 1)

        undoManager.undo()
        #expect(store.nodes.isEmpty)
        #expect(store.nodeLookup["n1"] == nil)
    }

    @Test("Redo addNode restores the node")
    func redoAddNode() {
        let (store, undoManager) = makeStore()
        let node = FlowNode(id: "n1", position: .zero, data: "A")
        store.addNode(node)
        undoManager.undo()
        #expect(store.nodes.isEmpty)

        undoManager.redo()
        #expect(store.nodes.count == 1)
        #expect(store.nodeLookup["n1"] != nil)
    }

    // MARK: - removeNode Undo (with cascaded edges)

    @Test("Undo removeNode restores node and cascaded edges")
    func undoRemoveNode() {
        let (store, undoManager) = makeStore()
        store.undoManager = nil
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        store.undoManager = undoManager

        store.removeNode("n1")
        #expect(store.nodes.count == 1)
        #expect(store.edges.isEmpty)

        undoManager.undo()
        #expect(store.nodes.count == 2)
        #expect(store.nodeLookup["n1"] != nil)
        #expect(store.edges.count == 1)
        #expect(store.edges[0].id == "e1")
    }

    @Test("Redo removeNode re-removes node and edges")
    func redoRemoveNode() {
        let (store, undoManager) = makeStore()
        store.undoManager = nil
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        store.undoManager = undoManager

        store.removeNode("n1")
        undoManager.undo()
        undoManager.redo()
        #expect(store.nodes.count == 1)
        #expect(store.nodeLookup["n1"] == nil)
        #expect(store.edges.isEmpty)
    }

    // MARK: - addEdge Undo/Redo

    @Test("Undo addEdge removes the edge")
    func undoAddEdge() {
        let (store, undoManager) = makeStore()
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        #expect(store.edges.count == 1)

        undoManager.undo()
        #expect(store.edges.isEmpty)
    }

    @Test("Redo addEdge restores the edge")
    func redoAddEdge() {
        let (store, undoManager) = makeStore()
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        undoManager.undo()
        undoManager.redo()
        #expect(store.edges.count == 1)
        #expect(store.edges[0].id == "e1")
    }

    // MARK: - removeEdge Undo/Redo

    @Test("Undo removeEdge restores the edge")
    func undoRemoveEdge() {
        let (store, undoManager) = makeStore()
        store.undoManager = nil
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        store.undoManager = undoManager

        store.removeEdge("e1")
        #expect(store.edges.isEmpty)

        undoManager.undo()
        #expect(store.edges.count == 1)
        #expect(store.edges[0].id == "e1")
    }

    @Test("Redo removeEdge re-removes the edge")
    func redoRemoveEdge() {
        let (store, undoManager) = makeStore()
        store.undoManager = nil
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        store.undoManager = undoManager

        store.removeEdge("e1")
        undoManager.undo()
        undoManager.redo()
        #expect(store.edges.isEmpty)
    }

    // MARK: - completeMoveNodes Undo/Redo

    @Test("Undo completeMoveNodes restores original positions")
    func undoMoveNodes() {
        let (store, undoManager) = makeStore()
        store.undoManager = nil
        store.addNode(FlowNode(id: "n1", position: CGPoint(x: 10, y: 20), data: "A"))
        store.undoManager = undoManager

        let startPositions = ["n1": CGPoint(x: 10, y: 20)]
        store.moveNode("n1", to: CGPoint(x: 100, y: 200))
        store.completeMoveNodes(from: startPositions)
        #expect(store.nodeLookup["n1"]?.position == CGPoint(x: 100, y: 200))

        undoManager.undo()
        #expect(store.nodeLookup["n1"]?.position == CGPoint(x: 10, y: 20))
    }

    @Test("Redo completeMoveNodes re-applies move")
    func redoMoveNodes() {
        let (store, undoManager) = makeStore()
        store.undoManager = nil
        store.addNode(FlowNode(id: "n1", position: CGPoint(x: 10, y: 20), data: "A"))
        store.undoManager = undoManager

        let startPositions = ["n1": CGPoint(x: 10, y: 20)]
        store.moveNode("n1", to: CGPoint(x: 100, y: 200))
        store.completeMoveNodes(from: startPositions)

        undoManager.undo()
        undoManager.redo()
        #expect(store.nodeLookup["n1"]?.position == CGPoint(x: 100, y: 200))
    }

    @Test("completeMoveNodes is no-op when positions unchanged")
    func moveNodesNoChange() {
        let (store, undoManager) = makeStore()
        store.undoManager = nil
        store.addNode(FlowNode(id: "n1", position: CGPoint(x: 10, y: 20), data: "A"))
        store.undoManager = undoManager

        let startPositions = ["n1": CGPoint(x: 10, y: 20)]
        store.completeMoveNodes(from: startPositions)
        #expect(!undoManager.canUndo)
    }

    // MARK: - deleteSelection Undo

    @Test("Undo deleteSelection restores all items and selection")
    func undoDeleteSelection() {
        let (store, undoManager) = makeStore()
        store.undoManager = nil
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))
        store.addNode(FlowNode(id: "n3", position: CGPoint(x: 400, y: 0), data: "C"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        store.addEdge(FlowEdge(id: "e2", sourceNodeID: "n2", targetNodeID: "n3"))
        store.undoManager = undoManager

        store.selectNode("n1", exclusive: false)
        store.selectNode("n2", exclusive: false)
        store.selectEdge("e2", exclusive: false)

        store.deleteSelection()
        #expect(store.nodes.count == 1)
        #expect(store.nodes[0].id == "n3")
        #expect(store.edges.isEmpty)

        undoManager.undo()
        #expect(store.nodes.count == 3)
        #expect(store.edges.count == 2)
        #expect(store.selectedNodeIDs.contains("n1"))
        #expect(store.selectedNodeIDs.contains("n2"))
        #expect(store.selectedEdgeIDs.contains("e2"))
    }

    @Test("Redo deleteSelection re-deletes")
    func redoDeleteSelection() {
        let (store, undoManager) = makeStore()
        store.undoManager = nil
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        store.undoManager = undoManager

        store.selectNode("n1", exclusive: false)
        store.selectNode("n2", exclusive: false)

        store.deleteSelection()
        undoManager.undo()
        undoManager.redo()
        #expect(store.nodes.isEmpty)
        #expect(store.edges.isEmpty)
    }

    // MARK: - undoManager nil safety

    @Test("No undo registered when undoManager is nil")
    func noUndoWhenNil() {
        let store = FlowStore<String>()
        #expect(store.undoManager == nil)

        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.removeNode("n1")
        // No crash, just works without undo
        #expect(store.nodes.isEmpty)
    }

    // MARK: - Empty deleteSelection

    @Test("deleteSelection with empty selection is no-op")
    func deleteSelectionEmpty() {
        let (store, undoManager) = makeStore()
        store.undoManager = nil
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.undoManager = undoManager

        store.deleteSelection()
        #expect(store.nodes.count == 1)
        #expect(!undoManager.canUndo)
    }

    // MARK: - Edge-only deletion

    @Test("deleteSelection with only edges selected")
    func deleteEdgeOnly() {
        let (store, undoManager) = makeStore()
        store.undoManager = nil
        store.addNode(FlowNode(id: "n1", position: .zero, data: "A"))
        store.addNode(FlowNode(id: "n2", position: CGPoint(x: 200, y: 0), data: "B"))
        store.addEdge(FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2"))
        store.undoManager = undoManager

        store.selectEdge("e1")
        store.deleteSelection()
        #expect(store.nodes.count == 2)
        #expect(store.edges.isEmpty)

        undoManager.undo()
        #expect(store.edges.count == 1)
    }
}
