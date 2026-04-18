import SwiftUI

/// Which pass of the dual-phase rendering pipeline is currently evaluating
/// a `nodeContent` closure.
///
/// Injected by `FlowCanvas` so that `LiveNode` can decide what to return:
/// a cached snapshot (or a placeholder) when the Canvas is rasterizing,
/// versus the real live content when the overlay layer evaluates the same
/// closure for an active node.
enum FlowNodeRenderPhase: Sendable, Hashable {
    case rasterize
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
    var flowNodeRenderPhase: FlowNodeRenderPhase {
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
    public var isFlowNodeActive: Bool {
        get { self[IsFlowNodeActiveKey.self] }
        set { self[IsFlowNodeActiveKey.self] = newValue }
    }
}
