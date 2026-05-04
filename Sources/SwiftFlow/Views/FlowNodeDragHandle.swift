import SwiftUI

/// A dedicated region a node exposes as its drag-to-move grip.
///
/// The handle owns its own `DragGesture` and tap gesture, driven through
/// the `\.flowNodeInteraction` environment value that `FlowCanvas`
/// publishes for every node it evaluates. That keeps node interaction
/// local to the node body — drags inside the handle move the node, drags
/// outside (e.g. on a `WKWebView`, `MKMapView`, or other native
/// representable in the same body) reach the inner view untouched.
///
/// ```
/// FlowCanvas(store: store) { node, _ in
///     VStack(spacing: 0) {
///         FlowNodeDragHandle {
///             Text(node.data.title)
///                 .frame(maxWidth: .infinity, alignment: .leading)
///                 .padding(6)
///                 .background(.thinMaterial)
///         }
///         LiveNode { MyWebView(url: node.data.url) }
///     }
/// }
/// ```
///
/// `content` defaults to a transparent rectangle so an invisible grip
/// strip can be dropped in with just a frame:
///
/// ```
/// FlowNodeDragHandle()
///     .frame(height: 16)
/// ```
///
/// Multi-selection moves, viewport-zoom normalization, and undo
/// registration are all handled by ``FlowNodeInteractionProxy``, so a
/// drag triggered through the handle behaves exactly like a drag on a
/// rasterized plain node.
///
/// When read outside a Flow node body the proxy is `nil` and gestures
/// become no-ops — the view just renders its content.
public struct FlowNodeDragHandle<Content: View>: View {

    private let content: () -> Content

    @Environment(\.flowNodeInteraction) private var interaction
    @State private var dragStartPositions: [String: CGPoint]?

    public init(@ViewBuilder content: @escaping () -> Content = { Color.clear }) {
        self.content = content
    }

    public var body: some View {
        let drag = DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard let interaction else { return }
                let starts = dragStartPositions ?? interaction.beginMove()
                if dragStartPositions == nil {
                    dragStartPositions = starts
                }
                interaction.updateMove(starts, value.translation)
            }
            .onEnded { _ in
                guard let interaction, let starts = dragStartPositions else {
                    dragStartPositions = nil
                    return
                }
                interaction.endMove(starts)
                dragStartPositions = nil
            }

        return content()
            .contentShape(Rectangle())
            .gesture(drag)
            .onTapGesture {
                interaction?.selectNode(false)
            }
    }
}
