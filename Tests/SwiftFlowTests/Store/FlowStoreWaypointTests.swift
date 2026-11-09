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

    @Test func bezierInterpolatesEveryWaypointAndSupportsHitTesting() throws {
        let source = FlowNode(id: "source", position: .zero, size: .init(width: 20, height: 20), data: "")
        let target = FlowNode(
            id: "target", position: .init(x: 200, y: 0), size: .init(width: 20, height: 20), data: "")
        let first = CGPoint(x: 10, y: -60)
        let second = CGPoint(x: 210, y: -60)
        let edge = FlowEdge(
            id: "curve", sourceNodeID: source.id, targetNodeID: target.id,
            pathType: .bezier, waypoints: [first, first, second])
        let store = FlowStore(nodes: [source, target], edges: [edge])
        let route = try #require(store.edgePath(for: edge))
        var visited: [CGPoint] = []
        var curves: [(start: CGPoint, end: CGPoint, startControl: CGPoint, endControl: CGPoint)] = []
        var current = CGPoint.zero
        route.path.forEach { element in
            switch element {
            case .move(to: let point), .line(to: let point):
                current = point
            case .curve(to: let end, control1: let first, control2: let second):
                curves.append((current, end, first, second))
                current = end
            default: Issue.record("Expected lines and cubic segments")
            }
            if current == first || current == second { visited.append(current) }
        }
        #expect(visited == [first, second])
        #expect(current == .init(x: 210, y: 10))
        let beforeTurn = try #require(curves.first { $0.end == first })
        let afterTurn = try #require(curves.first { $0.start == first })
        let incoming = beforeTurn.endControl
        let outgoing = afterTurn.startControl
        #expect(abs((first.x - incoming.x) - (outgoing.x - first.x)) < 0.0001)
        #expect(abs((first.y - incoming.y) - (outgoing.y - first.y)) < 0.0001)
        #expect(incoming.x < first.x && incoming.y > first.y)
        #expect(route.targetVector?.dx == 0 && (route.targetVector?.dy ?? 0) > 0)

        let curveMidpoint = CGPoint(
            x: (afterTurn.start.x + 3 * afterTurn.startControl.x
                + 3 * afterTurn.endControl.x + afterTurn.end.x) / 8,
            y: (afterTurn.start.y + 3 * afterTurn.startControl.y
                + 3 * afterTurn.endControl.y + afterTurn.end.y) / 8)
        #expect(curveMidpoint.y < -60.5)
        #expect(store.hitTestEdge(at: curveMidpoint, threshold: 0.25) == edge.id)
        #expect(store.hitTestEdge(at: .init(x: curveMidpoint.x, y: -60), threshold: 0.25) == nil)
        #expect(store.hitTestEdge(at: route.labelPosition, threshold: 0.5) == edge.id)
        store.selectInRect(.init(
            origin: .init(x: route.labelPosition.x - 0.5, y: route.labelPosition.y - 0.5),
            size: .init(width: 1, height: 1)))
        #expect(store.selectedEdgeIDs == [edge.id])

        store.updateEdge(edge.id) { $0.sharpWaypointIndices = [1] }
        let partiallyCurved = try #require(store.edgesForNode(source.id).first)
        #expect(partiallyCurved.sharpWaypointIndices == [1])
        #expect(store.hitTestEdge(at: curveMidpoint, threshold: 0.25) == nil)
        #expect(store.hitTestEdge(at: .init(x: curveMidpoint.x, y: -60), threshold: 0.25) == edge.id)
        store.updateEdge(edge.id) { $0.pathType = .straight }
        let straight = try #require(store.edgesForNode(source.id).first)
        #expect(store.edgePath(for: straight)?.labelPosition == .init(x: 110, y: -60))
        #expect(store.hitTestEdge(at: curveMidpoint, threshold: 0.25) == nil)
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
