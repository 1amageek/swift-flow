import Foundation

public struct FlowDocument<Data: Sendable & Hashable & Codable>: Codable, Sendable {

    public var nodes: [FlowNode<Data>]
    public var edges: [FlowEdge]
    public var viewport: Viewport

    public init(
        nodes: [FlowNode<Data>],
        edges: [FlowEdge],
        viewport: Viewport = Viewport()
    ) {
        self.nodes = nodes
        self.edges = edges
        self.viewport = viewport
    }

    public func encoded() throws -> Foundation.Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decoded(from data: Foundation.Data) throws -> Self {
        let decoder = JSONDecoder()
        return try decoder.decode(Self.self, from: data)
    }
}
