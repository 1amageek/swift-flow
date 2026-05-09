import CoreGraphics
import Testing
@testable import SwiftFlow

@Suite("FlowStore Hierarchy Tests")
@MainActor
struct FlowStoreHierarchyTests {

    @Test("Nodes and edges can be nested under a parent node")
    func nestedNodesAndEdges() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "group", position: .zero, data: "Group", acceptsChildren: true))
        store.addNode(FlowNode(id: "child", position: CGPoint(x: 20, y: 20), data: "Child", parentID: "group", acceptsChildren: true))
        store.addNode(FlowNode(id: "nested", position: CGPoint(x: 40, y: 40), data: "Nested", parentID: "child"))
        store.addEdge(FlowEdge(id: "edge", sourceNodeID: "child", targetNodeID: "nested", parentID: "group"))

        #expect(store.childNodes(of: nil).map(\.id) == ["group"])
        #expect(store.childNodes(of: "group").map(\.id) == ["child"])
        #expect(store.childNodes(of: "child").map(\.id) == ["nested"])
        #expect(store.childEdges(of: "group").map(\.id) == ["edge"])
        #expect(store.descendantNodeIDs(of: "group") == Set(["child", "nested"]))
    }

    @Test("Parent assignment rejects cycles")
    func parentCycleRejected() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "group", position: .zero, data: "Group", acceptsChildren: true))
        store.addNode(FlowNode(id: "child", position: CGPoint(x: 20, y: 20), data: "Child", parentID: "group"))

        store.setParent(of: "group", to: "child")

        #expect(store.nodeLookup["group"]?.parentID == nil)
        #expect(store.nodeLookup["child"]?.parentID == "group")
    }

    @Test("Removing a parent node removes descendants and nested edges")
    func removeParentCascadesHierarchy() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "group", position: .zero, data: "Group", acceptsChildren: true))
        store.addNode(FlowNode(id: "child", position: CGPoint(x: 20, y: 20), data: "Child", parentID: "group"))
        store.addNode(FlowNode(id: "outside", position: CGPoint(x: 200, y: 0), data: "Outside"))
        store.addEdge(FlowEdge(id: "inside", sourceNodeID: "child", targetNodeID: "outside", parentID: "group"))
        store.addEdge(FlowEdge(id: "outside", sourceNodeID: "outside", targetNodeID: "outside"))

        store.removeNode("group")

        #expect(store.nodeLookup["group"] == nil)
        #expect(store.nodeLookup["child"] == nil)
        #expect(store.nodeLookup["outside"] != nil)
        #expect(store.edges.map(\.id) == ["outside"])
    }

    @Test("Ungroup removes only the container and reparents direct children")
    func ungroupRemovesContainerOnly() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "root", position: .zero, data: "Root", acceptsChildren: true))
        store.addNode(FlowNode(id: "group", position: CGPoint(x: 10, y: 10), data: "Group", parentID: "root", acceptsChildren: true))
        store.addNode(FlowNode(id: "child", position: CGPoint(x: 20, y: 20), data: "Child", parentID: "group", acceptsChildren: true))
        store.addNode(FlowNode(id: "nested", position: CGPoint(x: 30, y: 30), data: "Nested", parentID: "child"))
        store.addEdge(FlowEdge(id: "inside", sourceNodeID: "child", targetNodeID: "nested", parentID: "group"))
        store.addEdge(FlowEdge(id: "group-edge", sourceNodeID: "group", targetNodeID: "child", parentID: "group"))

        let didUngroup = store.ungroupNode("group")

        #expect(didUngroup)
        #expect(store.nodeLookup["group"] == nil)
        #expect(store.nodeLookup["child"]?.parentID == "root")
        #expect(store.nodeLookup["nested"]?.parentID == "child")
        #expect(store.edges.first(where: { $0.id == "inside" })?.parentID == "root")
        #expect(store.edges.contains { $0.id == "group-edge" } == false)
    }

    @Test("Dragging a parent node moves every descendant")
    func dragParentMovesDescendants() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "group", position: CGPoint(x: 10, y: 10), data: "Group", acceptsChildren: true))
        store.addNode(FlowNode(id: "child", position: CGPoint(x: 30, y: 40), data: "Child", parentID: "group", acceptsChildren: true))
        store.addNode(FlowNode(id: "nested", position: CGPoint(x: 50, y: 60), data: "Nested", parentID: "child"))
        store.addNode(FlowNode(id: "outside", position: CGPoint(x: 200, y: 200), data: "Outside"))

        store.beginNodeDrag("group")
        store.updateNodeDrag(translation: CGSize(width: 15, height: 25))
        store.endNodeDrag()

        #expect(store.nodeLookup["group"]?.position == CGPoint(x: 25, y: 35))
        #expect(store.nodeLookup["child"]?.position == CGPoint(x: 45, y: 65))
        #expect(store.nodeLookup["nested"]?.position == CGPoint(x: 65, y: 85))
        #expect(store.nodeLookup["outside"]?.position == CGPoint(x: 200, y: 200))
    }

    @Test("Dragging an element outside its group clears parent")
    func dragElementOutsideGroupClearsParent() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "group", position: .zero, size: CGSize(width: 120, height: 120), data: "Group", acceptsChildren: true))
        store.addNode(FlowNode(id: "child", position: CGPoint(x: 20, y: 20), size: CGSize(width: 20, height: 20), data: "Child", parentID: "group"))

        store.beginNodeDrag("child")
        store.updateNodeDrag(translation: CGSize(width: 160, height: 0))
        store.endNodeDrag()

        #expect(store.nodeLookup["child"]?.parentID == nil)
    }

    @Test("Dragging an element into a group assigns parent")
    func dragElementIntoGroupAssignsParent() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "group", position: .zero, size: CGSize(width: 160, height: 160), data: "Group", acceptsChildren: true, zIndex: -10))
        store.addNode(FlowNode(id: "child", position: CGPoint(x: 220, y: 20), size: CGSize(width: 20, height: 20), data: "Child"))

        store.beginNodeDrag("child")
        store.updateNodeDrag(translation: CGSize(width: -180, height: 20))
        store.endNodeDrag()

        #expect(store.nodeLookup["child"]?.parentID == "group")
    }

    @Test("Dragging over an element does not assign parent")
    func dragOverElementDoesNotAssignParent() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "element", position: .zero, size: CGSize(width: 160, height: 160), data: "Element"))
        store.addNode(FlowNode(id: "child", position: CGPoint(x: 220, y: 20), size: CGSize(width: 20, height: 20), data: "Child"))

        store.beginNodeDrag("child")
        store.updateNodeDrag(translation: CGSize(width: -180, height: 20))
        store.endNodeDrag()

        #expect(store.nodeLookup["child"]?.parentID == nil)
    }

    @Test("Group selection creates a container node and reparents selected content")
    func groupSelectionCreatesContainer() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "first", position: CGPoint(x: 20, y: 40), size: CGSize(width: 30, height: 20), data: "First"))
        store.addNode(FlowNode(id: "second", position: CGPoint(x: 90, y: 100), size: CGSize(width: 40, height: 30), data: "Second"))
        store.addNode(FlowNode(id: "outside", position: CGPoint(x: 200, y: 200), data: "Outside"))
        store.addEdge(FlowEdge(id: "inside", sourceNodeID: "first", targetNodeID: "second"))
        store.addEdge(FlowEdge(id: "outside", sourceNodeID: "second", targetNodeID: "outside"))
        store.selectNode("first")
        store.selectNode("second", exclusive: false)

        let group = store.groupSelection(id: "group", data: "Group", padding: 10)

        #expect(group?.id == "group")
        #expect(group?.position == CGPoint(x: 10, y: 30))
        #expect(group?.size == CGSize(width: 130, height: 110))
        #expect(group?.acceptsChildren == true)
        #expect(store.nodeLookup["first"]?.parentID == "group")
        #expect(store.nodeLookup["second"]?.parentID == "group")
        #expect(store.nodeLookup["outside"]?.parentID == nil)
        #expect(store.edges.first(where: { $0.id == "inside" })?.parentID == "group")
        #expect(store.edges.first(where: { $0.id == "outside" })?.parentID == nil)
        #expect(store.selectedNodeIDs == Set(["group"]))
    }

    @Test("Document round-trip preserves hierarchy")
    func documentRoundTripPreservesHierarchy() throws {
        let store = FlowStore<String>()
        store.addNode(FlowNode(id: "group", position: .zero, data: "Group", acceptsChildren: true))
        store.addNode(FlowNode(id: "child", position: CGPoint(x: 20, y: 20), data: "Child", parentID: "group"))
        store.addEdge(FlowEdge(id: "edge", sourceNodeID: "group", targetNodeID: "child", parentID: "group"))

        let data = try store.export().encoded()
        let decoded = try FlowDocument<String>.decoded(from: data)

        #expect(decoded.nodes.first(where: { $0.id == "child" })?.parentID == "group")
        #expect(decoded.edges.first(where: { $0.id == "edge" })?.parentID == "group")
    }

    @Test("Load normalizes dangling hierarchy references")
    func loadNormalizesDanglingParents() {
        var child = FlowNode(id: "child", position: .zero, data: "Child", parentID: "missing")
        child.isSelected = true
        let edge = FlowEdge(id: "edge", sourceNodeID: "child", targetNodeID: "child", parentID: "missing")
        let store = FlowStore<String>()

        store.load(FlowDocument(nodes: [child], edges: [edge]))

        #expect(store.nodeLookup["child"]?.parentID == nil)
        #expect(store.edges.first?.parentID == nil)
    }
}
