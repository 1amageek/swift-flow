import Foundation
import Testing
@testable import SwiftFlow

@MainActor
struct FlowStoreWaypointTests {
    @Test func selectsAndLabelsTheOrderedRoute() throws {
        let source = FlowNode(id: "source", position: .zero, size: .init(width: 20, height: 20), data: "")
        let target = FlowNode(
            id: "target", position: .init(x: 200, y: 0), size: .init(width: 20, height: 20), data: "")
        let first = CGPoint(x: 10, y: -60)
        let second = CGPoint(x: 210, y: -60)
        let edge = FlowEdge(
            id: "route", sourceNodeID: source.id, targetNodeID: target.id,
            pathType: .straight, waypoints: [first, second])
        let store = FlowStore(nodes: [source, target], edges: [edge])
        let route = try #require(store.edgePath(for: edge))
        var points: [CGPoint] = []
        route.path.forEach { element in
            switch element {
            case .move(to: let point), .line(to: let point): points.append(point)
            default: Issue.record("Expected a polyline")
            }
        }
        #expect(points == [.init(x: 10, y: 10), first, second, .init(x: 210, y: 10)])
        #expect(route.labelPosition == .init(x: 110, y: -60))
        #expect(route.targetVector?.dx == 0 && route.targetVector?.dy == 70)
        #expect(store.hitTestEdge(at: route.labelPosition) == edge.id)
        #expect(store.hitTestEdge(at: .init(x: 110, y: 10)) == nil)

        store.selectInRect(.init(origin: .init(x: 100, y: -65), size: .init(width: 20, height: 10)))
        #expect(store.selectedEdgeIDs == [edge.id])
        store.selectInRect(.init(origin: .init(x: 100, y: -20), size: .init(width: 20, height: 10)))
        #expect(store.selectedEdgeIDs.isEmpty)
        store.moveNode(target.id, to: .init(x: 220, y: 20))
        let moved = try #require(store.edgePath(for: edge))
        #expect(moved.path.currentPoint == .init(x: 230, y: 30))
        #expect(moved.labelPosition == route.labelPosition)

        store.updateEdge(edge.id) { $0.waypoints = [.init(x: CGFloat.infinity, y: 0)] }
        let updated = try #require(store.edgesForNode(source.id).first)
        #expect(store.edgePath(for: updated) == nil)
        #expect(store.hitTestEdge(at: route.labelPosition) == nil)
    }

    @Test func fitIncludesWaypointsOutsideTheNodeBounds() {
        let source = FlowNode(id: "source", position: .zero, data: "")
        let target = FlowNode(id: "target", position: .init(x: 200, y: 0), data: "")
        let outside = CGPoint(x: 125, y: -600)
        let edge = FlowEdge(
            id: "route", sourceNodeID: source.id, targetNodeID: target.id, waypoints: [outside])
        let store = FlowStore(nodes: [source, target], edges: [edge])
        let canvas = CGSize(width: 500, height: 400)
        store.fitToContent(canvasSize: canvas)
        #expect(CGRect(origin: .zero, size: canvas).contains(store.viewport.canvasToScreen(outside)))
    }

}
