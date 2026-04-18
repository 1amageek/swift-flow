import SwiftUI

/// Draws a node's handles using the library default styling (circle
/// `FlowHandle` at each `HandlePosition`, with the connection-draft
/// target highlighted).
///
/// Expects to sit in a frame sized `node.size + FlowHandle.diameter` on
/// each axis — i.e. the handle-inset frame that `FlowCanvas` allocates
/// to every node symbol and that ``LiveNode`` exposes through its
/// padding. Place it as a sibling overlay / ZStack child so it fills the
/// full allotment and each handle snaps to the correct edge:
///
/// ```
/// LiveNode(node: node, context: ctx) { MyLiveView() }
///     .overlay { FlowNodeHandles(node: node, context: ctx) }
/// ```
///
/// Apps that want custom handle styling (different shape, colors,
/// connection-draft presentation, hit region, etc.) should skip this
/// helper and compose ``FlowHandle`` views directly against
/// `node.handles`.
public struct FlowNodeHandles<NodeData: Sendable & Hashable>: View {

    public let node: FlowNode<NodeData>
    public let context: NodeRenderContext

    public init(node: FlowNode<NodeData>, context: NodeRenderContext) {
        self.node = node
        self.context = context
    }

    public var body: some View {
        ForEach(node.handles, id: \.id) { handle in
            FlowHandle(handle.id, type: handle.type, position: handle.position)
                .overlay {
                    if context.connectedHandleID == handle.id {
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(-4)
                    }
                }
                .scaleEffect(context.connectedHandleID == handle.id ? 1.12 : 1.0)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: Self.alignment(for: handle.position)
                )
        }
    }

    private static func alignment(for position: HandlePosition) -> Alignment {
        switch position {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }
}
