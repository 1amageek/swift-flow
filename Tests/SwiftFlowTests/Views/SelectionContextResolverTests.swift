import CoreGraphics
import Testing
@testable import SwiftFlow

@Suite("Selection Context Resolver Tests")
@MainActor
struct SelectionContextResolverTests {

    @Test("Selected node bounds include canvas and screen coordinates")
    func selectedNodeBounds() {
        let store = FlowStore<String>()
        store.viewport = Viewport(offset: CGPoint(x: 10, y: 20), zoom: 2)
        store.addNode(
            FlowNode(
                id: "first",
                position: CGPoint(x: 10, y: 20),
                size: CGSize(width: 100, height: 50),
                data: "A"
            )
        )
        store.addNode(
            FlowNode(
                id: "second",
                position: CGPoint(x: 200, y: 100),
                size: CGSize(width: 80, height: 40),
                data: "B"
            )
        )

        store.selectNode("first")
        store.selectNode("second", exclusive: false)

        let context = SelectionContextResolver.resolve(
            store: store,
            canvasSize: CGSize(width: 800, height: 600)
        )

        #expect(context?.selectedNodeIDs == Set(["first", "second"]))
        #expect(context?.selectedEdgeIDs.isEmpty == true)
        #expect(context?.boundsInCanvas == CGRect(x: 10, y: 20, width: 270, height: 120))
        #expect(context?.boundsInScreen == CGRect(x: 30, y: 60, width: 540, height: 240))
        #expect(context?.nodeFramesInScreen["first"] == CGRect(x: 30, y: 60, width: 200, height: 100))
        #expect(context?.nodeFramesInScreen["second"] == CGRect(x: 410, y: 220, width: 160, height: 80))
    }

    @Test("Selected edge contributes bounds without selected nodes")
    func selectedEdgeBounds() {
        let store = FlowStore<String>()
        store.addNode(
            FlowNode(
                id: "source",
                position: CGPoint(x: 0, y: 0),
                size: CGSize(width: 100, height: 60),
                data: "A"
            )
        )
        store.addNode(
            FlowNode(
                id: "target",
                position: CGPoint(x: 300, y: 100),
                size: CGSize(width: 100, height: 60),
                data: "B"
            )
        )
        store.addEdge(
            FlowEdge(
                id: "edge",
                sourceNodeID: "source",
                targetNodeID: "target",
                pathType: .straight
            )
        )

        store.selectEdge("edge")

        let context = SelectionContextResolver.resolve(
            store: store,
            canvasSize: CGSize(width: 800, height: 600)
        )

        #expect(context?.selectedNodeIDs.isEmpty == true)
        #expect(context?.selectedEdgeIDs == Set(["edge"]))
        #expect(context?.edgeFramesInCanvas["edge"] != nil)
        #expect(context?.boundsInCanvas != nil)
    }
}
