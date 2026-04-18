import SwiftUI

/// Decouples the raw activation **intent** (the overlay's predicate result
/// — "user is hovering or selecting this node") from the **rendered
/// active** state (whether `LiveNodeOverlay` actually shows the live view
/// at opacity 1).
///
/// Without this split, deactivation looks like:
///
/// 1. User moves cursor off → intent flips to `false`
/// 2. Overlay opacity 1 → 0 **instantly**
/// 3. Canvas rasterize path draws the stale cached snapshot
/// 4. Async capture completes, writes fresh snapshot
/// 5. Canvas redraws with the new snapshot
///
/// The window between steps 2 and 5 is where the user sees the old
/// thumbnail — noticeable for WKWebView / MKMapView where pan/zoom state
/// visibly differs from the cached image.
///
/// The coordinator inverts that order:
///
/// 1. User moves cursor off → intent flips to `false`
/// 2. Coordinator enters **deactivating**: `renderedActive` stays `true`,
///    overlay opacity remains 1, Canvas skip remains in effect
/// 3. Coordinator awaits the registered capture handler
/// 4. Capture writes fresh snapshot to the store
/// 5. `renderedActive` flips to `false`, overlay fades, Canvas now draws
///    the fresh snapshot as the first visible frame
///
/// If the user re-hovers during step 3 the in-flight deactivation task is
/// cancelled and `renderedActive` stays `true` throughout — no flicker.
///
/// The coordinator is injected by `FlowCanvas` via
/// `\.liveNodeActivationCoordinator`; `LiveNode` registers its capture
/// handler on appear and unregisters on disappear.
@MainActor
@Observable
final class LiveNodeActivationCoordinator {

    /// IDs the overlay should render at opacity 1 with hit testing on.
    /// Reading this in the overlay body subscribes to Observation-driven
    /// updates so render state animates with intent + capture completion.
    private(set) var renderedActive: Set<String> = []

    /// Last observed intent per node (used only for edge detection).
    private var intent: [String: Bool] = [:]

    /// Capture handlers registered by `LiveNode` per capture mode.
    private var captureHandlers: [String: @MainActor () async -> Void] = [:]

    /// In-flight deactivation tasks keyed by node ID.
    private var deactivationTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Registration

    /// Registers the async capture handler `LiveNode` will invoke when the
    /// node starts deactivating. Idempotent — a subsequent call replaces
    /// the previous handler (useful when the capture closure captures
    /// `self` on a `View` value type whose address changes across body
    /// evaluations).
    func registerCapture(
        for nodeID: String,
        handler: @escaping @MainActor () async -> Void
    ) {
        captureHandlers[nodeID] = handler
    }

    /// Clears all state for a node. Called by `LiveNode.onDisappear` so
    /// viewport-culled or removed nodes don't leak task / handler entries.
    func unregisterCapture(for nodeID: String) {
        captureHandlers.removeValue(forKey: nodeID)
        if let task = deactivationTasks.removeValue(forKey: nodeID) {
            task.cancel()
        }
        intent.removeValue(forKey: nodeID)
        renderedActive.remove(nodeID)
    }

    // MARK: - Intent → render-state transitions

    /// Applies intent for a node. Safe to call every body evaluation — the
    /// coordinator only acts on edges (intent actually flipped).
    ///
    /// - `false → true`: cancels any pending deactivation, inserts into
    ///   `renderedActive` synchronously.
    /// - `true  → false`: starts an async deactivation task that awaits
    ///   the registered capture handler, then removes from
    ///   `renderedActive` (provided intent is still `false`).
    func update(nodeID: String, intent newIntent: Bool) {
        let previous = intent[nodeID] ?? false
        intent[nodeID] = newIntent
        guard previous != newIntent else { return }

        if newIntent {
            if let task = deactivationTasks.removeValue(forKey: nodeID) {
                task.cancel()
            }
            renderedActive.insert(nodeID)
        } else {
            guard renderedActive.contains(nodeID) else { return }
            if let task = deactivationTasks.removeValue(forKey: nodeID) {
                task.cancel()
            }
            let handler = captureHandlers[nodeID]
            deactivationTasks[nodeID] = Task { @MainActor [weak self] in
                if let handler {
                    await handler()
                }
                guard let self else { return }
                if Task.isCancelled { return }
                // Confirm the user didn't re-hover while capturing; if
                // they did, a later `update(... intent: true)` already
                // cancelled this task and we would have returned above.
                if self.intent[nodeID] == false {
                    self.renderedActive.remove(nodeID)
                }
                self.deactivationTasks.removeValue(forKey: nodeID)
            }
        }
    }

    /// Convenience used by the overlay and the Canvas skip to query the
    /// same source of truth.
    func isRenderedActive(_ nodeID: String) -> Bool {
        renderedActive.contains(nodeID)
    }
}

// MARK: - Environment

private struct LiveNodeActivationCoordinatorKey: EnvironmentKey {
    static let defaultValue: LiveNodeActivationCoordinator? = nil
}

extension EnvironmentValues {
    /// The coordinator that `LiveNode` uses to register its capture
    /// handler with the overlay's deactivation pipeline. Injected by
    /// `FlowCanvas`; `nil` when a `LiveNode` is rendered outside a
    /// `FlowCanvas` (the rasterize-only preview case), in which case
    /// `LiveNode` skips registration and falls back to best-effort
    /// capture semantics.
    var liveNodeActivationCoordinator: LiveNodeActivationCoordinator? {
        get { self[LiveNodeActivationCoordinatorKey.self] }
        set { self[LiveNodeActivationCoordinatorKey.self] = newValue }
    }
}
