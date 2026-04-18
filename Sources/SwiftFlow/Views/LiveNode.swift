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
/// ``LiveNodeCapture/manual`` and write `FlowNodeSnapshot` values via
/// `FlowStore.setNodeSnapshot(_:for:)` themselves.
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
                    if capture != .manual {
                        captureNow()
                    }
                }
        }
    }

    @ViewBuilder
    private var liveBody: some View {
        switch capture {
        case .onDeactivation:
            // The overlay keeps this subtree mounted across activation
            // toggles so native views (WKWebView / MKMapView / AVPlayerView)
            // don't reload. `.onDisappear` therefore no longer fires on
            // deactivation — detect the true → false transition explicitly.
            //
            // Also seed a snapshot on first mount so the rasterize path
            // has something to draw before the user ever activates this
            // node. The overlay runs viewport culling, so `onAppear`
            // fires on initial Canvas display for visible nodes and on
            // scroll-in for nodes panned into view.
            live()
                .onAppear { seedSnapshotIfNeeded() }
                .onChange(of: isActive) { oldValue, newValue in
                    if oldValue && !newValue { captureNow() }
                }
        case .periodic(let interval):
            // Only run the capture loop while the overlay considers this
            // node active. The subtree stays mounted when inactive (to
            // preserve native-view identity) but there's no point burning
            // CPU re-rasterizing a view nobody is looking at; rejoin the
            // loop once activation flips back to true.
            live()
                .onAppear { seedSnapshotIfNeeded() }
                .task(id: "\(node.id)|active=\(isActive)") {
                    guard isActive else { return }
                    await runPeriodicCapture(interval: interval)
                }
        case .manual:
            // The app owns snapshot writes for native views the library
            // can't render off-screen (WKWebView / MKMapView / …). Mount
            // the live subtree as-is so its own lifecycle (representables
            // inside `.task`, etc.) can drive `store.setNodeSnapshot`.
            live()
        }
    }

    @MainActor
    private func seedSnapshotIfNeeded() {
        guard capture != .manual else { return }
        guard context.snapshot == nil else { return }
        captureNow()
    }

    private func runPeriodicCapture(interval: TimeInterval) async {
        let nanos = UInt64(max(interval, 0.05) * 1_000_000_000)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            captureNow()
        }
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
