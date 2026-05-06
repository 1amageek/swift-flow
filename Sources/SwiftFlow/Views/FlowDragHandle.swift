import SwiftUI

/// View modifier that turns its host view into a drag handle for a
/// specific `FlowNode`, dispatching through the same `FlowStore` session
/// API as `FlowCanvas.primaryDragGesture`.
///
/// Apply via `.flowDragHandle(for:in:)`. The view this is attached to
/// becomes the **drag zone**; the **target node** is the one identified
/// by `nodeID`. The two can be different — a header overlay drawn on
/// top of a `LiveNode` can drag the `LiveNode` underneath without
/// needing the underlying native view (`WKWebView`, `MKMapView`,
/// `AVPlayerView`) to forward gestures.
///
/// Why a session API instead of forwarding to the Canvas's own gesture:
/// `LiveNode` mounts its content live in an overlay that sits above the
/// `Canvas`. Drags landing inside that overlay never reach the Canvas's
/// `primaryDragGesture` because the live row eats the hit. Routing
/// through `FlowStore.beginNodeDrag` / `updateNodeDrag` / `endNodeDrag`
/// makes both drag sites — Canvas-level and external handle — call the
/// same dispatch, so multi-selection moves, snap-to-grid, and undo
/// behave identically regardless of where the drag started.
struct FlowDragHandleModifier<Data: Sendable & Hashable>: ViewModifier {

    let nodeID: String
    let store: FlowStore<Data>

    /// Per-instance latch. A global / store-level "is some handle active"
    /// flag would race when two handles see overlapping `onChanged` callbacks
    /// during gesture handoff; a `@State` per modifier instance ties the
    /// session lifecycle to this one drag.
    @State private var sessionActive = false

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !sessionActive {
                            if store.selectedNodeIDs.contains(nodeID) {
                                store.focusNode(nodeID)
                            } else {
                                store.selectNode(nodeID)
                            }
                            store.beginNodeDrag(nodeID)
                            guard store.isNodeDragging else { return }
                            sessionActive = true
                        }
                        store.updateNodeDrag(translation: value.translation)
                    }
                    .onEnded { _ in
                        guard sessionActive else { return }
                        store.endNodeDrag()
                        sessionActive = false
                    }
            )
    }
}

public extension View {

    /// Attach a Canvas-equivalent drag gesture to this view that moves
    /// `node` through `store`'s shared drag dispatch.
    ///
    /// Use this on overlays that sit above a `LiveNode` (header bars,
    /// title chips, accessory rows) where the underlying native view
    /// would otherwise consume the drag. The drag zone (this view) and
    /// the moved node (`node`) are decoupled: a header overlay can drag
    /// the `LiveNode` it covers without sharing geometry with it.
    ///
    /// The dispatch path is identical to the Canvas's own drag —
    /// multi-selection moves, snap-to-grid, and undo all behave the same.
    /// `DragGesture` runs in `.global` coordinate space so the moving
    /// target view does not feed back into the translation values.
    ///
    /// ```swift
    /// LiveNode(node: node) {
    ///     WebRepresentable(webView: webView, url: url)
    /// }
    /// .overlay(alignment: .top) {
    ///     headerBar
    ///         .flowDragHandle(for: node, in: store)
    /// }
    /// ```
    func flowDragHandle<Data: Sendable & Hashable>(
        for node: FlowNode<Data>,
        in store: FlowStore<Data>
    ) -> some View {
        modifier(FlowDragHandleModifier(nodeID: node.id, store: store))
    }
}
