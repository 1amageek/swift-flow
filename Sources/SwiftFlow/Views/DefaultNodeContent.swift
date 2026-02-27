import SwiftUI

public struct DefaultNodeContent<NodeData: Sendable & Hashable>: NodeContent {

    public let node: FlowNode<NodeData>

    public init(node: FlowNode<NodeData>) {
        self.node = node
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.background)
            .shadow(color: node.isSelected ? .blue.opacity(0.5) : .black.opacity(0.15), radius: node.isSelected ? 4 : 2)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(node.isSelected ? Color.blue : Color.gray.opacity(0.3), lineWidth: node.isSelected ? 2 : 1)
            }
            .overlay {
                Text(String(describing: node.data))
                    .font(.caption)
                    .lineLimit(2)
            }
            .overlay {
                // Handles pinned to node edges
                ForEach(node.handles, id: \.id) { handle in
                    FlowHandle(handle.id, type: handle.type, position: handle.position)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: handleAlignment(handle.position))
                }
            }
            .frame(width: node.size.width, height: node.size.height)
    }

    private func handleAlignment(_ position: HandlePosition) -> Alignment {
        switch position {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }
}
