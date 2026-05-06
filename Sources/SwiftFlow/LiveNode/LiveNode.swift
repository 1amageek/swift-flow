import SwiftUI

// MARK: - LiveNode

/// Declares a node whose body is rendered as a live SwiftUI view while
/// interactive, and as a rasterized snapshot while not interactive.
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
/// owns the underlying instance through `@State` and the wrapping
/// representable participates in the snapshot pipeline by reading
/// `\.liveNodeSnapshotContext` from the environment:
///
/// ```swift
/// @State private var webView = WKWebView()
///
/// LiveNode(node: node, mount: .persistent) {
///     WebRepresentable(webView: webView, url: url)
/// }
/// ```
///
/// Inside `WebRepresentable.makeUIView` / `makeNSView` the developer reads
/// `\.liveNodeSnapshotContext` and either registers a capture handler
/// (called during interaction end) or pushes a snapshot directly when an
/// internal event lands (navigation finish, tile render). See
/// ``LiveNodeSnapshotContext`` for details.
public struct LiveNode<Content: View, Placeholder: View>: View {

    private let explicitNode: LiveNodeDescriptor?
    private let configuration: LiveNodeConfiguration
    private let content: (LiveNodeContentContext) -> Content
    private let placeholder: () -> Placeholder

    @Environment(\.liveNodeEnvironment) private var liveNodeEnvironment

    public init<Data>(
        node: FlowNode<Data>,
        mount: LiveNodeMountPolicy = .onInteraction,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) where Data: Sendable & Hashable {
        self.explicitNode = LiveNodeDescriptor(node: node)
        self.configuration = LiveNodeConfiguration(mountPolicy: mount)
        self.content = { _ in content() }
        self.placeholder = placeholder
    }

    public init<Data>(
        node: FlowNode<Data>,
        mount: LiveNodeMountPolicy = .onInteraction,
        @ViewBuilder content: @escaping (LiveNodeContentContext) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) where Data: Sendable & Hashable {
        self.explicitNode = LiveNodeDescriptor(node: node)
        self.configuration = LiveNodeConfiguration(mountPolicy: mount)
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
        mount: LiveNodeMountPolicy = .onInteraction,
        @ViewBuilder content: @escaping () -> Content
    ) where Data: Sendable & Hashable {
        self.init(
            node: node,
            mount: mount,
            content: content,
            placeholder: { FlowDefaultPlaceholder() }
        )
    }

    public init<Data>(
        node: FlowNode<Data>,
        mount: LiveNodeMountPolicy = .onInteraction,
        @ViewBuilder content: @escaping (LiveNodeContentContext) -> Content
    ) where Data: Sendable & Hashable {
        self.init(
            node: node,
            mount: mount,
            content: content,
            placeholder: { FlowDefaultPlaceholder() }
        )
    }
}

// MARK: - Native Capture Registry

/// Per-`LiveNode` slot for the native capture handler installed by a
/// descendant representable through ``LiveNodeSnapshotContext``.
///
/// Reference type so registering / clearing the handler from within
/// `makeUIView` / `dismantleUIView` does not invalidate the surrounding
/// SwiftUI body — the registry is held by `@State` and only its single
/// property is mutated.
@MainActor
final class LiveNodeNativeCaptureRegistry {
    var handler: (@MainActor () async -> FlowNodeSnapshot?)?
}

// MARK: - Core

private struct LiveNodeCore<Content: View, Placeholder: View>: View {

    let environment: LiveNodeEnvironment
    let configuration: LiveNodeConfiguration
    let content: (LiveNodeContentContext) -> Content
    let placeholder: () -> Placeholder

    @Environment(\.flowNodeRenderPhase) private var phase
    @Environment(\.isFlowNodeInteractive) private var isInteractive
    @Environment(\.displayScale) private var displayScale
    @Environment(\.self) private var swiftUIEnvironment
    @Environment(\.flowLiveNodeSnapshotWriter) private var snapshotWriter
    @Environment(\.liveNodeInteractionCoordinator) private var coordinator
    @Environment(\.defersLiveNodeSnapshotWrites) private var defersSnapshotWrites

    @State private var nativeCapture = LiveNodeNativeCaptureRegistry()
    @State private var remountGeneration: Int = 0
    @State private var previousInteractiveState: Bool = false
    @State private var hasSeededInitialSnapshot: Bool = false
    private var contentContext: LiveNodeContentContext {
        LiveNodeContentContext(
            id: environment.id,
            size: environment.size,
            snapshot: environment.snapshot,
            isInteractive: isInteractive
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
            .environment(\.liveNodeSnapshotContext, makeSnapshotContext())
            .onAppear {
                previousInteractiveState = isInteractive
            }
            .onChange(of: isInteractive) { _, newValue in
                handleInteractiveStateChange(newValue)
            }
    }

    @ViewBuilder
    private var phaseBody: some View {
        switch phase {
        case .rasterize:
            RasterizedNodeBody(
                snapshot: environment.snapshot,
                placeholder: placeholder
            )

        case .live:
            LiveNodeLiveBody(
                snapshot: environment.snapshot,
                mountPolicy: configuration.mountPolicy,
                remountGeneration: remountGeneration,
                content: { content(contentContext) }
            )
            .task(id: environment.id) {
                registerInteractionEndCapture()
                await seedInitialSnapshotIfNeeded()
            }
            .onDisappear {
                unregisterInteractionEndCapture()
            }
        }
    }

    private func handleInteractiveStateChange(_ isNowInteractive: Bool) {
        defer { previousInteractiveState = isNowInteractive }

        LiveNodeDebugLog.log(
            "interactive.changed node=\(environment.id) previous=\(previousInteractiveState) next=\(isNowInteractive) mount=\(configuration.mountPolicy)"
        )

        guard isNowInteractive, previousInteractiveState == false else {
            return
        }

        if configuration.mountPolicy == .remountOnInteraction {
            remountGeneration += 1
            LiveNodeDebugLog.log("remount.generation node=\(environment.id) generation=\(remountGeneration)")
        }
    }

    @MainActor
    private func registerInteractionEndCapture() {
        coordinator?.registerCapture(for: environment.id) {
            await captureNow()
        }
    }

    @MainActor
    private func unregisterInteractionEndCapture() {
        coordinator?.unregisterCapture(for: environment.id)
    }

    @MainActor
    private func seedInitialSnapshotIfNeeded() async {
        guard configuration.mountPolicy == .onInteraction else { return }
        guard environment.snapshot == nil else { return }
        guard !hasSeededInitialSnapshot else { return }
        guard !defersSnapshotWrites else { return }
        hasSeededInitialSnapshot = true

        do {
            try await Task.sleep(nanoseconds: 16_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        guard environment.snapshot == nil else { return }

        LiveNodeDebugLog.log("initialSnapshot.seed node=\(environment.id)")
        await captureNow()
    }

    @MainActor
    private func captureNow() async {
        guard let snapshotWriter else { return }
        guard !Task.isCancelled else {
            LiveNodeDebugLog.log("captureNow.skipped node=\(environment.id) reason=cancelled-before")
            return
        }
        LiveNodeDebugLog.log("captureNow.started node=\(environment.id)")
        guard let snapshot = await produceSnapshot() else {
            LiveNodeDebugLog.log("captureNow.empty node=\(environment.id)")
            return
        }
        guard !Task.isCancelled else {
            LiveNodeDebugLog.log("captureNow.skipped node=\(environment.id) reason=cancelled-after-produce")
            return
        }
        LiveNodeDebugLog.log("captureNow.write node=\(environment.id)")
        snapshotWriter(environment.id, snapshot)
    }

    @MainActor
    private func produceSnapshot() async -> FlowNodeSnapshot? {
        if let nativeHandler = nativeCapture.handler {
            return await nativeHandler()
        }
        return captureWithImageRenderer()
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

    @MainActor
    private func makeSnapshotContext() -> LiveNodeSnapshotContext? {
        guard let snapshotWriter else { return nil }
        let nodeID = environment.id
        let registry = nativeCapture
        let allowsImmediateSnapshotWrites = !defersSnapshotWrites
        return LiveNodeSnapshotContext(
            nodeID: nodeID,
            write: { snapshot in
                LiveNodeDebugLog.log("snapshotWriter.direct node=\(nodeID)")
                snapshotWriter(nodeID, snapshot)
            },
            registerCapture: { handler in
                LiveNodeDebugLog.log("nativeCapture.register node=\(nodeID)")
                registry.handler = handler
            },
            unregisterCapture: {
                LiveNodeDebugLog.log("nativeCapture.unregister node=\(nodeID)")
                registry.handler = nil
            },
            allowsImmediateSnapshotWrites: {
                allowsImmediateSnapshotWrites
            },
            requestCapture: {
                guard let handler = registry.handler else { return }
                guard !Task.isCancelled else {
                    LiveNodeDebugLog.log("snapshot.requestCapture.cancelled node=\(nodeID) stage=before")
                    return
                }
                guard let snapshot = await handler() else {
                    LiveNodeDebugLog.log("snapshot.requestCapture.empty node=\(nodeID)")
                    return
                }
                guard !Task.isCancelled else {
                    LiveNodeDebugLog.log("snapshot.requestCapture.cancelled node=\(nodeID) stage=after")
                    return
                }
                LiveNodeDebugLog.log("snapshot.requestCapture.write node=\(nodeID)")
                snapshotWriter(nodeID, snapshot)
            }
        )
    }
}

// MARK: - Rasterized Body

private struct RasterizedNodeBody<Placeholder: View>: View {
    let snapshot: FlowNodeSnapshot?
    let placeholder: () -> Placeholder

    var body: some View {
        Group {
            if let snapshot {
                SnapshotImage(snapshot: snapshot)
            } else {
                placeholder()
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
        case .onInteraction, .remountOnInteraction:
            return true

        case .persistent:
            return false
        }
    }

    private var contentIdentity: String {
        switch mountPolicy {
        case .onInteraction, .persistent:
            return "stable"

        case .remountOnInteraction:
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
