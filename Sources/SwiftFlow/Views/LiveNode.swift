import SwiftUI

// MARK: - LiveNode

/// Declares a node whose body is rendered as a live SwiftUI view while
/// active, and as a rasterized snapshot while inactive.
///
/// `LiveNode` must be used inside a `FlowCanvas` `nodeContent` closure.
/// The canvas injects the surrounding node's identity, size, and snapshot
/// through the environment, so the call site stays small:
///
/// ```swift
/// LiveNode {
///     AnyKindView()
/// }
/// ```
///
/// Use the closure-with-context overload when the content needs to react
/// to the node's activation state:
///
/// ```swift
/// LiveNode { live in
///     MapNode(...)
///         .allowsHitTesting(live.isActive)
/// }
/// ```
///
/// By default, `LiveNode` assumes SwiftUI-only content:
///
/// ```swift
/// .liveNodeMount(.onActivation)
/// .liveNodeSnapshot(.automatic)
/// ```
///
/// Native views such as `WKWebView`, `MKMapView`, and `AVPlayerView`
/// should opt into native snapshot handling:
///
/// ```swift
/// LiveNode {
///     WebViewNode(url: url)
/// }
/// .liveNodeMount(.persistent)
/// .liveNodeSnapshot(.native)
/// ```
///
/// Native snapshot views can access `liveNodeNativeSnapshotContext` from
/// the environment to:
///
/// - write ready-driven snapshots, e.g. after `WKNavigationDelegate.didFinish`
/// - register a capture handler used when hover/activation ends
public struct LiveNode<Content: View, Placeholder: View>: View {

    private let explicitNode: LiveNodeDescriptor?
    private let content: (LiveNodeContentContext) -> Content
    private let placeholder: () -> Placeholder

    @Environment(\.liveNodeEnvironment) private var liveNodeEnvironment

    public init(
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.explicitNode = nil
        self.content = { _ in content() }
        self.placeholder = placeholder
    }

    public init(
        @ViewBuilder content: @escaping (LiveNodeContentContext) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.explicitNode = nil
        self.content = content
        self.placeholder = placeholder
    }

    public init<Data>(
        node: FlowNode<Data>,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) where Data: Sendable & Hashable {
        self.explicitNode = LiveNodeDescriptor(node: node)
        self.content = { _ in content() }
        self.placeholder = placeholder
    }

    public init<Data>(
        node: FlowNode<Data>,
        @ViewBuilder content: @escaping (LiveNodeContentContext) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) where Data: Sendable & Hashable {
        self.explicitNode = LiveNodeDescriptor(node: node)
        self.content = content
        self.placeholder = placeholder
    }

    public var body: some View {
        if let resolved = resolvedEnvironment {
            LiveNodeCore(
                environment: resolved,
                content: content,
                placeholder: placeholder
            )
        } else {
            placeholder()
        }
    }

    /// Merge precedence:
    ///
    /// 1. `LiveNode(node:)` overrides id and size.
    /// 2. The Canvas-injected `liveNodeEnvironment` supplies the
    ///    snapshot — and id / size when no explicit node is provided.
    /// 3. Without either source, the placeholder is rendered.
    private var resolvedEnvironment: LiveNodeEnvironment? {
        if let explicitNode {
            return LiveNodeEnvironment(
                id: explicitNode.id,
                size: explicitNode.size,
                snapshot: liveNodeEnvironment?.snapshot
            )
        }
        return liveNodeEnvironment
    }
}

extension LiveNode where Placeholder == FlowDefaultPlaceholder {
    public init(
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            content: content,
            placeholder: { FlowDefaultPlaceholder() }
        )
    }

    public init(
        @ViewBuilder content: @escaping (LiveNodeContentContext) -> Content
    ) {
        self.init(
            content: content,
            placeholder: { FlowDefaultPlaceholder() }
        )
    }

    public init<Data>(
        node: FlowNode<Data>,
        @ViewBuilder content: @escaping () -> Content
    ) where Data: Sendable & Hashable {
        self.init(
            node: node,
            content: content,
            placeholder: { FlowDefaultPlaceholder() }
        )
    }

    public init<Data>(
        node: FlowNode<Data>,
        @ViewBuilder content: @escaping (LiveNodeContentContext) -> Content
    ) where Data: Sendable & Hashable {
        self.init(
            node: node,
            content: content,
            placeholder: { FlowDefaultPlaceholder() }
        )
    }
}

// MARK: - Core

private struct LiveNodeCore<Content: View, Placeholder: View>: View {

    let environment: LiveNodeEnvironment
    let content: (LiveNodeContentContext) -> Content
    let placeholder: () -> Placeholder

    @Environment(\.flowNodeRenderPhase) private var phase
    @Environment(\.isFlowNodeActive) private var isActive
    @Environment(\.displayScale) private var displayScale
    @Environment(\.self) private var swiftUIEnvironment
    @Environment(\.liveNodeConfiguration) private var configuration
    @Environment(\.flowLiveNodeSnapshotWriter) private var snapshotWriter
    @Environment(\.liveNodeActivationCoordinator) private var coordinator

    @StateObject private var nativeCaptureRegistry = LiveNodeNativeCaptureRegistry()

    @State private var remountGeneration: Int = 0
    @State private var previousActiveState: Bool = false

    private var contentContext: LiveNodeContentContext {
        LiveNodeContentContext(
            id: environment.id,
            size: environment.size,
            snapshot: environment.snapshot,
            isActive: isActive
        )
    }

    var body: some View {
        phaseBody
            .frame(width: environment.size.width, height: environment.size.height)
            .preference(key: LiveNodePresenceKey.self, value: [environment.id])
            .preference(
                key: LiveNodeMountPolicyKey.self,
                value: [environment.id: configuration.mountPolicy]
            )
            .onAppear {
                previousActiveState = isActive
            }
            .onChange(of: isActive) { _, newValue in
                handleActiveStateChange(newValue)
            }
    }

    @ViewBuilder
    private var phaseBody: some View {
        switch phase {
        case .rasterize:
            RasterizedNodeBody(
                snapshot: environment.snapshot,
                placeholder: placeholder,
                seedSnapshotIfNeeded: seedSnapshotIfNeeded
            )

        case .live:
            LiveNodeLiveBody(
                snapshot: environment.snapshot,
                mountPolicy: configuration.mountPolicy,
                remountGeneration: remountGeneration,
                content: { content(contentContext) }
            )
            .environment(\.liveNodeNativeSnapshotContext, makeNativeSnapshotContext())
            .modifier(
                LiveNodeCaptureLifecycleModifier(
                    nodeID: environment.id,
                    nodeSize: environment.size,
                    snapshotPolicy: configuration.snapshotPolicy,
                    isActive: isActive,
                    registerDeactivationCapture: registerDeactivationCapture,
                    unregisterDeactivationCapture: unregisterDeactivationCapture,
                    captureNow: captureNow
                )
            )
            .onAppear {
                seedSnapshotIfNeeded()
            }
        }
    }

    private func handleActiveStateChange(_ isNowActive: Bool) {
        defer { previousActiveState = isNowActive }

        guard isNowActive, previousActiveState == false else {
            return
        }

        if configuration.mountPolicy == .remountOnActivation {
            remountGeneration += 1
        }

        if configuration.snapshotPolicy.triggers.onActivation {
            Task { @MainActor in
                await captureNow()
            }
        }
    }

    @MainActor
    private func seedSnapshotIfNeeded() {
        guard environment.snapshot == nil else { return }
        guard configuration.snapshotPolicy.triggers.seedOnAppear else { return }

        switch configuration.snapshotPolicy.source {
        case .swiftUI:
            Task { @MainActor in
                await captureNow()
            }

        case .native, .disabled:
            break
        }
    }

    @MainActor
    private func registerDeactivationCapture() {
        guard configuration.snapshotPolicy.triggers.onDeactivation else { return }
        guard configuration.snapshotPolicy.source != .disabled else { return }

        coordinator?.registerCapture(for: environment.id) {
            await captureNow()
        }
    }

    @MainActor
    private func unregisterDeactivationCapture() {
        coordinator?.unregisterCapture(for: environment.id)
    }

    @MainActor
    private func captureNow() async {
        switch configuration.snapshotPolicy.source {
        case .swiftUI:
            captureSwiftUIView()

        case .native:
            await captureNativeView()

        case .disabled:
            break
        }
    }

    @MainActor
    private func captureSwiftUIView() {
        guard let snapshotWriter else { return }

        let scale = captureScale

        let renderer = ImageRenderer(
            content:
                content(contentContext)
                .frame(width: environment.size.width, height: environment.size.height)
                .environment(\.self, swiftUIEnvironment)
        )

        renderer.scale = scale

        guard let cgImage = renderer.cgImage else {
            return
        }

        snapshotWriter(
            environment.id,
            FlowNodeSnapshot(
                cgImage: cgImage,
                scale: scale
            )
        )
    }

    @MainActor
    private func captureNativeView() async {
        guard let snapshotWriter else { return }
        guard let handler = nativeCaptureRegistry.captureHandler else { return }
        guard let snapshot = await handler() else { return }

        snapshotWriter(environment.id, snapshot)
    }

    private var captureScale: CGFloat {
        min(max(displayScale * 2, 2), 4)
    }

    @MainActor
    private func makeNativeSnapshotContext() -> LiveNodeNativeSnapshotContext {
        LiveNodeNativeSnapshotContext(
            nodeID: environment.id,
            write: { snapshot in
                // Ready-driven path. Only honored when the policy
                // explicitly opts into ready-driven writes — high-
                // frequency delegates can otherwise trigger a feedback
                // loop through the store re-render.
                guard configuration.snapshotPolicy.triggers.readyDriven else {
                    return
                }
                snapshotWriter?(environment.id, snapshot)
            },
            registerCapture: { handler in
                nativeCaptureRegistry.captureHandler = handler

                guard configuration.snapshotPolicy.triggers.onDeactivation else {
                    return
                }

                coordinator?.registerCapture(for: environment.id) {
                    guard let snapshot = await handler() else {
                        return
                    }

                    await MainActor.run {
                        snapshotWriter?(environment.id, snapshot)
                    }
                }
            },
            unregisterCapture: {
                // Only clear the native capture handler. Native views
                // can dismantle for non-deactivation reasons (e.g. a
                // `.id()`-driven remount, viewport churn), and tearing
                // down `renderedActive` from here cascades into the
                // coordinator and immediately deactivates the row that
                // just remounted. The LiveNode's own
                // `LiveNodeCaptureLifecycleModifier.onDisappear` is the
                // single owner of activation-coordinator teardown.
                nativeCaptureRegistry.captureHandler = nil
            },
            requestCapture: {
                // Manual path. Only honored when the policy enables it,
                // so a Representable wired up against an arbitrary policy
                // cannot accidentally drive the write pipeline.
                guard configuration.snapshotPolicy.triggers.manual else {
                    return
                }
                await captureNativeView()
            }
        )
    }
}

// MARK: - Rasterized Body

private struct RasterizedNodeBody<Placeholder: View>: View {
    let snapshot: FlowNodeSnapshot?
    let placeholder: () -> Placeholder
    let seedSnapshotIfNeeded: @MainActor () -> Void

    var body: some View {
        Group {
            if let snapshot {
                SnapshotImage(snapshot: snapshot)
            } else {
                placeholder()
                    .onAppear {
                        seedSnapshotIfNeeded()
                    }
            }
        }
    }
}

// MARK: - Live Body

private struct LiveNodeLiveBody<Content: View>: View {
    let snapshot: FlowNodeSnapshot?
    let mountPolicy: LiveNodeMountPolicy
    let remountGeneration: Int
    let content: () -> Content

    var body: some View {
        ZStack {
            if shouldDrawSnapshotBackdrop, let snapshot {
                SnapshotImage(snapshot: snapshot)
                    .allowsHitTesting(false)
            }

            content()
                .id(contentIdentity)
        }
    }

    private var shouldDrawSnapshotBackdrop: Bool {
        switch mountPolicy {
        case .onActivation, .remountOnActivation:
            return true

        case .persistent:
            return false
        }
    }

    private var contentIdentity: String {
        switch mountPolicy {
        case .onActivation, .persistent:
            return "stable"

        case .remountOnActivation:
            return "remount-\(remountGeneration)"
        }
    }
}

// MARK: - Snapshot Image

private struct SnapshotImage: View {
    let snapshot: FlowNodeSnapshot

    var body: some View {
        Image(snapshot.cgImage, scale: snapshot.scale, label: Text(verbatim: ""))
            .resizable()
            .interpolation(.high)
    }
}

// MARK: - Capture Lifecycle

private struct LiveNodeCaptureLifecycleModifier: ViewModifier {
    let nodeID: String
    let nodeSize: CGSize
    let snapshotPolicy: LiveNodeSnapshotPolicy
    let isActive: Bool

    let registerDeactivationCapture: @MainActor () -> Void
    let unregisterDeactivationCapture: @MainActor () -> Void
    let captureNow: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content
            .task(id: registrationIdentity) {
                registerDeactivationCapture()
            }
            .onDisappear {
                unregisterDeactivationCapture()
            }
            .task(id: periodicIdentity) {
                await runPeriodicCaptureLoopIfNeeded()
            }
    }

    private var registrationIdentity: String {
        [
            nodeID,
            "\(Int(nodeSize.width))x\(Int(nodeSize.height))",
            snapshotPolicy.registrationIdentity
        ].joined(separator: "|")
    }

    private var periodicIdentity: String {
        [
            nodeID,
            "\(Int(nodeSize.width))x\(Int(nodeSize.height))",
            snapshotPolicy.registrationIdentity,
            "active=\(isActive)"
        ].joined(separator: "|")
    }

    private func runPeriodicCaptureLoopIfNeeded() async {
        guard isActive else { return }
        guard let interval = snapshotPolicy.triggers.periodicInterval else { return }
        guard snapshotPolicy.source != .disabled else { return }

        let nanos = UInt64(max(interval, 0.05) * 1_000_000_000)

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: nanos)

            if Task.isCancelled {
                return
            }

            await captureNow()
        }
    }
}

// MARK: - Native Capture Registry

@MainActor
private final class LiveNodeNativeCaptureRegistry: ObservableObject {
    var captureHandler: (@MainActor () async -> FlowNodeSnapshot?)?
}

// MARK: - Snapshot Writer Environment

private struct FlowLiveNodeSnapshotWriterKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String, FlowNodeSnapshot) -> Void)? = nil
}

extension EnvironmentValues {
    /// Closure injected by `FlowCanvas` that lets `LiveNode` deposit
    /// captured snapshots into the owning store without knowing the
    /// store's generic type.
    var flowLiveNodeSnapshotWriter: (@MainActor (String, FlowNodeSnapshot) -> Void)? {
        get { self[FlowLiveNodeSnapshotWriterKey.self] }
        set { self[FlowLiveNodeSnapshotWriterKey.self] = newValue }
    }
}
