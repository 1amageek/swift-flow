import Foundation
import CoreGraphics
import Testing
@testable import SwiftFlow

@Suite("FlowStore Animation", .serialized)
@MainActor
struct FlowStoreAnimationTests {

    private func makeStore() -> FlowStore<String> {
        let store = FlowStore<String>(
            nodes: [
                FlowNode(id: "a", position: .init(x: 0, y: 0), size: .init(width: 100, height: 50), data: "A"),
                FlowNode(id: "b", position: .init(x: 200, y: 0), size: .init(width: 100, height: 50), data: "B"),
                FlowNode(id: "c", position: .init(x: 400, y: 0), size: .init(width: 100, height: 50), data: "C"),
            ],
            edges: [
                FlowEdge(id: "e1", sourceNodeID: "a", targetNodeID: "b"),
            ]
        )
        return store
    }

    @Test("Animated fitToContent changes viewport")
    func animatedFitToContentChangesViewport() async throws {
        let store = makeStore()
        let initialViewport = store.viewport

        store.fitToContent(canvasSize: CGSize(width: 800, height: 600), animation: .default)

        // Let the animation run
        try await Task.sleep(for: .seconds(1))

        #expect(store.viewport.offset != initialViewport.offset || store.viewport.zoom != initialViewport.zoom)
        #expect(!store.isAnimating || store.viewport != initialViewport)
    }

    @Test("Animated zoom reaches target")
    func animatedZoomReachesTarget() async throws {
        let store = makeStore()
        let initialZoom = store.viewport.zoom

        store.zoom(by: 2.0, anchor: CGPoint(x: 400, y: 300), animation: .easeInOut(duration: 0.3))

        try await Task.sleep(for: .seconds(0.8))

        #expect(abs(store.viewport.zoom - initialZoom * 2.0) < 1.0)
    }

    @Test("moveNode cancels node animation")
    func moveNodeCancelsNodeAnimation() async throws {
        let store = makeStore()

        store.setNodePositions(["a": CGPoint(x: 500, y: 500)], animation: .easeInOut(duration: 1.0))

        // Let it start
        try await Task.sleep(for: .milliseconds(50))

        // Cancel by calling moveNode directly
        store.moveNode("a", to: CGPoint(x: 300, y: 300))

        // The node should be at the direct-set position
        #expect(store.nodeLookup["a"]?.position == CGPoint(x: 300, y: 300))
    }

    @Test("pan cancels viewport offset animation")
    func panCancelsViewportAnimation() async throws {
        let store = makeStore()

        store.setViewport(
            Viewport(offset: CGPoint(x: 500, y: 500), zoom: 1.0),
            animation: .easeInOut(duration: 1.0)
        )

        try await Task.sleep(for: .milliseconds(50))

        // Cancel offset animation via pan
        store.pan(by: CGSize(width: 10, height: 10))

        // Viewport should reflect the pan, not the animation target
        let offsetX = store.viewport.offset.x
        #expect(offsetX != 500)
    }

    @Test("Animated edges increment dashPhase")
    func animatedEdgesIncrementDashPhase() async throws {
        let store = makeStore()

        // Add an edge and mark it animated via side-table
        let animatedEdge = FlowEdge(id: "animated", sourceNodeID: "a", targetNodeID: "c")
        store.addEdge(animatedEdge)
        store.setEdgeAnimated("animated", true)

        let initialPhase = store.edgeDashPhase

        // Let the animation loop run
        try await Task.sleep(for: .milliseconds(100))

        #expect(store.edgeDashPhase > initialPhase)
    }

    @Test("setNodePositions animates multiple nodes")
    func setNodePositionsAnimatesMultipleNodes() async throws {
        let store = makeStore()

        store.setNodePositions([
            "a": CGPoint(x: 100, y: 100),
            "b": CGPoint(x: 300, y: 300),
        ], animation: .easeInOut(duration: 0.3))

        try await Task.sleep(for: .seconds(0.8))

        let posA = store.nodeLookup["a"]?.position ?? .zero
        let posB = store.nodeLookup["b"]?.position ?? .zero
        #expect(abs(posA.x - 100) < 2)
        #expect(abs(posA.y - 100) < 2)
        #expect(abs(posB.x - 300) < 2)
        #expect(abs(posB.y - 300) < 2)
    }

    @Test("load cancels all animations")
    func loadCancelsAllAnimations() async throws {
        let store = makeStore()

        // Start some animations
        store.setViewport(Viewport(offset: CGPoint(x: 500, y: 500), zoom: 2.0), animation: .default)
        store.setNodePositions(["a": CGPoint(x: 999, y: 999)], animation: .default)

        // Add edge and mark it animated via side-table
        let animatedEdge = FlowEdge(id: "animated", sourceNodeID: "a", targetNodeID: "b")
        store.addEdge(animatedEdge)
        store.setEdgeAnimated("animated", true)

        try await Task.sleep(for: .milliseconds(50))

        // Load resets everything
        let doc = FlowDocument<String>(
            nodes: [FlowNode(id: "x", position: .zero, size: .init(width: 50, height: 50), data: "X")],
            edges: [],
            viewport: Viewport()
        )
        store.load(doc)

        #expect(store.edgeDashPhase == 0)
        #expect(!store.isAnimating)
        #expect(store.nodes.count == 1)
        #expect(store.nodes.first?.id == "x")
    }
}
