#if os(iOS) || os(macOS)
import SwiftUI
import MapKit
import CoreLocation

// MARK: - State Store

/// Per-node region cache for ``LiveMapNode``.
///
/// `LiveMapNode` uses ``LiveNodeMountPolicy/remountOnActivation``, which
/// means the underlying `MKMapView` instance is destroyed and recreated
/// every time the node deactivates and reactivates. Without an external
/// store, the user's pan/zoom state would be lost on each cycle. This
/// observable store keeps the last-seen region per node ID across
/// remount cycles.
@MainActor
@Observable
public final class LiveMapNodeStateStore {

    public var regions: [String: MKCoordinateRegion] = [:]

    public init() {}
}

// MARK: - Public View

/// Drop-in `LiveNode` wrapper around `MKMapView`.
///
/// Hides the bookkeeping required to make a native MapView cooperate
/// with the Poster pattern:
///
/// - mount policy: `.remountOnActivation` (MapKit's tile pipeline does
///   not survive an inactive cycle reliably, so each activation gets a
///   fresh MKMapView)
/// - snapshot policy: `.nativeManual` (the wrapper requests a one-shot
///   capture once the tile pipeline has produced its first stable frame
///   — high-frequency MapKit delegate callbacks would otherwise create
///   a write-feedback loop)
/// - region persistence: read/write through the user-supplied
///   ``LiveMapNodeStateStore`` so pan/zoom survives remounts
/// - tile pipeline kick: window-attach + non-zero bounds polling so the
///   map renders without requiring the user to interact first
///
/// Usage:
///
/// ```swift
/// FlowCanvas(store: store) { node, context in
///     LiveMapNode(
///         node: node,
///         initialCoordinate: node.data.coordinate,
///         stateStore: mapStateStore,
///         cornerRadius: 12
///     )
///     .padding(FlowHandle.diameter / 2)
///     .overlay { FlowNodeHandles(node: node, context: context) }
/// }
/// ```
public struct LiveMapNode<Data>: View where Data: Sendable & Hashable {

    private let node: FlowNode<Data>
    private let initialCoordinate: CLLocationCoordinate2D
    private let stateStore: LiveMapNodeStateStore
    private let cornerRadius: CGFloat

    public init(
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

    public var body: some View {
        LiveNode(node: node) {
            LiveMapRepresentable(
                nodeID: node.id,
                initialCoordinate: initialCoordinate,
                cornerRadius: cornerRadius,
                stateStore: stateStore
            )
        } placeholder: {
            Color.clear
        }
        .liveNodeMount(.remountOnActivation)
        .liveNodeSnapshot(.nativeManual)
    }
}

// MARK: - MKMapView subclass

/// `MKMapView` subclass that fires a hook every time the view is
/// attached to a window. Polling for non-zero bounds is brittle (the
/// polling task can race with platform layout and exhaust before the
/// view is in the hierarchy); the window-attach callback is the
/// deterministic signal that AppKit/UIKit has placed the view and is
/// about to lay it out.
final class LiveMapNodeMapView: MKMapView {

    var onWindowAttach: (@MainActor (LiveMapNodeMapView) -> Void)?

    #if os(macOS)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        let attach = onWindowAttach
        Task { @MainActor in
            attach?(self)
        }
    }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        let attach = onWindowAttach
        Task { @MainActor in
            attach?(self)
        }
    }
    #endif
}

// MARK: - Coordinator

@MainActor
final class LiveMapNodeCoordinator: NSObject, MKMapViewDelegate {

    let nodeID: String
    let stateStore: LiveMapNodeStateStore
    var snapshotContext: LiveNodeNativeSnapshotContext?

    private var registeredMapViewID: ObjectIdentifier?

    /// Only flipped to `true` after a real-size `setRegion` has actually
    /// landed. Flipping it earlier would consume the activation edge on
    /// a still-zero-bounds view and leave MapKit's tile pipeline dormant
    /// forever — `updateActiveState` would never see another false→true.
    private var wasActive = false

    private var activationKickTask: Task<Void, Never>?

    /// One-shot delayed task that asks `LiveNode` to capture a
    /// snapshot once the first activation kick has actually rendered
    /// tiles. `.nativeManual` snapshot policy does not seed on appear,
    /// so without this the Canvas poster stays empty and the user has
    /// to hover the map to see anything.
    private var initialCaptureTask: Task<Void, Never>?
    private var hasRequestedInitialCapture = false

    init(nodeID: String, stateStore: LiveMapNodeStateStore) {
        self.nodeID = nodeID
        self.stateStore = stateStore
    }

    func updateActiveState(_ isActive: Bool, mapView: MKMapView) {
        if !isActive {
            wasActive = false
            activationKickTask?.cancel()
            activationKickTask = nil
            return
        }

        guard !wasActive else { return }
        guard activationKickTask == nil else { return }
        scheduleActivationKick(for: mapView)
    }

    /// Forces the map's tile pipeline to wake. Driven by either the
    /// window-attach callback on `LiveMapNodeMapView` or by
    /// `updateActiveState` for representables that race ahead of the
    /// window attach. Idempotent via `wasActive`.
    func kickIfReady(_ mapView: MKMapView) {
        guard !wasActive else { return }
        guard mapView.window != nil else { return }
        if activationKickTask == nil {
            scheduleActivationKick(for: mapView)
        }
    }

    private func scheduleActivationKick(for mapView: MKMapView) {
        let region = stateStore.regions[nodeID] ?? mapView.region

        activationKickTask = Task { @MainActor [weak self, weak mapView] in
            for _ in 0..<60 {
                if Task.isCancelled { return }
                guard let view = mapView else { return }

                #if os(macOS)
                view.superview?.layoutSubtreeIfNeeded()
                #else
                view.superview?.layoutIfNeeded()
                #endif

                if view.bounds.width > 1, view.bounds.height > 1 {
                    Self.applyRegion(region, on: view)

                    try? await Task.sleep(nanoseconds: 16_000_000)
                    if Task.isCancelled { return }

                    guard let view = mapView else { return }
                    Self.applyRegion(region, on: view)

                    self?.wasActive = true
                    self?.activationKickTask = nil
                    self?.requestInitialCaptureAfterRender()
                    return
                }

                try? await Task.sleep(nanoseconds: 16_000_000)
            }

            self?.activationKickTask = nil
        }
    }

    private func requestInitialCaptureAfterRender() {
        guard !hasRequestedInitialCapture else { return }
        guard snapshotContext != nil else { return }

        hasRequestedInitialCapture = true
        initialCaptureTask?.cancel()

        initialCaptureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.snapshotContext?.requestCapture()
            self.initialCaptureTask = nil
        }
    }

    private static func applyRegion(_ region: MKCoordinateRegion, on mapView: MKMapView) {
        #if os(macOS)
        mapView.needsLayout = true
        mapView.layoutSubtreeIfNeeded()
        #else
        mapView.setNeedsLayout()
        mapView.layoutIfNeeded()
        #endif
        mapView.setRegion(region, animated: false)
    }

    func registerCaptureIfNeeded(for mapView: MKMapView) {
        guard let snapshotContext else {
            registeredMapViewID = nil
            return
        }

        let id = ObjectIdentifier(mapView)
        guard registeredMapViewID != id else { return }
        registeredMapViewID = id

        snapshotContext.registerCapture { [weak mapView] in
            guard let mapView else { return nil }
            return mapView.makeLiveMapNodeSnapshot()
        }
    }

    func unregisterCapture() {
        registeredMapViewID = nil
        activationKickTask?.cancel()
        activationKickTask = nil
        initialCaptureTask?.cancel()
        initialCaptureTask = nil
        hasRequestedInitialCapture = false
        snapshotContext?.unregisterCapture()
    }

    nonisolated func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        Task { @MainActor [weak self, weak mapView] in
            guard let self, let mapView else { return }
            self.stateStore.regions[self.nodeID] = mapView.region
        }
    }
}

// MARK: - Representable

#if os(iOS)
struct LiveMapRepresentable: UIViewRepresentable {

    @Environment(\.liveNodeNativeSnapshotContext) private var snapshotContext
    @Environment(\.isFlowNodeActive) private var isActive

    let nodeID: String
    let initialCoordinate: CLLocationCoordinate2D
    let cornerRadius: CGFloat
    let stateStore: LiveMapNodeStateStore

    func makeCoordinator() -> LiveMapNodeCoordinator {
        LiveMapNodeCoordinator(nodeID: nodeID, stateStore: stateStore)
    }

    func makeUIView(context: Context) -> MKMapView {
        context.coordinator.snapshotContext = snapshotContext

        let mapView = LiveMapNodeMapView()
        mapView.delegate = context.coordinator
        mapView.layer.cornerRadius = cornerRadius
        mapView.layer.masksToBounds = true
        mapView.setRegion(initialRegion, animated: false)

        let coordinator = context.coordinator
        mapView.onWindowAttach = { [weak coordinator] view in
            coordinator?.kickIfReady(view)
        }

        coordinator.registerCaptureIfNeeded(for: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.snapshotContext = snapshotContext
        mapView.layer.cornerRadius = cornerRadius
        context.coordinator.registerCaptureIfNeeded(for: mapView)
        context.coordinator.updateActiveState(isActive, mapView: mapView)
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: LiveMapNodeCoordinator) {
        coordinator.stateStore.regions[coordinator.nodeID] = mapView.region
        coordinator.unregisterCapture()
        (mapView as? LiveMapNodeMapView)?.onWindowAttach = nil
        mapView.delegate = nil
    }

    private var initialRegion: MKCoordinateRegion {
        stateStore.regions[nodeID] ?? MKCoordinateRegion(
            center: initialCoordinate,
            latitudinalMeters: 3000,
            longitudinalMeters: 3000
        )
    }
}
#elseif os(macOS)
struct LiveMapRepresentable: NSViewRepresentable {

    @Environment(\.liveNodeNativeSnapshotContext) private var snapshotContext
    @Environment(\.isFlowNodeActive) private var isActive

    let nodeID: String
    let initialCoordinate: CLLocationCoordinate2D
    let cornerRadius: CGFloat
    let stateStore: LiveMapNodeStateStore

    func makeCoordinator() -> LiveMapNodeCoordinator {
        LiveMapNodeCoordinator(nodeID: nodeID, stateStore: stateStore)
    }

    func makeNSView(context: Context) -> MKMapView {
        context.coordinator.snapshotContext = snapshotContext

        let mapView = LiveMapNodeMapView()
        mapView.delegate = context.coordinator
        mapView.wantsLayer = true
        mapView.layer?.cornerRadius = cornerRadius
        mapView.layer?.masksToBounds = true
        mapView.setRegion(initialRegion, animated: false)

        let coordinator = context.coordinator
        mapView.onWindowAttach = { [weak coordinator] view in
            coordinator?.kickIfReady(view)
        }

        coordinator.registerCaptureIfNeeded(for: mapView)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.snapshotContext = snapshotContext
        mapView.layer?.cornerRadius = cornerRadius
        context.coordinator.registerCaptureIfNeeded(for: mapView)
        context.coordinator.updateActiveState(isActive, mapView: mapView)
    }

    static func dismantleNSView(_ mapView: MKMapView, coordinator: LiveMapNodeCoordinator) {
        coordinator.stateStore.regions[coordinator.nodeID] = mapView.region
        coordinator.unregisterCapture()
        (mapView as? LiveMapNodeMapView)?.onWindowAttach = nil
        mapView.delegate = nil
    }

    private var initialRegion: MKCoordinateRegion {
        stateStore.regions[nodeID] ?? MKCoordinateRegion(
            center: initialCoordinate,
            latitudinalMeters: 3000,
            longitudinalMeters: 3000
        )
    }
}
#endif

// MARK: - Snapshot helper

#if os(macOS)
private extension NSView {
    @MainActor
    func makeLiveMapNodeSnapshot() -> FlowNodeSnapshot? {
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
private extension UIView {
    @MainActor
    func makeLiveMapNodeSnapshot() -> FlowNodeSnapshot? {
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
