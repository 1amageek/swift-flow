import SwiftUI

/// Draws a node's handles on top of its content.
///
/// Expects to sit in a frame sized `node.size + FlowHandle.diameter` on
/// each axis (i.e. the already-handle-inset frame used by
/// `DefaultNodeContent` and `LiveNode`). Each handle aligns itself to the
/// edge indicated by its `HandlePosition`, and reflects the current
/// connection draft via `context.connectedHandleID`.
///
/// Internal: shared between `DefaultNodeContent` and `LiveNode`.
/// External styling of handles is not part of the public surface yet.
struct FlowNodeHandles<NodeData: Sendable & Hashable>: View {

    let node: FlowNode<NodeData>
    let context: NodeRenderContext

    var body: some View {
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
