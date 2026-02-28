import SwiftUI

/// Preferred placement direction for an accessory view relative to its anchor.
public enum AccessoryPlacement: Sendable {
    /// Above the anchor (default). Flips below if clipped.
    case top
    /// Below the anchor. Flips above if clipped.
    case bottom
    /// Left of the anchor. Flips right if clipped.
    case leading
    /// Right of the anchor. Flips left if clipped.
    case trailing
}

/// Positions and renders an accessory view for a single selected node or edge.
///
/// Placed in a ZStack above the Canvas so that the accessory is a real
/// SwiftUI view (buttons, text fields, etc.) rather than a Canvas symbol.
struct AccessoryOverlay<NodeData: Sendable & Hashable>: View {

    let store: FlowStore<NodeData>
    let canvasSize: CGSize
    let nodeAccessoryBuilder: ((FlowNode<NodeData>) -> AnyView)?
    let edgeAccessoryBuilder: ((FlowEdge) -> AnyView)?
    let nodeAccessoryPlacement: (FlowNode<NodeData>) -> AccessoryPlacement
    let edgeAccessoryPlacement: AccessoryPlacement
    let animation: Animation?

    @State private var accessorySize: CGSize = .zero
    /// Tracks which content ID has been measured, so the display phase
    /// only activates after the measurement phase provides a valid size.
    @State private var measuredID: String?

    var body: some View {
        let content = resolveContent()
        let measured = content != nil
            && measuredID == content?.id
            && accessorySize.width > 0
            && accessorySize.height > 0

        ZStack {
            // Phase 1: Hidden measurement — renders the content off-screen to
            // obtain its intrinsic size before computing the correct position.
            if let content, !measured {
                content.view
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { proxy in
                        proxy.size
                    } action: { newSize in
                        accessorySize = newSize
                        measuredID = content.id
                    }
                    .hidden()
            }

            // Phase 2: Positioned display — the size is known, so
            // accessoryClampedPosition returns the correct location from the
            // very first visible frame.
            if let content, measured {
                let clampedPos = accessoryClampedPosition(
                    anchor: content.anchor,
                    anchorSize: content.anchorSize,
                    accessorySize: accessorySize,
                    canvasSize: canvasSize,
                    placement: content.placement
                )
                content.view
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { proxy in
                        proxy.size
                    } action: { newSize in
                        accessorySize = newSize
                    }
                    .position(clampedPos)
                    .id(content.id)
                    .transition(
                        AccessoryTransition(
                            anchor: content.anchor,
                            canvasSize: canvasSize
                        )
                    )
            }
        }
        .animation(animation, value: measured)
        .allowsHitTesting(measured)
    }

    // MARK: - Content Resolution

    private struct ResolvedContent {
        let id: String
        let view: AnyView
        let anchor: CGPoint
        /// Screen-space size of the anchor element (node or edge label).
        let anchorSize: CGSize
        let placement: AccessoryPlacement
    }

    private func resolveContent() -> ResolvedContent? {
        let totalSelected = store.selectedNodeIDs.count + store.selectedEdgeIDs.count
        guard totalSelected == 1 else { return nil }

        if let nodeID = store.selectedNodeIDs.first,
           let node = store.nodeLookup[nodeID],
           let builder = nodeAccessoryBuilder {
            let anchor = store.viewport.canvasToScreen(
                CGPoint(
                    x: node.position.x + node.size.width / 2,
                    y: node.position.y + node.size.height / 2
                )
            )
            let screenNodeSize = CGSize(
                width: node.size.width * store.viewport.zoom,
                height: node.size.height * store.viewport.zoom
            )
            return ResolvedContent(
                id: "node-\(nodeID)",
                view: builder(node),
                anchor: anchor,
                anchorSize: screenNodeSize,
                placement: nodeAccessoryPlacement(node)
            )
        }

        if let edgeID = store.selectedEdgeIDs.first,
           let edge = store.edges.first(where: { $0.id == edgeID }),
           let builder = edgeAccessoryBuilder {
            guard let anchor = edgeLabelScreenPoint(for: edge) else { return nil }
            return ResolvedContent(
                id: "edge-\(edgeID)",
                view: builder(edge),
                anchor: anchor,
                anchorSize: .zero,
                placement: edgeAccessoryPlacement
            )
        }

        return nil
    }

    // MARK: - Edge Label Position

    private func edgeLabelScreenPoint(for edge: FlowEdge) -> CGPoint? {
        guard let source = store.handleInfo(nodeID: edge.sourceNodeID, handleID: edge.sourceHandleID),
              let target = store.handleInfo(nodeID: edge.targetNodeID, handleID: edge.targetHandleID)
        else { return nil }

        let calculator = FlowStore<NodeData>.pathCalculator(for: edge.pathType)
        let edgePath = calculator.path(
            from: source.point, sourcePosition: source.position,
            to: target.point, targetPosition: target.position
        )
        return store.viewport.canvasToScreen(edgePath.labelPosition)
    }
}

// MARK: - Accessory Transition

/// Custom transition that scales and fades the accessory from/to the
/// node center.
///
/// After `.position()`, the view's frame equals the parent (canvasSize).
/// By computing the node center as a `UnitPoint` within that frame and
/// passing it to `.scaleEffect(anchor:)`, the scale transformation
/// naturally pulls the content toward / pushes it away from the node.
///
/// - Insertion: content grows from near-zero at the node center to full
///   size at its clamped position, while fading in.
/// - Removal: reverses back toward the node center.
struct AccessoryTransition: Transition {
    /// Node (or edge label) center in screen coordinates.
    let anchor: CGPoint
    /// Size of the parent coordinate space (matches the view frame
    /// produced by `.position()`).
    let canvasSize: CGSize

    func body(content: Content, phase: TransitionPhase) -> some View {
        // Convert screen-space anchor to a UnitPoint in the parent frame.
        let scaleAnchor = UnitPoint(
            x: canvasSize.width > 0 ? anchor.x / canvasSize.width : 0.5,
            y: canvasSize.height > 0 ? anchor.y / canvasSize.height : 0.5
        )
        content
            .scaleEffect(phase.isIdentity ? 1 : 0.01, anchor: scaleAnchor)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

// MARK: - Clamped Positioning (free function, not MainActor-isolated)

/// Computes the screen-space center for an accessory view, keeping it within the canvas bounds.
///
/// Places the accessory in the given `placement` direction relative to `anchor`,
/// offset by half the `anchorSize` so the accessory does not overlap the anchor element.
/// If the preferred direction causes clipping, flips to the opposite side.
/// Horizontal/vertical position is clamped so the accessory stays within margins.
func accessoryClampedPosition(
    anchor: CGPoint,
    anchorSize: CGSize = .zero,
    accessorySize: CGSize,
    canvasSize: CGSize,
    placement: AccessoryPlacement = .top,
    spacing: CGFloat = 8,
    margin: CGFloat = 8
) -> CGPoint {
    let halfW = accessorySize.width / 2
    let halfH = accessorySize.height / 2
    let anchorHalfW = anchorSize.width / 2
    let anchorHalfH = anchorSize.height / 2

    var x = anchor.x
    var y = anchor.y

    switch placement {
    case .top:
        // Place above the anchor's top edge, flip below if clipped
        y = anchor.y - anchorHalfH - halfH - spacing
        if y - halfH < margin {
            y = anchor.y + anchorHalfH + halfH + spacing
        }
        if y + halfH > canvasSize.height - margin {
            y = anchor.y - anchorHalfH - halfH - spacing
        }
        x = max(margin + halfW, min(canvasSize.width - margin - halfW, x))

    case .bottom:
        // Place below the anchor's bottom edge, flip above if clipped
        y = anchor.y + anchorHalfH + halfH + spacing
        if y + halfH > canvasSize.height - margin {
            y = anchor.y - anchorHalfH - halfH - spacing
        }
        if y - halfH < margin {
            y = anchor.y + anchorHalfH + halfH + spacing
        }
        x = max(margin + halfW, min(canvasSize.width - margin - halfW, x))

    case .leading:
        // Place left of the anchor's leading edge, flip right if clipped
        x = anchor.x - anchorHalfW - halfW - spacing
        if x - halfW < margin {
            x = anchor.x + anchorHalfW + halfW + spacing
        }
        if x + halfW > canvasSize.width - margin {
            x = anchor.x - anchorHalfW - halfW - spacing
        }
        y = max(margin + halfH, min(canvasSize.height - margin - halfH, y))

    case .trailing:
        // Place right of the anchor's trailing edge, flip left if clipped
        x = anchor.x + anchorHalfW + halfW + spacing
        if x + halfW > canvasSize.width - margin {
            x = anchor.x - anchorHalfW - halfW - spacing
        }
        if x - halfW < margin {
            x = anchor.x + anchorHalfW + halfW + spacing
        }
        y = max(margin + halfH, min(canvasSize.height - margin - halfH, y))
    }

    // Final clamp both axes
    x = max(margin + halfW, min(canvasSize.width - margin - halfW, x))
    y = max(margin + halfH, min(canvasSize.height - margin - halfH, y))

    return CGPoint(x: x, y: y)
}
