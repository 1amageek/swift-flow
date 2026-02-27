import SwiftUI

/// Default node view:
/// - Clean card with title centered
/// - Handles protruding on the node border
public struct DefaultNodeContent<NodeData: Sendable & Hashable>: NodeContent {

    public let node: FlowNode<NodeData>

    static var handleInset: CGFloat { FlowHandle.diameter / 2 }

    public init(node: FlowNode<NodeData>) {
        self.node = node
    }

    public var body: some View {
        let inset = Self.handleInset

        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.background)
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                .shadow(
                    color: node.isSelected ? Color.accentColor.opacity(0.35) : .black.opacity(0.08),
                    radius: node.isSelected ? 8 : 3,
                    y: node.isSelected ? 0 : 2
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            node.isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                            lineWidth: node.isSelected ? 1.5 : 0.5
                        )
                }
                .overlay {
                    Text(String(describing: node.data))
                        .font(.system(.subheadline, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
                .padding(inset)

            ForEach(node.handles, id: \.id) { handle in
                FlowHandle(handle.id, type: handle.type, position: handle.position)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: handleAlignment(handle.position))
            }
        }
        .frame(width: node.size.width + inset * 2, height: node.size.height + inset * 2)
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
