import SwiftUI

/// Draws a node's handles using the library default styling (circle
/// `FlowHandle` at each `HandlePosition`, with the connection-draft
/// target highlighted).
///
/// Expects to sit in a frame sized `node.size + FlowHandle.diameter` on
/// each axis — i.e. the handle-inset frame that `FlowCanvas` allocates
/// to every node symbol. `LiveNode` already sizes itself to `node.size`,
/// so the caller only needs to add the handle inset via
/// `.padding(FlowHandle.diameter / 2)` before overlaying these handles:
///
/// ```
/// LiveNode(node: node) { MyLiveView() }
///     .padding(FlowHandle.diameter / 2)
///     .overlay { FlowNodeHandles(node: node, context: ctx) }
/// ```
///
/// Each handle keeps a small explicit `frame(width:height:)` and is
/// positioned with `.position(...)`. This is critical for live/native
/// nodes: an `alignment`-based full-size frame per handle would create
/// transparent hit-test layers covering the whole node body, blocking
/// gestures destined for an underlying `WKWebView` / `MKMapView` /
/// `AVPlayerView`.
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
        GeometryReader { proxy in
            ZStack {
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
                        .frame(width: FlowHandle.diameter, height: FlowHandle.diameter)
                        .position(Self.position(for: handle.position, in: proxy.size))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private static func position(for handlePosition: HandlePosition, in size: CGSize) -> CGPoint {
        let radius = FlowHandle.diameter / 2

        switch handlePosition {
        case .top:
            return CGPoint(x: size.width / 2, y: radius)
        case .bottom:
            return CGPoint(x: size.width / 2, y: size.height - radius)
        case .left:
            return CGPoint(x: radius, y: size.height / 2)
        case .right:
            return CGPoint(x: size.width - radius, y: size.height / 2)
        }
    }
}
