import SwiftUI

/// Which pass of the dual-phase rendering pipeline is currently evaluating
/// a `nodeContent` closure.
///
/// `FlowCanvas` injects `\.flowNodeRenderPhase` so that `LiveNode` can
/// decide what to return: a cached snapshot (or a placeholder) when the
/// Canvas is rasterizing, versus the real live content when the overlay
/// layer evaluates the same closure for an interactive node.
///
/// Apps typically don't need to read this directly — `LiveNode` handles
/// the branching. It's exposed so that callers hosting Metal-backed
/// native views (`MKMapView`, `SCNView`, …) can apply SwiftUI modifiers
/// that create offscreen compositing groups (`.clipShape`, `.shadow`,
/// `.drawingGroup`) **only** in the rasterize pass — those modifiers
/// break Metal drawable compositing on the live pass. See
/// ``EnvironmentValues/isFlowNodeInteractive`` for a worked example.
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

private struct IsFlowNodeInteractiveKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct IsFlowNodeSelectedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct IsFlowNodeHoveredKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct IsFlowNodeFocusedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct DefersLiveNodeSnapshotWritesKey: EnvironmentKey {
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
    /// node interactive — i.e. the interaction predicate returns `true`
    /// for it, or the node is warming up its first snapshot.
    ///
    /// This is intentionally distinct from selection. The default
    /// interaction predicate treats a hovered node as interactive so native
    /// content can receive scroll and pointer events like a macOS window
    /// under the cursor, even when the node is not selected. Use
    /// ``EnvironmentValues/isFlowNodeSelected`` and
    /// ``EnvironmentValues/isFlowNodeFocused`` for selection and keyboard
    /// routing.
    ///
    /// Injected by `LiveNodeOverlay` so downstream SwiftUI views (including
    /// `UIViewRepresentable` / `NSViewRepresentable` wrappers around native
    /// views such as `WKWebView`, `MKMapView`, or `AVPlayerView`) can react
    /// to interaction changes without a separate binding. Typical use is to
    /// suspend expensive work while the node is hidden:
    ///
    /// ```swift
    /// struct WebNodeRepresentable: UIViewRepresentable {
    ///     @Environment(\.isFlowNodeInteractive) private var isInteractive
    ///     func updateUIView(_ view: WKWebView, context: Context) {
    ///         if isInteractive { view.resumeAllMediaPlayback() }
    ///         else { view.pauseAllMediaPlayback() }
    ///     }
    /// }
    /// ```
    ///
    /// The subtree stays mounted across interaction toggles so WebView /
    /// player state survives; this flag is how apps opt in to pausing
    /// their own internal loops while the overlay is hidden.
    ///
    /// ## Kick-on-interaction for Metal-backed views
    ///
    /// Inactive nodes are mounted in the overlay at `opacity(0)` so that
    /// their native view identity is preserved across interaction toggles.
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
    /// edge of `isFlowNodeInteractive` (via a coordinator that remembers the
    /// last value) and force a fresh render pass. For `MKMapView` the
    /// canonical kick is a layout followed by re-applying the current
    /// region, which reissues tile requests:
    ///
    /// ```swift
    /// struct MapNodeRepresentable: UIViewRepresentable {
    ///     @Environment(\.isFlowNodeInteractive) private var isInteractive
    ///
    ///     final class Coordinator { var wasInteractive = false }
    ///     func makeCoordinator() -> Coordinator { Coordinator() }
    ///
    ///     func updateUIView(_ mv: MKMapView, context: Context) {
    ///         let didInteract = isInteractive && !context.coordinator.wasInteractive
    ///         context.coordinator.wasInteractive = isInteractive
    ///         guard didInteract else { return }
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
    public var isFlowNodeInteractive: Bool {
        get { self[IsFlowNodeInteractiveKey.self] }
        set { self[IsFlowNodeInteractiveKey.self] = newValue }
    }

    /// `true` when the enclosing flow node is selected in ``FlowStore``.
    ///
    /// This models selection separately from ``isFlowNodeInteractive`` and
    /// ``isFlowNodeFocused``. Live content may be scrollable on hover while
    /// this value remains `false`, matching macOS window behavior.
    public var isFlowNodeSelected: Bool {
        get { self[IsFlowNodeSelectedKey.self] }
        set { self[IsFlowNodeSelectedKey.self] = newValue }
    }

    /// `true` when the pointer is currently over the enclosing flow node.
    ///
    /// This is useful for hover-only affordances that should not imply
    /// selection.
    public var isFlowNodeHovered: Bool {
        get { self[IsFlowNodeHoveredKey.self] }
        set { self[IsFlowNodeHoveredKey.self] = newValue }
    }

    /// `true` when keyboard-directed flow actions target the enclosing node.
    ///
    /// Focus is separate from selection and hover. A hovered LiveNode may
    /// receive scroll or pointer events through hit testing while focus remains
    /// elsewhere.
    public var isFlowNodeFocused: Bool {
        get { self[IsFlowNodeFocusedKey.self] }
        set { self[IsFlowNodeFocusedKey.self] = newValue }
    }

    /// `true` while direct snapshot writes should stay out of the user's
    /// interaction path. Interaction-end capture is still allowed: it is
    /// driven by ``LiveNodeInteractionCoordinator`` after the raw hover /
    /// selection intent has ended, and is cancelled if that intent returns.
    var defersLiveNodeSnapshotWrites: Bool {
        get { self[DefersLiveNodeSnapshotWritesKey.self] }
        set { self[DefersLiveNodeSnapshotWritesKey.self] = newValue }
    }
}
