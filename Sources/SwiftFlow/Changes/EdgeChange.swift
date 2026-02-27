import Foundation

public enum EdgeChange: Sendable {
    case add(FlowEdge)
    case remove(edgeID: String)
    case select(edgeID: String, isSelected: Bool)
    case replace(FlowEdge)
}
