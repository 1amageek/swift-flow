import CoreGraphics
import Testing
@testable import SwiftFlow

@Suite("FlowStore Handle Hit Area Tests")
@MainActor
struct FlowStoreHandleHitAreaTests {

    @Test("Center handle position resolves to the node center")
    func centerHandlePositionResolvesToNodeCenter() throws {
        let store = FlowStore<String>()
        store.addNode(FlowNode(
            id: "node",
            position: CGPoint(x: 20, y: 40),
            size: CGSize(width: 100, height: 60),
            data: "Node",
            handles: [
                HandleDeclaration(id: "source", type: .source, position: .center)
            ]
        ))

        let info = try #require(store.handleInfo(nodeID: "node", handleID: "source"))

        #expect(info.point == CGPoint(x: 70, y: 70))
        #expect(info.position == .center)
    }

    @Test("Connection start area can be limited to the node border band")
    func connectionStartAreaCanUseNodeBorderBand() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(
            id: "node",
            position: CGPoint(x: 20, y: 40),
            size: CGSize(width: 100, height: 60),
            data: "Node",
            handles: [
                HandleDeclaration(
                    id: "source",
                    type: .source,
                    position: .center,
                    connectionStartArea: .nodeBorder(width: 6),
                    connectionTargetArea: .disabled
                )
            ]
        ))

        #expect(store.hitTestHandle(at: CGPoint(x: 20, y: 70))?.handleID == "source")
        #expect(store.hitTestHandle(at: CGPoint(x: 70, y: 70)) == nil)
    }

    @Test("Connection target area can accept the whole node without becoming a start area")
    func connectionTargetAreaCanUseWholeNodeWithoutStartArea() {
        let store = FlowStore<String>()
        store.addNode(FlowNode(
            id: "source",
            position: CGPoint(x: 0, y: 0),
            data: "Source",
            handles: [
                HandleDeclaration(id: "source", type: .source, position: .center)
            ]
        ))
        store.addNode(FlowNode(
            id: "target",
            position: CGPoint(x: 200, y: 100),
            size: CGSize(width: 120, height: 80),
            data: "Target",
            handles: [
                HandleDeclaration(
                    id: "target",
                    type: .target,
                    position: .center,
                    connectionStartArea: .disabled,
                    connectionTargetArea: .node
                )
            ]
        ))

        let pointInsideTarget = CGPoint(x: 230, y: 120)
        let target = store.findNearestHandle(
            at: pointInsideTarget,
            excludingNodeID: "source",
            targetType: .target
        )

        #expect(target?.nodeID == "target")
        #expect(target?.handleID == "target")
        #expect(store.hitTestHandle(at: pointInsideTarget) == nil)
    }
}
