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
/// - Mount policy is ``LiveNodeMountPolicy/remountOnActivation``: MapKit's
///   tile pipeline does not survive an inactive cycle reliably, so each
///   activation gets a fresh `MKMapView`.
/// - Snapshot policy is ``LiveNodeSnapshotPolicy/onDeactivation`` so the
///   poster reflects the user's most recent pan/zoom. ``LiveNodeCapture``
///   is `.custom` and reads from a weak reference into the currently
///   mounted `MKMapView` — the closure is set once at `LiveNode` init,
///   but the target `MKMapView` is replaced on every activation cycle.
/// - The coordinator additionally pushes a one-shot bootstrap snapshot
///   500ms after the first activation kick so the poster is non-empty
///   before the user hovers out (the `.onDeactivation` policy does not
///   seed on appear).
/// - Region persistence is read/write through the user-supplied
///   ``LiveMapNodeStateStore`` so pan/zoom survives remount cycles.
/// - Tile pipeline kick: window-attach callback + non-zero bounds polling
///   so the map renders without requiring the user to interact first.
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

    @StateObject private var ref = LiveMapNodeRef()

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
        LiveNode(
            node: node,
            mount: .remountOnActivation,
            snapshot: .onDeactivation,
            capture: .custom { [ref] in
                ref.currentMapView?.makeLiveMapNodeSnapshot()
            }
        ) {
            LiveMapRepresentable(
                ref: ref,
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

// MARK: - Reference Holder

/// Stable per-``LiveMapNode`` handle that bridges the `LiveNode`
/// `capture: .custom` closure (set once at init time) to the currently
/// mounted `MKMapView` (recreated on every activation under
/// ``LiveNodeMountPolicy/remountOnActivation``). The reference is
/// `weak` so this object never extends the `MKMapView`'s lifetime;
/// dismantle is the natural cleanup point.
@MainActor
final class LiveMapNodeRef: ObservableObject {
    weak var currentMapView: LiveMapNodeMapView?

    init() {}
}

// MARK: - MKMapView subclass

/// `MKMapView` subclass that fires a hook every time the view is attached
/// to a window. Polling for non-zero bounds is brittle (the polling task
/// can race with platform layout and exhaust before the view is in the
/// hierarchy); the window-attach callback is the deterministic signal
/// that AppKit/UIKit has placed the view and is about to lay it out.
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

    /// Closure injected by ``LiveMapRepresentable`` from
    /// `\.flowLiveNodeSnapshotWriter` so the coordinator can push a
    /// bootstrap snapshot 500ms after the activation kick. `LiveNode` is
    /// configured with `snapshot: .onDeactivation` (no `seedOnAppear`),
    /// so without this push the poster stays empty until the user has
    /// hovered out at least once.
    var snapshotWriter: (@MainActor (String, FlowNodeSnapshot) -> Void)?

    /// Only flipped to `true` after a real-size `setRegion` has actually
    /// landed. Flipping it earlier would consume the activation edge on a
    /// still-zero-bounds view and leave MapKit's tile pipeline dormant
    /// forever — `updateActiveState` would never see another false→true.
    private var wasActive = false

    private var activationKickTask: Task<Void, Never>?

    /// One-shot delayed task that pushes the first real snapshot once the
    /// activation kick has actually rendered tiles.
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
            initialCaptureTask?.cancel()
            initialCaptureTask = nil
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

    func tearDown() {
        activationKickTask?.cancel()
        activationKickTask = nil
        initialCaptureTask?.cancel()
        initialCaptureTask = nil
        hasRequestedInitialCapture = false
        wasActive = false
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

                    do {
                        try await Task.sleep(nanoseconds: 16_000_000)
                    } catch {
                        return
                    }
                    if Task.isCancelled { return }

                    guard let view = mapView else { return }
                    Self.applyRegion(region, on: view)

                    self?.wasActive = true
                    self?.activationKickTask = nil
                    self?.requestInitialCaptureAfterRender(for: view)
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: 16_000_000)
                } catch {
                    return
                }
            }

            self?.activationKickTask = nil
        }
    }

    private func requestInitialCaptureAfterRender(for mapView: MKMapView) {
        guard !hasRequestedInitialCapture else { return }
        guard snapshotWriter != nil else { return }

        hasRequestedInitialCapture = true
        initialCaptureTask?.cancel()

        initialCaptureTask = Task { @MainActor [weak self, weak mapView] in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self, let mapView else { return }
            guard let snapshot = mapView.makeLiveMapNodeSnapshot() else { return }
            self.snapshotWriter?(self.nodeID, snapshot)
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

    @Environment(\.isFlowNodeActive) private var isActive
    @Environment(\.flowLiveNodeSnapshotWriter) private var snapshotWriter

    let ref: LiveMapNodeRef
    let nodeID: String
    let initialCoordinate: CLLocationCoordinate2D
    let cornerRadius: CGFloat
    let stateStore: LiveMapNodeStateStore

    func makeCoordinator() -> LiveMapNodeCoordinator {
        LiveMapNodeCoordinator(nodeID: nodeID, stateStore: stateStore)
    }

    func makeUIView(context: Context) -> MKMapView {
        context.coordinator.snapshotWriter = snapshotWriter

        let mapView = LiveMapNodeMapView()
        ref.currentMapView = mapView
        mapView.delegate = context.coordinator
        mapView.layer.cornerRadius = cornerRadius
        mapView.layer.masksToBounds = true
        mapView.setRegion(initialRegion, animated: false)

        let coordinator = context.coordinator
        mapView.onWindowAttach = { [weak coordinator] view in
            coordinator?.kickIfReady(view)
        }

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.snapshotWriter = snapshotWriter
        mapView.layer.cornerRadius = cornerRadius
        context.coordinator.updateActiveState(isActive, mapView: mapView)
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: LiveMapNodeCoordinator) {
        coordinator.stateStore.regions[coordinator.nodeID] = mapView.region
        coordinator.tearDown()
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

    @Environment(\.isFlowNodeActive) private var isActive
    @Environment(\.flowLiveNodeSnapshotWriter) private var snapshotWriter

    let ref: LiveMapNodeRef
    let nodeID: String
    let initialCoordinate: CLLocationCoordinate2D
    let cornerRadius: CGFloat
    let stateStore: LiveMapNodeStateStore

    func makeCoordinator() -> LiveMapNodeCoordinator {
        LiveMapNodeCoordinator(nodeID: nodeID, stateStore: stateStore)
    }

    func makeNSView(context: Context) -> MKMapView {
        context.coordinator.snapshotWriter = snapshotWriter

        let mapView = LiveMapNodeMapView()
        ref.currentMapView = mapView
        mapView.delegate = context.coordinator
        mapView.wantsLayer = true
        mapView.layer?.cornerRadius = cornerRadius
        mapView.layer?.masksToBounds = true
        mapView.setRegion(initialRegion, animated: false)

        let coordinator = context.coordinator
        mapView.onWindowAttach = { [weak coordinator] view in
            coordinator?.kickIfReady(view)
        }

        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.snapshotWriter = snapshotWriter
        mapView.layer?.cornerRadius = cornerRadius
        context.coordinator.updateActiveState(isActive, mapView: mapView)
    }

    static func dismantleNSView(_ mapView: MKMapView, coordinator: LiveMapNodeCoordinator) {
        coordinator.stateStore.regions[coordinator.nodeID] = mapView.region
        coordinator.tearDown()
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
