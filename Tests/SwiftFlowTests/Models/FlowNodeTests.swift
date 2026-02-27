import Testing
import Foundation
@testable import SwiftFlow

@Suite("FlowNode Tests")
struct FlowNodeTests {

    @Test("Initialize with default values")
    func initDefaults() {
        let node = FlowNode(id: "n1", position: CGPoint(x: 10, y: 20), data: "Hello")
        #expect(node.id == "n1")
        #expect(node.position == CGPoint(x: 10, y: 20))
        #expect(node.size == CGSize(width: 150, height: 60))
        #expect(node.data == "Hello")
        #expect(node.isSelected == false)
        #expect(node.isHovered == false)
        #expect(node.isDraggable == true)
        #expect(node.zIndex == 0)
    }

    @Test("Frame calculation")
    func frame() {
        let node = FlowNode(
            id: "n1",
            position: CGPoint(x: 100, y: 200),
            size: CGSize(width: 80, height: 40),
            data: "Test"
        )
        #expect(node.frame == CGRect(x: 100, y: 200, width: 80, height: 40))
    }

    @Test("Hashable conformance")
    func hashable() {
        let a = FlowNode(id: "n1", position: .zero, data: "A")
        let b = FlowNode(id: "n2", position: .zero, data: "A")
        let c = FlowNode(id: "n1", position: .zero, data: "A")
        #expect(a != b)
        #expect(a == c)
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let node = FlowNode(
            id: "n1",
            position: CGPoint(x: 50, y: 100),
            size: CGSize(width: 200, height: 80),
            data: "TestData",
            isSelected: true,
            isDraggable: false,
            zIndex: 5
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(node)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FlowNode<String>.self, from: data)
        #expect(decoded == node)
    }

    @Test("Codable excludes isHovered")
    func codableExcludesHovered() throws {
        var node = FlowNode(
            id: "n1",
            position: CGPoint(x: 0, y: 0),
            data: "Test"
        )
        node.isHovered = true

        let encoder = JSONEncoder()
        let data = try encoder.encode(node)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FlowNode<String>.self, from: data)
        #expect(decoded.isHovered == false)
    }
}
