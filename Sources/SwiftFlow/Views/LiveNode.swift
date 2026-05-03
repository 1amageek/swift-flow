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
    private let mountPolicy: LiveNodeMountPolicy
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
        mountPolicy: LiveNodeMountPolicy = .onActivation,
        @ViewBuilder live: @escaping () -> Live,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.node = node
        self.context = context
        self.capture = capture
        self.mountPolicy = mountPolicy
        self.live = live
        self.placeholder = placeholder
    }

    public var body: some View {
        // Pure phase dispatch. No frame, padding, clip, or other styling
        // — the caller composes sizing and visual treatment outside.
        //
        // Preferences are published from the outer body (not just the
        // live phase) so the Canvas's `symbols:` pass — which evaluates
        // every LiveNode in `.rasterize` once per render — also feeds
        // the coordinator's presence / policy maps. This is what closes
        // the bootstrap window: by the time `LiveNodeOverlay` decides
        // a row's mount policy, the policy preference has already been
        // delivered through the Canvas's render, so a `.persistent`
        // WKWebView never has to mount at opacity 0 on first appear
        // (which strands its WebContent compositor in a dormant state).
        contentBody
            .preference(key: LiveNodePresenceKey.self, value: [node.id])
            .preference(key: LiveNodeMountPolicyKey.self, value: [node.id: mountPolicy])
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
            // Placeholder covers two first-frame cases:
            //   1. Viewport-culled nodes that haven't been hosted by the
            //      overlay yet (their `liveBody.onAppear` hasn't fired).
            //   2. Nodes whose `.manual(capture:)` handler is still
            //      waiting on its native view to become snapshot-ready
            //      (e.g. WKWebView is still loading the first page).
            // Seed from here too; `seedSnapshotIfNeeded` guards on the
            // current snapshot so duplicate `onAppear` calls are no-ops.
            placeholder()
                .onAppear { seedSnapshotIfNeeded() }
        }
    }

    /// Mounted only while the coordinator marks the row rendered-active;
    /// deactivation unmounts the subtree so idle LiveNodes don't pay
    /// per-frame SwiftUI / transform / TimelineView costs during canvas
    /// pan and zoom.
    ///
    /// Capture on deactivation is routed through
    /// ``LiveNodeActivationCoordinator`` so the snapshot is written
    /// **before** `renderedActive` flips false — the Canvas `resolveSymbol`
    /// path then draws the fresh snapshot as the first visible frame
    /// after unmount, with no stale-thumbnail flash.
    ///
    /// ## Snapshot backdrop
    ///
    /// The overlay and Canvas hand off via `overlayIsDrawing` — Canvas
    /// stops drawing the rasterized snapshot exactly when the overlay
    /// becomes opaque. That handoff is sub-frame clean on the SwiftUI
    /// side, but compositor-backed surfaces (WKWebView / MKMapView /
    /// AVPlayer) need at least one display commit to publish their
    /// layer's backing store. For ``LiveNodeMountPolicy/onActivation``
    /// rows we paint the stored snapshot behind the live view to fill
    /// that one-frame gap — when Canvas stops drawing, the overlay
    /// already has an identical still frame under the live content,
    /// so there is nothing to flicker. Opaque live content (WKWebView,
    /// MKMapView, most TimelineView scenes) fully covers the backdrop
    /// once composited.
    ///
    /// ``LiveNodeMountPolicy/persistent`` rows skip the backdrop
    /// entirely — Canvas always skips drawing for them, so no handoff
    /// happens to begin with. More importantly, **adding** the Image
    /// to the ZStack the first time `context.snapshot` becomes non-nil
    /// (typically a few seconds after mount, when a `.manual` capture
    /// handler finally writes its first snapshot) causes SwiftUI to
    /// reassign the structural identity of `live()` at the next
    /// position. For pure-SwiftUI content that's invisible, but for an
    /// `NSViewRepresentable` / `UIViewRepresentable` it triggers a
    /// fresh `makeNSView` which detaches and reattaches the underlying
    /// `WKWebView` — within the same window, so
    /// `viewDidMoveToWindow` never fires and the WebContent process's
    /// compositor wake is missed. The visible result is that the web
    /// view goes solid black several seconds into the session, exactly
    /// when the snapshot capture lands.
    @ViewBuilder
    private var liveBody: some View {
        let nodeID = node.id
        ZStack {
            if let snap = context.snapshot {
                Image(snap.cgImage, scale: snap.scale, label: Text(verbatim: ""))
                    .resizable()
                    .interpolation(.high)
                    .allowsHitTesting(false)
            }
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

    /// Ensures the rasterize path has something to draw before the user
    /// ever activates the node — without it, the first frame after mount
    /// shows the placeholder until a full hover → unhover cycle completes.
    ///
    /// - `.onDeactivation` / `.periodic`: synchronous `ImageRenderer`
    ///   produces a thumbnail immediately.
    /// - `.manual(capture:)`: the library cannot know when the caller's
    ///   native view (WKWebView, MKMapView, AVPlayerView, …) is ready
    ///   to produce a meaningful frame — calling the handler on mount
    ///   would capture an unloaded / blank surface and pollute the
    ///   snapshot cache. The caller signals readiness themselves (e.g.
    ///   `WKNavigationDelegate.didFinish`, `MKMapViewDelegate.mapViewDidFinishRenderingMap`,
    ///   `AVPlayer` status KVO) and invokes capture from there.
    @MainActor
    private func seedSnapshotIfNeeded() {
        guard context.snapshot == nil else { return }
        switch capture {
        case .onDeactivation, .periodic:
            captureNow()
        case .manual:
            break
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

// MARK: - Presence preference

/// Collects the IDs of nodes whose `nodeContent` actually contains a
/// `LiveNode` in the live phase. `LiveNodeOverlay` reads this to decide,
/// per-row, whether to pay the hit-testing cost of the hosting layer —
/// plain (non-live) nodes leave their row at opacity 0 with hit testing
/// disabled so Canvas-level drag / selection gestures pass straight
/// through.
public struct LiveNodePresenceKey: PreferenceKey {
    public static let defaultValue: Set<String> = []
    public static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) {
        value.formUnion(nextValue())
    }
}

// MARK: - Mount policy preference

/// Aggregates the per-node mount policy that ``LiveNode`` declares for
/// itself, so `LiveNodeOverlay` can decide whether each row mounts on
/// activation only or stays mounted for the life of its viewport
/// presence. Last-write-wins on the rare merge — a node ID emitting
/// from two LiveNodes would already be a programmer error caught by
/// the deduplicated `LiveNodePresenceKey`.
public struct LiveNodeMountPolicyKey: PreferenceKey {
    public static let defaultValue: [String: LiveNodeMountPolicy] = [:]
    public static func reduce(
        value: inout [String: LiveNodeMountPolicy],
        nextValue: () -> [String: LiveNodeMountPolicy]
    ) {
        value.merge(nextValue()) { _, new in new }
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
