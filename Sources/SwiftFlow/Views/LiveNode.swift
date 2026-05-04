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
/// LiveNode(node: node) {
///     MyChartView()
/// }
/// ```
///
/// For native views (`WKWebView`, `MKMapView`, `AVPlayerView`) the developer
/// owns the underlying instance through `@State` and supplies a
/// ``LiveNodeCapture/custom(_:)`` closure that produces a snapshot:
///
/// ```swift
/// @State private var webView = WKWebView()
///
/// LiveNode(
///     node: node,
///     mount: .persistent,
///     capture: .custom { await webView.makeFlowNodeSnapshot() }
/// ) {
///     WebRepresentable(webView: webView, url: url)
/// }
/// ```
public struct LiveNode<Content: View, Placeholder: View>: View {

    private let explicitNode: LiveNodeDescriptor?
    private let configuration: LiveNodeConfiguration
    private let content: (LiveNodeContentContext) -> Content
    private let placeholder: () -> Placeholder

    @Environment(\.liveNodeEnvironment) private var liveNodeEnvironment

    public init<Data>(
        node: FlowNode<Data>,
        mount: LiveNodeMountPolicy = .onActivation,
        snapshot: LiveNodeSnapshotPolicy = .automatic,
        capture: LiveNodeCapture = .auto,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) where Data: Sendable & Hashable {
        self.explicitNode = LiveNodeDescriptor(node: node)
        self.configuration = LiveNodeConfiguration(
            mountPolicy: mount,
            snapshotPolicy: snapshot,
            capture: capture
        )
        self.content = { _ in content() }
        self.placeholder = placeholder
    }

    public init<Data>(
        node: FlowNode<Data>,
        mount: LiveNodeMountPolicy = .onActivation,
        snapshot: LiveNodeSnapshotPolicy = .automatic,
        capture: LiveNodeCapture = .auto,
        @ViewBuilder content: @escaping (LiveNodeContentContext) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) where Data: Sendable & Hashable {
        self.explicitNode = LiveNodeDescriptor(node: node)
        self.configuration = LiveNodeConfiguration(
            mountPolicy: mount,
            snapshotPolicy: snapshot,
            capture: capture
        )
        self.content = content
        self.placeholder = placeholder
    }

    public var body: some View {
        if let resolved = resolvedEnvironment {
            LiveNodeCore(
                environment: resolved,
                configuration: configuration,
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
    public init<Data>(
        node: FlowNode<Data>,
        mount: LiveNodeMountPolicy = .onActivation,
        snapshot: LiveNodeSnapshotPolicy = .automatic,
        capture: LiveNodeCapture = .auto,
        @ViewBuilder content: @escaping () -> Content
    ) where Data: Sendable & Hashable {
        self.init(
            node: node,
            mount: mount,
            snapshot: snapshot,
            capture: capture,
            content: content,
            placeholder: { FlowDefaultPlaceholder() }
        )
    }

    public init<Data>(
        node: FlowNode<Data>,
        mount: LiveNodeMountPolicy = .onActivation,
        snapshot: LiveNodeSnapshotPolicy = .automatic,
        capture: LiveNodeCapture = .auto,
        @ViewBuilder content: @escaping (LiveNodeContentContext) -> Content
    ) where Data: Sendable & Hashable {
        self.init(
            node: node,
            mount: mount,
            snapshot: snapshot,
            capture: capture,
            content: content,
            placeholder: { FlowDefaultPlaceholder() }
        )
    }
}

// MARK: - Core

private struct LiveNodeCore<Content: View, Placeholder: View>: View {

    let environment: LiveNodeEnvironment
    let configuration: LiveNodeConfiguration
    let content: (LiveNodeContentContext) -> Content
    let placeholder: () -> Placeholder

    @Environment(\.flowNodeRenderPhase) private var phase
    @Environment(\.isFlowNodeActive) private var isActive
    @Environment(\.displayScale) private var displayScale
    @Environment(\.self) private var swiftUIEnvironment
    @Environment(\.flowLiveNodeSnapshotWriter) private var snapshotWriter
    @Environment(\.liveNodeActivationCoordinator) private var coordinator

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

        if configuration.snapshotPolicy.triggersOnActivation {
            Task { @MainActor in
                await captureNow()
            }
        }
    }

    @MainActor
    private func seedSnapshotIfNeeded() {
        guard environment.snapshot == nil else { return }
        guard configuration.snapshotPolicy.seedsOnAppear else { return }

        Task { @MainActor in
            await captureNow()
        }
    }

    @MainActor
    private func registerDeactivationCapture() {
        guard configuration.snapshotPolicy.triggersOnDeactivation else { return }

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
        guard let snapshotWriter else { return }

        switch configuration.capture {
        case .auto:
            guard let snapshot = captureWithImageRenderer() else { return }
            snapshotWriter(environment.id, snapshot)

        case let .custom(handler):
            guard let snapshot = await handler() else { return }
            snapshotWriter(environment.id, snapshot)

        case .disabled:
            return
        }
    }

    @MainActor
    private func captureWithImageRenderer() -> FlowNodeSnapshot? {
        let scale = captureScale

        let renderer = ImageRenderer(
            content:
                content(contentContext)
                .frame(width: environment.size.width, height: environment.size.height)
                .environment(\.self, swiftUIEnvironment)
        )
        renderer.scale = scale

        guard let cgImage = renderer.cgImage else {
            return nil
        }
        return FlowNodeSnapshot(cgImage: cgImage, scale: scale)
    }

    private var captureScale: CGFloat {
        min(max(displayScale * 2, 2), 4)
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
        guard let interval = snapshotPolicy.periodicInterval else { return }

        let nanos = UInt64(max(interval, 0.05) * 1_000_000_000)

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: nanos)
            } catch {
                return
            }

            if Task.isCancelled {
                return
            }

            await captureNow()
        }
    }
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
