import SwiftUI

public protocol NodeContent: View {
    associatedtype NodeData: Sendable & Hashable
    init(node: FlowNode<NodeData>)
}
