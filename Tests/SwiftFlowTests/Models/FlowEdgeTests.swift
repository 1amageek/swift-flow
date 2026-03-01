import Testing
import Foundation
@testable import SwiftFlow

@Suite("FlowEdge Tests")
struct FlowEdgeTests {

    @Test("Initialize with default values")
    func initDefaults() {
        let edge = FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2")
        #expect(edge.id == "e1")
        #expect(edge.sourceNodeID == "n1")
        #expect(edge.sourceHandleID == nil)
        #expect(edge.targetNodeID == "n2")
        #expect(edge.targetHandleID == nil)
        #expect(edge.pathType == .bezier)
        #expect(edge.isSelected == false)
        #expect(edge.label == nil)
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let edge = FlowEdge(
            id: "e1",
            sourceNodeID: "n1",
            sourceHandleID: "out",
            targetNodeID: "n2",
            targetHandleID: "in",
            pathType: .smoothStep,
            isSelected: true,
            label: "Label"
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(edge)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FlowEdge.self, from: data)
        #expect(decoded == edge)
    }

    @Test("Hashable conformance")
    func hashable() {
        let a = FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2")
        let b = FlowEdge(id: "e2", sourceNodeID: "n1", targetNodeID: "n2")
        let c = FlowEdge(id: "e1", sourceNodeID: "n1", targetNodeID: "n2")
        #expect(a != b)
        #expect(a == c)
    }
}
