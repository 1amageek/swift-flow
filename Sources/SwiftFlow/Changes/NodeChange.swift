import Foundation

public enum NodeChange<Data: Sendable & Hashable>: Sendable {
    case add(FlowNode<Data>)
    case remove(nodeID: String)
    case position(nodeID: String, position: CGPoint)
    case select(nodeID: String, isSelected: Bool)
    case dimensions(nodeID: String, size: CGSize)
    case replace(FlowNode<Data>)
}
