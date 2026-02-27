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

    public var body: some View {
        let bounds = store.nodeBounds()
        let expandedBounds = bounds.insetBy(dx: -50, dy: -50)
        let scale = min(
            minimapSize.width / max(expandedBounds.width, 1),
            minimapSize.height / max(expandedBounds.height, 1)
        )

        // Center content within minimap when aspect ratios differ
        let contentWidth = expandedBounds.width * scale
        let contentHeight = expandedBounds.height * scale
        let originX = (minimapSize.width - contentWidth) / 2
        let originY = (minimapSize.height - contentHeight) / 2

        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(.ultraThinMaterial)
                .frame(width: minimapSize.width, height: minimapSize.height)

            ForEach(store.nodes) { node in
                Rectangle()
                    .fill(node.isSelected ? Color.blue : Color.secondary)
                    .frame(
                        width: max(node.size.width * scale, 2),
                        height: max(node.size.height * scale, 2)
                    )
                    .position(
                        x: originX + (node.position.x + node.size.width / 2 - expandedBounds.minX) * scale,
                        y: originY + (node.position.y + node.size.height / 2 - expandedBounds.minY) * scale
                    )
            }

            viewportRect(expandedBounds: expandedBounds, scale: scale, origin: CGPoint(x: originX, y: originY))
        }
        .frame(width: minimapSize.width, height: minimapSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .gesture(minimapDrag(expandedBounds: expandedBounds, scale: scale, origin: CGPoint(x: originX, y: originY)))
    }

    private func viewportRect(expandedBounds: CGRect, scale: CGFloat, origin: CGPoint) -> some View {
        let viewportOrigin = store.viewport.screenToCanvas(.zero)
        let viewportEnd = store.viewport.screenToCanvas(CGPoint(x: canvasSize.width, y: canvasSize.height))
        let width = (viewportEnd.x - viewportOrigin.x) * scale
        let height = (viewportEnd.y - viewportOrigin.y) * scale
        let x = origin.x + (viewportOrigin.x - expandedBounds.minX) * scale + width / 2
        let y = origin.y + (viewportOrigin.y - expandedBounds.minY) * scale + height / 2

        return Rectangle()
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
                store.viewport.offset.x -= dx * store.viewport.zoom
                store.viewport.offset.y -= dy * store.viewport.zoom
            }
    }
}
