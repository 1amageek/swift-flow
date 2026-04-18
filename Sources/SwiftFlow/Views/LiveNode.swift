import SwiftUI

/// Declares a node whose body should be rendered as a live SwiftUI view
/// while the node is active, and as a rasterized snapshot while it is
/// inactive — all from a single call site.
///
/// `LiveNode` is a pure phase dispatcher: it emits the snapshot image on
/// the rasterize path and the caller-supplied live view on the live
/// path, and **applies no sizing, padding, clipping, or other styling**.
/// All visual treatment — frame, corner radius, handle-border inset,
/// background, overlay — is the caller's responsibility, composed with
/// ordinary SwiftUI modifiers around `LiveNode`.
///
/// ```
/// FlowCanvas(store: store) { node, ctx in
///     let inset = FlowHandle.diameter / 2
///     LiveNode(node: node, context: ctx) {
///         TimelineView(.animation) { tl in
///             ClockFace(date: tl.date)
///         }
///     }
///     .frame(width: node.size.width, height: node.size.height)
///     .padding(inset)
///     .overlay { FlowNodeHandles(node: node, context: ctx) }
/// }
/// ```
///
/// Capture of the snapshot used by the Canvas rasterize path is
/// automatic for SwiftUI-only content (see ``LiveNodeCapture``). Native
/// views (`WKWebView` / `MKMapView` / `AVPlayerView`) must use
/// ``LiveNodeCapture/manual(capture:)`` and write `FlowNodeSnapshot`
/// values via `FlowStore.setNodeSnapshot(_:for:)` themselves.
public struct LiveNode<NodeData: Sendable & Hashable, Live: View, Placeholder: View>: View {

    private let node: FlowNode<NodeData>
    private let context: NodeRenderContext
    private let capture: LiveNodeCapture
    private let live: () -> Live
    private let placeholder: () -> Placeholder

    @Environment(\.flowNodeRenderPhase) private var phase
    @Environment(\.isFlowNodeActive) private var isActive
    @Environment(\.self) private var environment
    @Environment(\.displayScale) private var displayScale
    @Environment(\.flowLiveNodeSnapshotWriter) private var snapshotWriter
    @Environment(\.liveNodeActivationCoordinator) private var coordinator

    public init(
        node: FlowNode<NodeData>,
        context: NodeRenderContext,
        capture: LiveNodeCapture = .onDeactivation,
        @ViewBuilder live: @escaping () -> Live,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.node = node
        self.context = context
        self.capture = capture
        self.live = live
        self.placeholder = placeholder
    }

    public var body: some View {
        // Pure phase dispatch. No frame, padding, clip, or other styling
        // — the caller composes sizing and visual treatment outside.
        contentBody
    }

    @ViewBuilder
    private var contentBody: some View {
        switch phase {
        case .rasterize:
            rasterizeBody
        case .live:
            liveBody
        }
    }

    @ViewBuilder
    private var rasterizeBody: some View {
        if let snap = context.snapshot {
            Image(snap.cgImage, scale: snap.scale, label: Text(verbatim: ""))
                .resizable()
                .interpolation(.high)
        } else {
            placeholder()
                .onAppear {
                    if case .manual = capture { return }
                    captureNow()
                }
        }
    }

    /// The overlay keeps this subtree mounted across activation toggles
    /// so native views (WKWebView / MKMapView / AVPlayerView) don't
    /// reload. Capture on deactivation is routed through
    /// ``LiveNodeActivationCoordinator`` so the snapshot is written
    /// **before** the overlay fades and the Canvas repaints — otherwise
    /// the stale cached image flashes between deactivation and the
    /// async capture completing.
    @ViewBuilder
    private var liveBody: some View {
        let nodeID = node.id
        // Re-register on every inputs change so the handler closure
        // always sees the latest `node.size`, caller-provided manual
        // closure, etc. `SwiftUI.View` is a value type, so the closure
        // registered from a stale `self` would otherwise capture inputs
        // from the first mount only. The task id is cheap; registration
        // itself is idempotent (just a dictionary overwrite).
        live()
            .onAppear { seedSnapshotIfNeeded() }
            .onDisappear {
                coordinator?.unregisterCapture(for: nodeID)
            }
            .task(id: captureRegistrationIdentity) {
                registerCaptureHandler()
            }
            .modifier(PeriodicCaptureModifier(capture: capture, isActive: isActive, captureNow: captureNow, nodeID: nodeID))
    }

    /// Identity string that rebuilds the registration task whenever
    /// inputs the handler depends on change. `.manual` users that swap
    /// the capture closure across body evaluations should bump something
    /// observable on the outer view to trigger re-registration; in
    /// practice the stable tuple below covers SwiftUI-only and native
    /// representable call sites.
    private var captureRegistrationIdentity: String {
        let mode: String
        switch capture {
        case .onDeactivation: mode = "d"
        case .periodic(let i): mode = "p\(i)"
        case .manual: mode = "m"
        }
        return "\(node.id)|\(Int(node.size.width))x\(Int(node.size.height))|\(mode)"
    }

    /// Registers the mode-specific capture handler with the overlay
    /// coordinator. `onDeactivation` / `periodic` route through
    /// `captureNow()` (ImageRenderer); `.manual(capture:)` forwards the
    /// caller-supplied async closure.
    @MainActor
    private func registerCaptureHandler() {
        guard let coordinator else { return }
        let nodeID = node.id
        switch capture {
        case .onDeactivation, .periodic:
            coordinator.registerCapture(for: nodeID) {
                await captureNowAwaitable()
            }
        case .manual(let handler):
            coordinator.registerCapture(for: nodeID, handler: handler)
        }
    }

    /// `ImageRenderer` is synchronous, but exposing it as `async` keeps
    /// the coordinator's handler signature uniform and lets a future
    /// implementation swap in an off-thread rasterizer without touching
    /// the coordinator.
    @MainActor
    private func captureNowAwaitable() async {
        captureNow()
    }

    @MainActor
    private func seedSnapshotIfNeeded() {
        if case .manual = capture { return }
        guard context.snapshot == nil else { return }
        captureNow()
    }

    @MainActor
    private func captureNow() {
        guard let writer = snapshotWriter else { return }
        let scale = min(max(displayScale * 2, 2), 4)
        let renderer = ImageRenderer(
            content: live()
                .frame(width: node.size.width, height: node.size.height)
                .environment(\.self, environment)
        )
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return }
        writer(node.id, FlowNodeSnapshot(cgImage: cgImage, scale: scale))
    }
}

// MARK: - Periodic capture

/// Applies the periodic capture loop only when ``LiveNodeCapture/periodic``
/// is selected. Extracted into a modifier so `LiveNode.liveBody` stays
/// declarative and avoids a per-mode switch that would force every capture
/// mode to pay the `.task(id:)` rebuild cost.
private struct PeriodicCaptureModifier: ViewModifier {
    let capture: LiveNodeCapture
    let isActive: Bool
    let captureNow: @MainActor () -> Void
    let nodeID: String

    func body(content: Content) -> some View {
        switch capture {
        case .periodic(let interval):
            content.task(id: "\(nodeID)|active=\(isActive)") {
                guard isActive else { return }
                let nanos = UInt64(max(interval, 0.05) * 1_000_000_000)
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: nanos)
                    if Task.isCancelled { return }
                    await MainActor.run { captureNow() }
                }
            }
        case .onDeactivation, .manual:
            content
        }
    }
}

// MARK: - Default placeholder

/// Default placeholder used by `LiveNode` when the caller omits its own.
/// A muted rectangle that fades cleanly against most canvas backgrounds
/// while a snapshot is being produced.
public struct FlowDefaultPlaceholder: View {
    public init() {}
    public var body: some View {
        Rectangle().fill(Color.secondary.opacity(0.08))
    }
}

extension LiveNode where Placeholder == FlowDefaultPlaceholder {
    public init(
        node: FlowNode<NodeData>,
        context: NodeRenderContext,
        capture: LiveNodeCapture = .onDeactivation,
        @ViewBuilder live: @escaping () -> Live
    ) {
        self.init(
            node: node,
            context: context,
            capture: capture,
            live: live,
            placeholder: { FlowDefaultPlaceholder() }
        )
    }
}

// MARK: - Snapshot writer environment

private struct FlowLiveNodeSnapshotWriterKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String, FlowNodeSnapshot) -> Void)? = nil
}

extension EnvironmentValues {
    /// Closure injected by `FlowCanvas` that lets `LiveNode` deposit
    /// captured snapshots into the owning `FlowStore` without knowing the
    /// store's `Data` generic parameter.
    var flowLiveNodeSnapshotWriter: (@MainActor (String, FlowNodeSnapshot) -> Void)? {
        get { self[FlowLiveNodeSnapshotWriterKey.self] }
        set { self[FlowLiveNodeSnapshotWriterKey.self] = newValue }
    }
}
