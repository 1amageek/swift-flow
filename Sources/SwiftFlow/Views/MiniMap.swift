import SwiftUI

public struct MiniMap<Data: Sendable & Hashable>: View {

    let store: FlowStore<Data>
    let canvasSize: CGSize
    let minimapSize: CGSize

    public init(
        store: FlowStore<Data>,
        canvasSize: CGSize,
        minimapSize: CGSize = CGSize(width: 200, height: 150)
    ) {
        self.store = store
        self.canvasSize = canvasSize
        self.minimapSize = minimapSize
    }

    private var expandedBounds: CGRect {
        if store.nodes.isEmpty {
            let vOrigin = store.viewport.screenToCanvas(.zero)
            let vEnd = store.viewport.screenToCanvas(
                CGPoint(x: canvasSize.width, y: canvasSize.height)
            )
            let visible = CGRect(
                x: vOrigin.x, y: vOrigin.y,
                width: vEnd.x - vOrigin.x,
                height: vEnd.y - vOrigin.y
            )
            return visible.insetBy(dx: -visible.width, dy: -visible.height)
        } else {
            return store.nodeBounds().insetBy(dx: -50, dy: -50)
        }
    }

    public var body: some View {
        let bounds = expandedBounds
        let scale = min(
            minimapSize.width / max(bounds.width, 1),
            minimapSize.height / max(bounds.height, 1)
        )

        let contentWidth = bounds.width * scale
        let contentHeight = bounds.height * scale
        let originX = (minimapSize.width - contentWidth) / 2
        let originY = (minimapSize.height - contentHeight) / 2

        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(.ultraThinMaterial)
                .frame(width: minimapSize.width, height: minimapSize.height)

            ForEach(store.nodes) { node in
                RoundedRectangle(cornerRadius: 2)
                    .fill(node.isSelected ? Color.blue : Color.secondary)
                    .frame(
                        width: max(node.size.width * scale, 2),
                        height: max(node.size.height * scale, 2)
                    )
                    .position(
                        x: originX + (node.position.x + node.size.width / 2 - bounds.minX) * scale,
                        y: originY + (node.position.y + node.size.height / 2 - bounds.minY) * scale
                    )
            }

            viewportRect(expandedBounds: bounds, scale: scale, origin: CGPoint(x: originX, y: originY))
        }
        .frame(width: minimapSize.width, height: minimapSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .gesture(minimapDrag(expandedBounds: bounds, scale: scale, origin: CGPoint(x: originX, y: originY)))
    }

    private func viewportRect(expandedBounds: CGRect, scale: CGFloat, origin: CGPoint) -> some View {
        let viewportOrigin = store.viewport.screenToCanvas(.zero)
        let viewportEnd = store.viewport.screenToCanvas(CGPoint(x: canvasSize.width, y: canvasSize.height))
        let width = (viewportEnd.x - viewportOrigin.x) * scale
        let height = (viewportEnd.y - viewportOrigin.y) * scale
        let x = origin.x + (viewportOrigin.x - expandedBounds.minX) * scale + width / 2
        let y = origin.y + (viewportOrigin.y - expandedBounds.minY) * scale + height / 2

        return RoundedRectangle(cornerRadius: 3)
            .strokeBorder(Color.blue.opacity(0.6), lineWidth: 1)
            .frame(width: max(width, 0), height: max(height, 0))
            .position(x: x, y: y)
    }

    private func minimapDrag(expandedBounds: CGRect, scale: CGFloat, origin: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let canvasX = (value.location.x - origin.x) / scale + expandedBounds.minX
                let canvasY = (value.location.y - origin.y) / scale + expandedBounds.minY
                let viewportCenter = store.viewport.screenToCanvas(
                    CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                )
                let dx = canvasX - viewportCenter.x
                let dy = canvasY - viewportCenter.y
                store.pan(by: CGSize(
                    width: -(dx * store.viewport.zoom),
                    height: -(dy * store.viewport.zoom)
                ))
            }
    }
}

#Preview("Empty") {
    let store = FlowStore<String>()
    MiniMap(store: store, canvasSize: CGSize(width: 800, height: 600))
        .padding()
}

#Preview("With Nodes") {
    let store = FlowStore<String>()
    let _ = {
        store.addNode(FlowNode(id: "a", position: CGPoint(x: 50, y: 50), size: CGSize(width: 120, height: 60), data: "A"))
        store.addNode(FlowNode(id: "b", position: CGPoint(x: 300, y: 200), size: CGSize(width: 120, height: 60), data: "B"))
        store.addNode(FlowNode(id: "c", position: CGPoint(x: 150, y: 350), size: CGSize(width: 120, height: 60), data: "C"))
    }()
    MiniMap(store: store, canvasSize: CGSize(width: 800, height: 600))
        .padding()
}
