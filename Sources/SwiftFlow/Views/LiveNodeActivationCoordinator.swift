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

    /// IDs of nodes whose `nodeContent` currently contains a `LiveNode`.
    /// Populated by `FlowCanvas` from the aggregated
    /// `LiveNodePresenceKey` preference. Canvas's rasterize draw and the
    /// overlay's hit-testing / opacity gating both read this to leave
    /// plain (non-live) nodes alone — the Canvas keeps drawing them and
    /// the overlay keeps their row at opacity 0, so Canvas-level
    /// gestures (drag, selection) pass through untouched.
    var liveNodeIDs: Set<String> = [] {
        didSet { hasReceivedFirstPreferenceCycle = true }
    }

    /// Latches `true` the first time either presence or policy
    /// preferences land. The overlay holds off mounting any row until
    /// this is set, so a `.persistent` LiveNode's WKWebView never
    /// briefly mounts at opacity 0 (which would let the WebContent
    /// compositor go dormant before the policy preference arrives).
    /// Plain flows with no live nodes never trip this — there's
    /// nothing the overlay would mount in that case anyway.
    private(set) var hasReceivedFirstPreferenceCycle: Bool = false

    /// Per-node mount policy declared by each `LiveNode` via
    /// `LiveNodeMountPolicyKey`. `LiveNodeOverlayRow` consults this to
    /// decide whether a row may unmount on deactivation or must stay in
    /// the SwiftUI tree for the life of its viewport presence. Nodes
    /// missing from the dictionary fall back to
    /// ``LiveNodeMountPolicy/onActivation`` — the bootstrap window
    /// before the first preference cycle lands, and any plain
    /// (non-live) row.
    var liveNodeMountPolicies: [String: LiveNodeMountPolicy] = [:] {
        didSet { hasReceivedFirstPreferenceCycle = true }
    }

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

    /// Clears the capture handler for a node. **Does not** touch
    /// `intent`, `renderedActive`, or in-flight deactivation tasks —
    /// `LiveNode`'s `onDisappear` fires for view-tree reasons that are
    /// not actually node deactivations (`.remountOnActivation` swapping
    /// its inner content, viewport cull, transient parent re-layout),
    /// and tearing down activation state from any of those would make
    /// the overlay drop the row mid-display.
    ///
    /// Cancelling the deactivation task here is also wrong: the task
    /// is the driver of `renderedActive.remove`, so cancelling it
    /// after intent has gone false would leave the row stuck active.
    /// Activation/deactivation is owned solely by
    /// ``update(nodeID:intent:)``, which is driven by the predicate
    /// edge.
    func unregisterCapture(for nodeID: String) {
        captureHandlers.removeValue(forKey: nodeID)
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

    /// Per-node mount policy as published by each `LiveNode`. Falls back
    /// to ``LiveNodeMountPolicy/onActivation`` for nodes that haven't
    /// surfaced a policy yet (the bootstrap window before the first
    /// `LiveNodeMountPolicyKey` preference cycle lands) and for plain
    /// non-live rows.
    func mountPolicy(for nodeID: String) -> LiveNodeMountPolicy {
        liveNodeMountPolicies[nodeID] ?? .onActivation
    }

    /// Whether the Canvas's rasterize path should skip this node because
    /// the overlay is currently drawing a live view for it. Plain
    /// (non-live) rows answer `false` even when hovered/selected, so
    /// Canvas keeps drawing them — otherwise the node would disappear
    /// the instant the user moves the cursor over it.
    ///
    /// **Poster pattern**: every LiveNode (regardless of mount policy)
    /// is drawn by the Canvas as a snapshot poster while inactive, and
    /// only swaps to the live overlay view while the user is hovering
    /// or has selected it. ``LiveNodeMountPolicy/persistent`` differs
    /// from ``LiveNodeMountPolicy/onActivation`` only in **mount**
    /// behaviour — the underlying native view stays in the SwiftUI
    /// tree so its CARemoteLayer pipeline doesn't stall — not in
    /// **drawing** behaviour. That is why this method ignores mount
    /// policy and answers solely on `renderedActive`.
    func overlayIsDrawing(_ nodeID: String) -> Bool {
        guard liveNodeIDs.contains(nodeID) else { return false }
        return renderedActive.contains(nodeID)
    }

    /// Whether the overlay row should accept hit-testing. Distinct from
    /// ``overlayIsDrawing(_:)`` because `.persistent` rows stay drawn
    /// (opacity 1) the whole time they are mounted, but their underlying
    /// `WKWebView` / `MKMapView` should only intercept scroll / click
    /// while the user is actually interacting with the node. When the
    /// row is not active, hit-testing is off so a click passes through
    /// to Canvas — letting selection trigger and, in turn, activate the
    /// row through the predicate.
    func overlayIsHittable(_ nodeID: String) -> Bool {
        liveNodeIDs.contains(nodeID) && renderedActive.contains(nodeID)
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
