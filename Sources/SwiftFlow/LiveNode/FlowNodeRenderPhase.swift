import SwiftUI

/// Which pass of the dual-phase rendering pipeline is currently evaluating
/// a `nodeContent` closure.
///
/// `FlowCanvas` injects `\.flowNodeRenderPhase` so that `LiveNode` can
/// decide what to return: a cached snapshot (or a placeholder) when the
/// Canvas is rasterizing, versus the real live content when the overlay
/// layer evaluates the same closure for an active node.
///
/// Apps typically don't need to read this directly — `LiveNode` handles
/// the branching. It's exposed so that callers hosting Metal-backed
/// native views (`MKMapView`, `SCNView`, …) can apply SwiftUI modifiers
/// that create offscreen compositing groups (`.clipShape`, `.shadow`,
/// `.drawingGroup`) **only** in the rasterize pass — those modifiers
/// break Metal drawable compositing on the live pass. See
/// ``EnvironmentValues/isFlowNodeActive`` for a worked example.
public enum FlowNodeRenderPhase: Sendable, Hashable {
    /// The Canvas is drawing a snapshot of this node (either the cached
    /// image or its placeholder). Safe to apply any SwiftUI modifier —
    /// the output is rasterized before display.
    case rasterize
    /// The live overlay is hosting this node on top of the Canvas. The
    /// subtree here may contain native representables; avoid modifiers
    /// that force offscreen compositing on Metal-backed layers.
    case live
}

private struct FlowNodeRenderPhaseKey: EnvironmentKey {
    static let defaultValue: FlowNodeRenderPhase = .rasterize
}

private struct FlowNodeIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct IsFlowNodeActiveKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// Which dual-phase rendering pass is currently evaluating a
    /// `nodeContent` closure. See ``FlowNodeRenderPhase`` for the
    /// intended use and trade-offs between the two passes.
    public var flowNodeRenderPhase: FlowNodeRenderPhase {
        get { self[FlowNodeRenderPhaseKey.self] }
        set { self[FlowNodeRenderPhaseKey.self] = newValue }
    }

    var flowNodeID: String? {
        get { self[FlowNodeIDKey.self] }
        set { self[FlowNodeIDKey.self] = newValue }
    }

    /// `true` while the SwiftFlow live overlay considers the enclosing
    /// node active — i.e. the activation predicate returns `true` for it.
    ///
    /// Injected by `LiveNodeOverlay` so downstream SwiftUI views (including
    /// `UIViewRepresentable` / `NSViewRepresentable` wrappers around native
    /// views such as `WKWebView`, `MKMapView`, or `AVPlayerView`) can react
    /// to activation changes without a separate binding. Typical use is to
    /// suspend expensive work while the node is hidden:
    ///
    /// ```swift
    /// struct WebNodeRepresentable: UIViewRepresentable {
    ///     @Environment(\.isFlowNodeActive) private var isActive
    ///     func updateUIView(_ view: WKWebView, context: Context) {
    ///         if isActive { view.resumeAllMediaPlayback() }
    ///         else { view.pauseAllMediaPlayback() }
    ///     }
    /// }
    /// ```
    ///
    /// The subtree stays mounted across activation toggles so WebView /
    /// player state survives; this flag is how apps opt in to pausing
    /// their own internal loops while the overlay is hidden.
    ///
    /// ## Kick-on-activation for Metal-backed views
    ///
    /// Inactive nodes are mounted in the overlay at `opacity(0)` so that
    /// their native view identity is preserved across activation toggles.
    /// Most native views (`WKWebView`, `AVPlayerView`) keep their internal
    /// rendering loops alive in this state and light up instantly once
    /// opacity flips back to 1. **Metal-backed views that gate their draw
    /// pipeline on layer visibility — notably `MKMapView` and `SCNView` —
    /// do not**: while the hosting layer is at opacity 0, their drawable
    /// scheduling is suspended and tile / frame requests are never issued.
    /// When opacity returns to 1 the view is still "paused" and the user
    /// sees blank content until something nudges it.
    ///
    /// Representables wrapping such views should watch for the false → true
    /// edge of `isFlowNodeActive` (via a coordinator that remembers the
    /// last value) and force a fresh render pass. For `MKMapView` the
    /// canonical kick is a layout followed by re-applying the current
    /// region, which reissues tile requests:
    ///
    /// ```swift
    /// struct MapNodeRepresentable: UIViewRepresentable {
    ///     @Environment(\.isFlowNodeActive) private var isActive
    ///
    ///     final class Coordinator { var wasActive = false }
    ///     func makeCoordinator() -> Coordinator { Coordinator() }
    ///
    ///     func updateUIView(_ mv: MKMapView, context: Context) {
    ///         let didActivate = isActive && !context.coordinator.wasActive
    ///         context.coordinator.wasActive = isActive
    ///         guard didActivate else { return }
    ///         mv.setNeedsLayout()
    ///         mv.layoutIfNeeded()
    ///         mv.setRegion(mv.region, animated: false)
    ///     }
    /// }
    /// ```
    ///
    /// ## SwiftUI styling vs Metal-backed views
    ///
    /// SwiftUI modifiers that create an offscreen compositing group —
    /// `.clipShape`, `.shadow`, `.drawingGroup`, `.mask`, non-1 opacity
    /// transitions — force the enclosing subtree to be rendered into an
    /// intermediate buffer. `CAMetalLayer`'s drawable does **not**
    /// participate in that buffer, so hosted `MKMapView` / `SCNView` /
    /// `MTKView` content renders as a flat background color (usually pale
    /// gray) while those modifiers are in effect on the live path.
    ///
    /// The library-level escape hatch is ``FlowNodeRenderPhase``: gate
    /// offscreen-compositing modifiers on `phase == .rasterize` and let
    /// the native view apply its own rounding / shadow at the
    /// `CALayer` level for the live path.
    ///
    /// ```swift
    /// struct PhaseGatedDecoration: ViewModifier {
    ///     @Environment(\.flowNodeRenderPhase) private var phase
    ///     let cornerRadius: CGFloat
    ///     func body(content: Content) -> some View {
    ///         if phase == .rasterize {
    ///             content
    ///                 .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    ///                 .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    ///         } else {
    ///             content    // Live path: rounding & shadow handled by CALayer
    ///         }
    ///     }
    /// }
    /// ```
    public var isFlowNodeActive: Bool {
        get { self[IsFlowNodeActiveKey.self] }
        set { self[IsFlowNodeActiveKey.self] = newValue }
    }
}
