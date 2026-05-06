#if DEBUG && (os(iOS) || os(macOS))
import Foundation
import SwiftUI
import MapKit
import CoreLocation

// MARK: - State Store

/// Per-node region cache for ``LiveMapNode``.
///
/// `LiveMapNode` keeps the underlying `MKMapView` mounted with
/// ``LiveNodeMountPolicy/persistent`` so MapKit's native renderer keeps
/// its identity across interaction changes. This observable store keeps
/// the last-seen region per node ID as a fallback for actual view
/// teardown, such as Preview reloads or sample app window recreation.
@MainActor
@Observable
final class LiveMapNodeStateStore {

    var regions: [String: MKCoordinateRegion] = [:]
    var mapViewIDs: [String: String] = [:]
    var makeCounts: [String: Int] = [:]
    var dismantleCounts: [String: Int] = [:]

    init() {}

    func recordMake(nodeID: String, mapView: MKMapView) {
        mapViewIDs[nodeID] = Self.mapID(for: mapView)
        makeCounts[nodeID, default: 0] += 1
    }

    func recordDismantle(nodeID: String, mapView: MKMapView) {
        mapViewIDs[nodeID] = Self.mapID(for: mapView)
        dismantleCounts[nodeID, default: 0] += 1
    }

    func diagnostics(for nodeID: String) -> LiveMapNodeDiagnostics {
        LiveMapNodeDiagnostics(
            nodeID: nodeID,
            mapID: mapViewIDs[nodeID] ?? "none",
            makeCount: makeCounts[nodeID, default: 0],
            dismantleCount: dismantleCounts[nodeID, default: 0]
        )
    }

    private static func mapID(for mapView: MKMapView) -> String {
        guard let liveMapView = mapView as? LiveMapNodeMapView else {
            return "unknown"
        }
        return String(liveMapView.debugID.prefix(8))
    }
}

struct LiveMapNodeDiagnostics: Sendable, Hashable {
    let nodeID: String
    let mapID: String
    let makeCount: Int
    let dismantleCount: Int
}

// MARK: - Public View

/// Drop-in `LiveNode` wrapper around `MKMapView`.
///
/// Hides the bookkeeping required to make a native MapView cooperate
/// with the Poster pattern:
///
/// - Mount policy is ``LiveNodeMountPolicy/persistent``: MapKit's native
///   renderer stays mounted across interaction changes, while the Canvas
///   still draws the poster when the node is idle.
/// - ``LiveMapRepresentable`` reads `\.liveNodeSnapshotContext` and uses
///   it to register an interaction-end capture handler from `makeUIView` /
///   `makeNSView`. The handler captures the live `MKMapView` weakly and
///   runs while the row is still mounted, so the coordinator's
///   interaction-end pipeline writes a fresh snapshot before the overlay
///   fades.
/// - The coordinator additionally pushes a one-shot bootstrap snapshot
///   after MapKit reports a fully rendered pass, with a delayed fallback
///   after the first interaction kick so the poster is non-empty before
///   the user hovers out for the first time.
/// - Region persistence is read/write through the user-supplied
///   ``LiveMapNodeStateStore`` so pan/zoom survives real teardown.
/// - Tile pipeline kick: window-attach callback + non-zero bounds polling
///   so the map renders without requiring the user to interact first.
struct LiveMapNode<Data>: View where Data: Sendable & Hashable {

    private let node: FlowNode<Data>
    private let initialCoordinate: CLLocationCoordinate2D
    private let stateStore: LiveMapNodeStateStore
    private let cornerRadius: CGFloat

    init(
        node: FlowNode<Data>,
        initialCoordinate: CLLocationCoordinate2D,
        stateStore: LiveMapNodeStateStore,
        cornerRadius: CGFloat = 0
    ) {
        self.node = node
        self.initialCoordinate = initialCoordinate
        self.stateStore = stateStore
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        LiveNode(node: node, mount: .persistent) {
            LiveMapRepresentable(
                nodeID: node.id,
                initialCoordinate: initialCoordinate,
                cornerRadius: cornerRadius,
                stateStore: stateStore
            )
        } placeholder: {
            Color.clear
        }
    }
}

// MARK: - MKMapView subclass

/// `MKMapView` subclass that fires a hook every time the view is attached
/// to a window. Polling for non-zero bounds is brittle (the polling task
/// can race with platform layout and exhaust before the view is in the
/// hierarchy); the window-attach callback is the deterministic signal
/// that AppKit/UIKit has placed the view and is about to lay it out.
final class LiveMapNodeMapView: MKMapView {

    var onWindowAttach: (@MainActor (LiveMapNodeMapView) -> Void)?
    var debugNodeID = "unknown"

    let debugID = UUID().uuidString
    let debugCreatedUptime = ProcessInfo.processInfo.systemUptime

    private var lastLifecycleSignature: String?

    var debugIdentity: String {
        let age = ProcessInfo.processInfo.systemUptime - debugCreatedUptime
        return "mapID=\(String(debugID.prefix(8))) age=\(String(format: "%.3fs", age))"
    }

    #if os(macOS)
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        debugLogLifecycle("viewWillMoveToWindow", pendingWindow: newWindow != nil, force: true)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        debugLogLifecycle("viewDidMoveToWindow", force: true)
        guard window != nil else {
            return
        }
        let attach = onWindowAttach
        Task { @MainActor in
            attach?(self)
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        debugLogLifecycle("viewDidMoveToSuperview", force: true)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        debugLogLifecycle("setFrameSize", force: false)
    }
    #else
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        debugLogLifecycle("willMoveToWindow", pendingWindow: newWindow != nil, force: true)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        debugLogLifecycle("didMoveToWindow", force: true)
        guard window != nil else {
            return
        }
        let attach = onWindowAttach
        Task { @MainActor in
            attach?(self)
        }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        debugLogLifecycle("didMoveToSuperview", force: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        debugLogLifecycle("layoutSubviews", force: false)
    }
    #endif

    private func debugLogLifecycle(
        _ event: String,
        pendingWindow: Bool? = nil,
        force: Bool
    ) {
        let currentWindow = window != nil
        let signature = "\(bounds.size)|\(frame)|\(currentWindow)|\(superview != nil)|\(isHidden)|\(debugLayerDescription)"
        guard force || signature != lastLifecycleSignature else { return }
        lastLifecycleSignature = signature
        let pendingWindowDescription = pendingWindow.map { String(describing: $0) } ?? "nil"
        LiveNodeDebugLog.log(
            "map.viewLifecycle node=\(debugNodeID) event=\(event) \(debugIdentity) bounds=\(bounds.size) frame=\(frame) window=\(currentWindow) pendingWindow=\(pendingWindowDescription) superview=\(superview != nil) \(debugViewDescription) \(debugLayerDescription)"
        )
    }

    private var debugViewDescription: String {
        #if os(macOS)
        return "hidden=\(isHidden) alpha=\(alphaValue) wantsLayer=\(wantsLayer)"
        #else
        return "hidden=\(isHidden) alpha=\(alpha) opaque=\(isOpaque)"
        #endif
    }

    private var debugLayerDescription: String {
        #if os(macOS)
        let currentLayer = layer
        return "layerExists=\(currentLayer != nil) layerHidden=\(currentLayer?.isHidden ?? false) layerOpacity=\(currentLayer?.opacity ?? -1) masks=\(currentLayer?.masksToBounds ?? false) corner=\(currentLayer?.cornerRadius ?? -1)"
        #else
        let currentLayer = layer
        return "layerHidden=\(currentLayer.isHidden) layerOpacity=\(currentLayer.opacity) masks=\(currentLayer.masksToBounds) corner=\(currentLayer.cornerRadius)"
        #endif
    }
}

// MARK: - Coordinator

@MainActor
final class LiveMapNodeCoordinator: NSObject, MKMapViewDelegate {

    let nodeID: String
    let stateStore: LiveMapNodeStateStore
    private let initialRegion: MKCoordinateRegion

    /// Snapshot channel injected by ``LiveMapRepresentable`` from
    /// `\.liveNodeSnapshotContext`. The coordinator uses it to push a
    /// bootstrap snapshot after MapKit reports a fully rendered pass, with
    /// a delayed fallback after the interaction kick so the poster has a
    /// real frame before the user hovers out for the first time.
    var snapshotContext: LiveNodeSnapshotContext?

    /// Only flipped to `true` after a real-size `setRegion` has actually
    /// landed. Flipping it earlier would consume the interaction edge on a
    /// still-zero-bounds view and leave MapKit's tile pipeline dormant
    /// forever — `updateInteractionState` would never see another false→true.
    private var wasInteractive = false

    private var interactionKickTask: Task<Void, Never>?

    /// One-shot delayed task that pushes the first real snapshot once the
    /// interaction kick has actually rendered tiles.
    private var initialCaptureTask: Task<Void, Never>?
    private var diagnosticProbeTask: Task<Void, Never>?
    private var hasRequestedInitialCapture = false
    private var allowsRegionPersistence = false

    init(
        nodeID: String,
        initialRegion: MKCoordinateRegion,
        stateStore: LiveMapNodeStateStore
    ) {
        self.nodeID = nodeID
        self.initialRegion = initialRegion
        self.stateStore = stateStore
    }

    func updateInteractionState(_ isInteractive: Bool, mapView: MKMapView) {
        LiveNodeDebugLog.log(
            "map.interactive.update node=\(nodeID) \(Self.mapIdentity(for: mapView)) value=\(isInteractive) wasInteractive=\(wasInteractive) bounds=\(mapView.bounds.size)"
        )
        logMapState("interactive.update", mapView: mapView)
        if !isInteractive {
            LiveNodeDebugLog.log("map.interactive.end node=\(nodeID)")
            wasInteractive = false
            interactionKickTask?.cancel()
            interactionKickTask = nil
            initialCaptureTask?.cancel()
            initialCaptureTask = nil
            diagnosticProbeTask?.cancel()
            diagnosticProbeTask = nil
            return
        }

        guard !wasInteractive else { return }
        guard interactionKickTask == nil else { return }
        LiveNodeDebugLog.log("map.interactive.start node=\(nodeID)")
        scheduleInteractionKick(for: mapView)
    }

    /// Forces the map's tile pipeline to wake. Driven by either the
    /// window-attach callback on `LiveMapNodeMapView` or by
    /// `updateInteractionState` for representables that race ahead of the
    /// window attach. Idempotent via `wasInteractive`.
    func kickIfReady(_ mapView: MKMapView) {
        LiveNodeDebugLog.log(
            "map.kickIfReady node=\(nodeID) \(Self.mapIdentity(for: mapView)) wasInteractive=\(wasInteractive) hasWindow=\(mapView.window != nil) bounds=\(mapView.bounds.size)"
        )
        logMapState("kickIfReady", mapView: mapView)
        guard !wasInteractive else { return }
        guard mapView.window != nil else { return }
        if interactionKickTask == nil {
            scheduleInteractionKick(for: mapView)
        }
    }

    func tearDown() {
        LiveNodeDebugLog.log("map.tearDown node=\(nodeID)")
        interactionKickTask?.cancel()
        interactionKickTask = nil
        initialCaptureTask?.cancel()
        initialCaptureTask = nil
        diagnosticProbeTask?.cancel()
        diagnosticProbeTask = nil
        hasRequestedInitialCapture = false
        wasInteractive = false
        snapshotContext?.unregisterCapture()
    }

    private func scheduleInteractionKick(for mapView: MKMapView) {
        let regionSource = stateStore.regions[nodeID].map { ("cached", $0) } ?? ("initial", initialRegion)
        let region = regionSource.1
        LiveNodeDebugLog.log("map.kick.schedule node=\(nodeID) \(Self.mapIdentity(for: mapView)) bounds=\(mapView.bounds.size) pollInterval=16ms maxPolls=60")
        LiveNodeDebugLog.log("map.kick.regionSource node=\(nodeID) source=\(regionSource.0)")
        logRegion("kick.schedule.region", region: region)
        logMapState("kick.schedule", mapView: mapView)

        interactionKickTask = Task { @MainActor [weak self, weak mapView] in
            for _ in 0..<60 {
                if Task.isCancelled { return }
                guard let view = mapView else { return }

                if view.bounds.width > 1, view.bounds.height > 1 {
                    LiveNodeDebugLog.log("map.kick.applyRegion node=\(self?.nodeID ?? "unknown") \(Self.mapIdentity(for: view)) bounds=\(view.bounds.size)")
                    self?.logMapState("kick.beforeApplyRegion", mapView: view)
                    self?.allowsRegionPersistence = true
                    Self.applyRegion(region, on: view)
                    self?.logMapState("kick.afterFirstApplyRegion", mapView: view)

                    do {
                        try await Task.sleep(nanoseconds: 16_000_000)
                    } catch {
                        return
                    }
                    if Task.isCancelled { return }

                    guard let view = mapView else { return }
                    Self.applyRegion(region, on: view)
                    self?.logMapState("kick.afterSecondApplyRegion", mapView: view)

                    self?.wasInteractive = true
                    self?.interactionKickTask = nil
                    LiveNodeDebugLog.log("map.kick.complete node=\(self?.nodeID ?? "unknown") \(Self.mapIdentity(for: view))")
                    self?.scheduleDiagnosticProbes(for: view, reason: "kick.complete")
                    self?.scheduleInitialCaptureFallback(for: view)
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: 16_000_000)
                } catch {
                    return
                }
            }

            self?.interactionKickTask = nil
            LiveNodeDebugLog.log("map.kick.timeout node=\(self?.nodeID ?? "unknown")")
        }
    }

    func persistRegionIfUsable(from mapView: MKMapView, reason: String) {
        guard allowsRegionPersistence else {
            LiveNodeDebugLog.log("map.region.storeSkipped node=\(nodeID) reason=\(reason).notReady")
            return
        }
        guard mapView.window != nil, mapView.bounds.width > 1, mapView.bounds.height > 1 else {
            LiveNodeDebugLog.log("map.region.storeSkipped node=\(nodeID) reason=\(reason).invalidLayout bounds=\(mapView.bounds.size) window=\(mapView.window != nil)")
            return
        }
        let region = mapView.region
        stateStore.regions[nodeID] = region
        LiveNodeDebugLog.log("map.region.stored node=\(nodeID) reason=\(reason)")
        logRegion("stored.\(reason)", region: region)
    }

    private func requestInitialCaptureAfterRender(for mapView: MKMapView) {
        guard !hasRequestedInitialCapture else { return }
        guard snapshotContext != nil else { return }

        hasRequestedInitialCapture = true
        initialCaptureTask?.cancel()
        LiveNodeDebugLog.log("map.initialCapture.schedule node=\(nodeID) \(Self.mapIdentity(for: mapView)) reason=didFinishRendering delay=100ms")

        initialCaptureTask = Task { @MainActor [weak self, weak mapView] in
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self, let mapView else { return }
            self.logMapState("initialCapture.beforeSnapshot", mapView: mapView)
            guard let snapshot = await mapView.makeLiveMapNodeSnapshot() else {
                LiveNodeDebugLog.log("map.initialCapture.empty node=\(self.nodeID)")
                return
            }
            LiveNodeDebugLog.log("map.initialCapture.write node=\(self.nodeID)")
            self.snapshotContext?.write(snapshot)
            self.initialCaptureTask = nil
        }
    }

    private func scheduleInitialCaptureFallback(for mapView: MKMapView) {
        guard !hasRequestedInitialCapture else { return }
        guard snapshotContext != nil else { return }
        guard initialCaptureTask == nil else { return }

        LiveNodeDebugLog.log("map.initialCapture.schedule node=\(nodeID) \(Self.mapIdentity(for: mapView)) reason=kickFallback delay=1500ms")

        initialCaptureTask = Task { @MainActor [weak self, weak mapView] in
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self, let mapView else { return }
            self.requestInitialCaptureAfterRender(for: mapView)
        }
    }

    private static func applyRegion(_ region: MKCoordinateRegion, on mapView: MKMapView) {
        mapView.setRegion(region, animated: false)
    }

    private func scheduleDiagnosticProbes(for mapView: MKMapView, reason: String) {
        diagnosticProbeTask?.cancel()
        LiveNodeDebugLog.log(
            "map.probe.schedule node=\(nodeID) \(Self.mapIdentity(for: mapView)) reason=\(reason) cumulativeDelays=250ms,1000ms,2500ms,5500ms,10500ms"
        )
        diagnosticProbeTask = Task { @MainActor [weak self, weak mapView] in
            let delays: [UInt64] = [
                250_000_000,
                750_000_000,
                1_500_000_000,
                3_000_000_000,
                5_000_000_000
            ]

            for delay in delays {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let self, let mapView else { return }
                LiveNodeDebugLog.log("map.probe.fire node=\(self.nodeID) \(Self.mapIdentity(for: mapView)) reason=\(reason) slept=\(delay / 1_000_000)ms")
                self.logMapState("probe.\(reason).\(delay / 1_000_000)ms", mapView: mapView)
            }
        }
    }

    func logMapState(_ event: String, mapView: MKMapView) {
        let region = mapView.region
        let camera = mapView.camera
        let layerDescription = Self.layerDescription(for: mapView)
        let viewDescription = Self.viewDescription(for: mapView)
        LiveNodeDebugLog.log(
            "map.state node=\(nodeID) event=\(event) \(Self.mapIdentity(for: mapView)) bounds=\(mapView.bounds.size) frame=\(mapView.frame) window=\(mapView.window != nil) \(viewDescription) \(layerDescription) regionCenter=(\(region.center.latitude), \(region.center.longitude)) span=(\(region.span.latitudeDelta), \(region.span.longitudeDelta)) cameraCenter=(\(camera.centerCoordinate.latitude), \(camera.centerCoordinate.longitude)) altitude=\(camera.altitude) pitch=\(camera.pitch) heading=\(camera.heading)"
        )
    }

    private func logRegion(_ event: String, region: MKCoordinateRegion) {
        LiveNodeDebugLog.log(
            "map.region node=\(nodeID) event=\(event) center=(\(region.center.latitude), \(region.center.longitude)) span=(\(region.span.latitudeDelta), \(region.span.longitudeDelta))"
        )
    }

    private static func layerDescription(for mapView: MKMapView) -> String {
        #if os(macOS)
        let layer = mapView.layer
        return "layerExists=\(layer != nil) layerHidden=\(layer?.isHidden ?? false) layerOpacity=\(layer?.opacity ?? -1) masks=\(layer?.masksToBounds ?? false) corner=\(layer?.cornerRadius ?? -1)"
        #else
        let layer = mapView.layer
        return "layerHidden=\(layer.isHidden) layerOpacity=\(layer.opacity) masks=\(layer.masksToBounds) corner=\(layer.cornerRadius)"
        #endif
    }

    private static func viewDescription(for mapView: MKMapView) -> String {
        #if os(macOS)
        return "hidden=\(mapView.isHidden) alpha=\(mapView.alphaValue) wantsLayer=\(mapView.wantsLayer) superview=\(mapView.superview != nil)"
        #else
        return "hidden=\(mapView.isHidden) alpha=\(mapView.alpha) opaque=\(mapView.isOpaque) superview=\(mapView.superview != nil)"
        #endif
    }

    private static func mapIdentity(for mapView: MKMapView) -> String {
        guard let liveMapView = mapView as? LiveMapNodeMapView else {
            return "mapID=unknown age=unknown"
        }
        return liveMapView.debugIdentity
    }

    nonisolated func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        Task { @MainActor [weak self, weak mapView] in
            guard let self, let mapView else { return }
            LiveNodeDebugLog.log("map.regionDidChange node=\(self.nodeID) \(Self.mapIdentity(for: mapView)) animated=\(animated)")
            self.logMapState("regionDidChange", mapView: mapView)
            self.persistRegionIfUsable(from: mapView, reason: "regionDidChange")
        }
    }

    nonisolated func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        Task { @MainActor [weak self, weak mapView] in
            guard let self, let mapView else { return }
            LiveNodeDebugLog.log("map.regionWillChange node=\(self.nodeID) \(Self.mapIdentity(for: mapView)) animated=\(animated)")
            self.logMapState("regionWillChange", mapView: mapView)
        }
    }

    nonisolated func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        Task { @MainActor [weak self, weak mapView] in
            guard let self, let mapView else { return }
            LiveNodeDebugLog.log("map.visibleRegionDidChange node=\(self.nodeID) \(Self.mapIdentity(for: mapView))")
            self.logMapState("visibleRegionDidChange", mapView: mapView)
        }
    }

    nonisolated func mapViewWillStartLoadingMap(_ mapView: MKMapView) {
        Task { @MainActor [weak self, weak mapView] in
            guard let self, let mapView else { return }
            LiveNodeDebugLog.log("map.willStartLoading node=\(self.nodeID) \(Self.mapIdentity(for: mapView))")
            self.logMapState("willStartLoading", mapView: mapView)
        }
    }

    nonisolated func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
        Task { @MainActor [weak self, weak mapView] in
            guard let self, let mapView else { return }
            LiveNodeDebugLog.log("map.didFinishLoading node=\(self.nodeID) \(Self.mapIdentity(for: mapView))")
            self.logMapState("didFinishLoading", mapView: mapView)
        }
    }

    nonisolated func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
        Task { @MainActor [weak self, weak mapView] in
            guard let self, let mapView else { return }
            LiveNodeDebugLog.log("map.didFailLoading node=\(self.nodeID) \(Self.mapIdentity(for: mapView)) error=\(error)")
            self.logMapState("didFailLoading", mapView: mapView)
        }
    }

    nonisolated func mapViewWillStartRenderingMap(_ mapView: MKMapView) {
        Task { @MainActor [weak self, weak mapView] in
            guard let self, let mapView else { return }
            LiveNodeDebugLog.log("map.willStartRendering node=\(self.nodeID) \(Self.mapIdentity(for: mapView))")
            self.logMapState("willStartRendering", mapView: mapView)
        }
    }

    nonisolated func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        Task { @MainActor [weak self, weak mapView] in
            guard let self, let mapView else { return }
            LiveNodeDebugLog.log("map.didFinishRendering node=\(self.nodeID) \(Self.mapIdentity(for: mapView)) fullyRendered=\(fullyRendered)")
            self.logMapState("didFinishRendering", mapView: mapView)
            guard fullyRendered else { return }
            self.requestInitialCaptureAfterRender(for: mapView)
        }
    }
}

// MARK: - Representable

#if os(iOS)
struct LiveMapRepresentable: UIViewRepresentable {

    @Environment(\.isFlowNodeInteractive) private var isInteractive
    @Environment(\.liveNodeSnapshotContext) private var snapshotContext

    let nodeID: String
    let initialCoordinate: CLLocationCoordinate2D
    let cornerRadius: CGFloat
    let stateStore: LiveMapNodeStateStore

    func makeCoordinator() -> LiveMapNodeCoordinator {
        LiveMapNodeCoordinator(
            nodeID: nodeID,
            initialRegion: defaultRegion,
            stateStore: stateStore
        )
    }

    func makeUIView(context: Context) -> MKMapView {
        let coordinator = context.coordinator
        coordinator.snapshotContext = snapshotContext

        let mapView = LiveMapNodeMapView()
        mapView.debugNodeID = nodeID
        stateStore.recordMake(nodeID: nodeID, mapView: mapView)
        mapView.delegate = coordinator
        mapView.layer.cornerRadius = cornerRadius
        mapView.layer.masksToBounds = true
        mapView.setRegion(initialRegion, animated: false)
        coordinator.logMapState("makeUIView.afterSetup", mapView: mapView)

        mapView.onWindowAttach = { [weak coordinator] view in
            coordinator?.logMapState("windowAttach", mapView: view)
            coordinator?.kickIfReady(view)
        }

        // Register the interaction-end capture handler with the surrounding
        // LiveNode. The handler captures `mapView` weakly, so it always
        // reads from the current native view if SwiftUI recreates the
        // representable for unrelated tree changes.
        snapshotContext?.registerCapture { [weak mapView] in
            guard let mapView else { return nil }
            return await mapView.makeLiveMapNodeSnapshot()
        }

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.snapshotContext = snapshotContext
        mapView.layer.cornerRadius = cornerRadius
        coordinator.logMapState("updateUIView.beforeInteraction", mapView: mapView)
        coordinator.updateInteractionState(isInteractive, mapView: mapView)
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: LiveMapNodeCoordinator) {
        coordinator.stateStore.recordDismantle(nodeID: coordinator.nodeID, mapView: mapView)
        coordinator.persistRegionIfUsable(from: mapView, reason: "dismantle")
        coordinator.tearDown()
        (mapView as? LiveMapNodeMapView)?.onWindowAttach = nil
        mapView.delegate = nil
    }

    private var initialRegion: MKCoordinateRegion {
        stateStore.regions[nodeID] ?? defaultRegion
    }

    private var defaultRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: initialCoordinate,
            latitudinalMeters: 3000,
            longitudinalMeters: 3000
        )
    }
}
#elseif os(macOS)
struct LiveMapRepresentable: NSViewRepresentable {

    @Environment(\.isFlowNodeInteractive) private var isInteractive
    @Environment(\.liveNodeSnapshotContext) private var snapshotContext

    let nodeID: String
    let initialCoordinate: CLLocationCoordinate2D
    let cornerRadius: CGFloat
    let stateStore: LiveMapNodeStateStore

    func makeCoordinator() -> LiveMapNodeCoordinator {
        LiveMapNodeCoordinator(
            nodeID: nodeID,
            initialRegion: defaultRegion,
            stateStore: stateStore
        )
    }

    func makeNSView(context: Context) -> MKMapView {
        let coordinator = context.coordinator
        coordinator.snapshotContext = snapshotContext

        let mapView = LiveMapNodeMapView()
        mapView.debugNodeID = nodeID
        stateStore.recordMake(nodeID: nodeID, mapView: mapView)
        mapView.delegate = coordinator
        mapView.wantsLayer = true
        mapView.layer?.cornerRadius = cornerRadius
        mapView.layer?.masksToBounds = true
        mapView.setRegion(initialRegion, animated: false)
        coordinator.logMapState("makeNSView.afterSetup", mapView: mapView)

        mapView.onWindowAttach = { [weak coordinator] view in
            coordinator?.logMapState("windowAttach", mapView: view)
            coordinator?.kickIfReady(view)
        }

        // Register the interaction-end capture handler with the surrounding
        // LiveNode. The handler captures `mapView` weakly, so it always
        // reads from the current native view if SwiftUI recreates the
        // representable for unrelated tree changes.
        snapshotContext?.registerCapture { [weak mapView] in
            guard let mapView else { return nil }
            return await mapView.makeLiveMapNodeSnapshot()
        }

        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.snapshotContext = snapshotContext
        mapView.layer?.cornerRadius = cornerRadius
        coordinator.logMapState("updateNSView.beforeInteraction", mapView: mapView)
        coordinator.updateInteractionState(isInteractive, mapView: mapView)
    }

    static func dismantleNSView(_ mapView: MKMapView, coordinator: LiveMapNodeCoordinator) {
        coordinator.stateStore.recordDismantle(nodeID: coordinator.nodeID, mapView: mapView)
        coordinator.persistRegionIfUsable(from: mapView, reason: "dismantle")
        coordinator.tearDown()
        (mapView as? LiveMapNodeMapView)?.onWindowAttach = nil
        mapView.delegate = nil
    }

    private var initialRegion: MKCoordinateRegion {
        stateStore.regions[nodeID] ?? defaultRegion
    }

    private var defaultRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: initialCoordinate,
            latitudinalMeters: 3000,
            longitudinalMeters: 3000
        )
    }
}
#endif

// MARK: - Snapshot helper

#if os(macOS)
private extension MKMapView {
    @MainActor
    func makeLiveMapNodeSnapshot() async -> FlowNodeSnapshot? {
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: bitmap)
        guard let cgImage = bitmap.cgImage else { return nil }

        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2

        return FlowNodeSnapshot(cgImage: cgImage, scale: scale)
    }
}
#elseif os(iOS)
private extension MKMapView {
    @MainActor
    func makeLiveMapNodeSnapshot() async -> FlowNodeSnapshot? {
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        let scale = window?.screen.scale ?? traitCollection.displayScale
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = isOpaque

        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        let image = renderer.image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: true)
        }

        guard let cgImage = image.cgImage else { return nil }
        return FlowNodeSnapshot(cgImage: cgImage, scale: scale)
    }
}
#endif

#endif
