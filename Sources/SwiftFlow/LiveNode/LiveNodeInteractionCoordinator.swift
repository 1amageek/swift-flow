import Foundation
import SwiftUI

/// Decouples the raw interaction **intent** (the overlay's predicate result
/// — "this node should currently be live") from the **rendered
/// interactive** state (whether `LiveNodeOverlay` actually shows the live view
/// at opacity 1).
///
/// Without this split, interaction end looks like:
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
/// 2. Coordinator enters **ending interaction**: `renderedInteractive` stays `true`,
///    overlay opacity remains 1, Canvas skip remains in effect
/// 3. Coordinator awaits the registered capture handler
/// 4. Capture writes fresh snapshot to the store
/// 5. `renderedInteractive` flips to `false`, overlay fades, Canvas now draws
///    the fresh snapshot as the first visible frame
///
/// If the user re-hovers during step 3 the in-flight interaction-end task is
/// cancelled and `renderedInteractive` stays `true` throughout — no flicker.
///
/// The coordinator is injected by `FlowCanvas` via
/// `\.liveNodeInteractionCoordinator`; `LiveNode` registers its capture
/// handler on appear and unregisters on disappear.
@MainActor
@Observable
final class LiveNodeInteractionCoordinator {

    /// IDs the overlay should render at opacity 1 with hit testing on.
    /// Reading this in the overlay body subscribes to Observation-driven
    /// updates so render state animates with intent + capture completion.
    private(set) var renderedInteractive: Set<String> = []

    /// IDs of nodes whose `nodeContent` currently contains a `LiveNode`.
    /// Populated by `FlowCanvas` from the aggregated
    /// `LiveNodePresenceKey` preference, scoped by the latest
    /// ``EvaluatedNodeIDsKey`` cycle so a `LiveNode` that conditionally
    /// disappears (e.g. `if showLive { LiveNode { … } }`) is dropped
    /// from this set instead of lingering forever via union semantics.
    /// Canvas's rasterize draw and the overlay's hit-testing / opacity
    /// gating both read this to leave plain (non-live) nodes alone —
    /// the Canvas keeps drawing them and the overlay keeps their row
    /// at opacity 0, so Canvas-level gestures (drag, selection) pass
    /// through untouched.
    private(set) var liveNodeIDs: Set<String> = []

    /// Latches `true` the first time the registrar's
    /// ``EvaluatedNodeIDsKey`` cycle lands. The overlay holds off
    /// mounting any row until this is set, so a `.persistent`
    /// LiveNode's WKWebView never briefly mounts at opacity 0 (which
    /// would let the WebContent compositor go dormant before the
    /// policy preference arrives).
    private(set) var hasReceivedFirstPreferenceCycle: Bool = false

    /// Most recent set of node IDs evaluated by the registrar pass.
    /// Treated as the **scope** within which presence and policy
    /// preferences are authoritative for the latest cycle. Nodes
    /// outside this scope keep their prior decisions, which is what
    /// guards against transient empty preference cycles.
    private(set) var lastEvaluatedNodeIDs: Set<String> = []

    /// Per-node mount policy declared by each `LiveNode` via
    /// `LiveNodeMountPolicyKey`. `LiveNodeOverlayRow` consults this to
    /// decide whether a row may unmount on interaction end or must stay in
    /// the SwiftUI tree for the life of its viewport presence. Nodes
    /// missing from the dictionary fall back to
    /// ``LiveNodeMountPolicy/onInteraction`` — the bootstrap window
    /// before the first preference cycle lands, and any plain
    /// (non-live) row.
    private(set) var liveNodeMountPolicies: [String: LiveNodeMountPolicy] = [:]

    /// Last observed intent per node (used only for edge detection).
    private var intent: [String: Bool] = [:]

    /// Capture handlers registered by `LiveNode` per capture mode.
    private var captureHandlers: [String: @MainActor () async -> Void] = [:]

    /// In-flight interaction-end tasks keyed by node ID.
    private var interactionEndTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Preference application

    /// Reconciles the registrar scope, LiveNode presence, and mount policies
    /// from one preference snapshot. Within the evaluated scope, the snapshot
    /// is authoritative; outside the scope, prior decisions carry over.
    func applyPreferences(
        evaluated: Set<String>,
        present: Set<String>,
        policies: [String: LiveNodeMountPolicy],
        storeNodeIDs: Set<String>
    ) {
        let scoped = evaluated.intersection(storeNodeIDs)
        guard !scoped.isEmpty else {
            liveNodeIDs = liveNodeIDs.intersection(storeNodeIDs)
            liveNodeMountPolicies = liveNodeMountPolicies.filter { storeNodeIDs.contains($0.key) }
            if storeNodeIDs.isEmpty {
                lastEvaluatedNodeIDs = []
            }
            return
        }

        lastEvaluatedNodeIDs = scoped
        hasReceivedFirstPreferenceCycle = true

        let withinScope = present.intersection(scoped)
        let outsideScope = liveNodeIDs.subtracting(scoped)
        liveNodeIDs = withinScope.union(outsideScope).intersection(storeNodeIDs)

        var nextPolicies = liveNodeMountPolicies.filter { !scoped.contains($0.key) }
        for (id, policy) in policies where scoped.contains(id) {
            nextPolicies[id] = policy
        }
        liveNodeMountPolicies = nextPolicies.filter { storeNodeIDs.contains($0.key) }
    }

    /// Stores the latest `EvaluatedNodeIDsKey` cycle, intersected with the
    /// store's current node ids. Empty cycles (which SwiftUI publishes
    /// during transient ForEach rebuilds) are ignored so they cannot
    /// erase prior decisions.
    func applyEvaluatedNodeIDs(
        _ evaluated: Set<String>,
        storeNodeIDs: Set<String>
    ) {
        let scoped = evaluated.intersection(storeNodeIDs)
        guard !scoped.isEmpty else { return }
        lastEvaluatedNodeIDs = scoped
        hasReceivedFirstPreferenceCycle = true
    }

    /// Reconciles `liveNodeIDs` with the latest `LiveNodePresenceKey`
    /// cycle. Within ``lastEvaluatedNodeIDs`` (the registrar's coverage
    /// for the current cycle) presence is authoritative and replaces
    /// prior state — that is what drops a conditionally-disappeared
    /// `LiveNode` from `liveNodeIDs`. Outside that scope prior
    /// decisions carry over so a partial preference cycle cannot
    /// silently demote untouched live nodes.
    func applyLiveNodePresence(
        _ present: Set<String>,
        storeNodeIDs: Set<String>
    ) {
        let evaluated = lastEvaluatedNodeIDs
        guard !evaluated.isEmpty else {
            // No evaluation cycle on record yet — fall back to the legacy
            // union so the very first preference cycle (which may arrive
            // before the registrar's evaluation propagates) is not lost.
            liveNodeIDs = liveNodeIDs.union(present).intersection(storeNodeIDs)
            return
        }
        let withinScope = present.intersection(evaluated)
        let outsideScope = liveNodeIDs.subtracting(evaluated)
        liveNodeIDs = withinScope.union(outsideScope).intersection(storeNodeIDs)
    }

    /// Reconciles `liveNodeMountPolicies` the same way as presence:
    /// within the latest evaluated scope, the cycle's entries replace
    /// prior values; outside the scope, prior values carry over.
    func applyLiveNodeMountPolicies(
        _ policies: [String: LiveNodeMountPolicy],
        storeNodeIDs: Set<String>
    ) {
        let evaluated = lastEvaluatedNodeIDs
        guard !evaluated.isEmpty else {
            var merged = liveNodeMountPolicies
            merged.merge(policies) { _, new in new }
            liveNodeMountPolicies = merged.filter { storeNodeIDs.contains($0.key) }
            return
        }
        var next = liveNodeMountPolicies.filter { !evaluated.contains($0.key) }
        for (id, policy) in policies where evaluated.contains(id) {
            next[id] = policy
        }
        liveNodeMountPolicies = next.filter { storeNodeIDs.contains($0.key) }
    }

    // MARK: - Registration

    /// Registers the async capture handler `LiveNode` will invoke when the
    /// node starts ending interaction. Idempotent — a subsequent call replaces
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
    /// `intent`, `renderedInteractive`, or in-flight interaction-end tasks —
    /// `LiveNode`'s `onDisappear` fires for view-tree reasons that are
    /// not actually node interaction ends (viewport cull, transient parent
    /// re-layout), and tearing down interaction state from any of those
    /// would make the overlay drop the row mid-display.
    ///
    /// Cancelling the interaction-end task here is also wrong: the task
    /// is the driver of `renderedInteractive.remove`, so cancelling it
    /// after intent has gone false would leave the row stuck interactive.
    /// Interaction start/end is owned solely by
    /// ``update(nodeID:intent:)``, which is driven by the predicate
    /// edge.
    func unregisterCapture(for nodeID: String) {
        captureHandlers.removeValue(forKey: nodeID)
    }

    // MARK: - Intent → render-state transitions

    /// Applies intent for a node. Safe to call every body evaluation — the
    /// coordinator only acts on edges (intent actually flipped).
    ///
    /// - `false → true`: cancels any pending interaction end, inserts into
    ///   `renderedInteractive` synchronously.
    /// - `true  → false`: starts an async interaction-end task that awaits
    ///   the registered capture handler, then removes from
    ///   `renderedInteractive` (provided intent is still `false`).
    func update(nodeID: String, intent newIntent: Bool) {
        let previous = intent[nodeID] ?? false
        intent[nodeID] = newIntent
        guard previous != newIntent else { return }


        if newIntent {
            if let task = interactionEndTasks.removeValue(forKey: nodeID) {
                task.cancel()
            }
            renderedInteractive.insert(nodeID)
        } else {
            guard renderedInteractive.contains(nodeID) else { return }
            if let task = interactionEndTasks.removeValue(forKey: nodeID) {
                task.cancel()
            }
            let handler = captureHandlers[nodeID]
            interactionEndTasks[nodeID] = Task { @MainActor [weak self] in
                if let handler {
                    await handler()
                }
                guard let self else { return }
                if Task.isCancelled {
                    return
                }
                // Confirm the user didn't re-hover while capturing; if
                // they did, a later `update(... intent: true)` already
                // cancelled this task and we would have returned above.
                if self.intent[nodeID] == false {
                    self.renderedInteractive.remove(nodeID)
                }
                self.interactionEndTasks.removeValue(forKey: nodeID)
            }
        }
    }

    /// Convenience used by the overlay and the Canvas skip to query the
    /// same source of truth.
    func isRenderedInteractive(_ nodeID: String) -> Bool {
        renderedInteractive.contains(nodeID)
    }

    /// Per-node mount policy as published by each `LiveNode`. Falls back
    /// to ``LiveNodeMountPolicy/onInteraction`` for nodes that haven't
    /// surfaced a policy yet (the bootstrap window before the first
    /// `LiveNodeMountPolicyKey` preference cycle lands) and for plain
    /// non-live rows.
    func mountPolicy(for nodeID: String) -> LiveNodeMountPolicy {
        liveNodeMountPolicies[nodeID] ?? .onInteraction
    }

    /// Whether the Canvas's rasterize path should skip this node because
    /// the overlay is currently drawing a live view for it. Plain
    /// (non-live) rows answer `false` even when hovered or selected, so
    /// Canvas keeps drawing them — otherwise the node would disappear
    /// the instant the user moves the cursor over it.
    ///
    /// **Poster pattern**: every LiveNode (regardless of mount policy)
    /// is drawn by the Canvas as a snapshot poster while not interactive, and
    /// only swaps to the live overlay view while the interaction predicate
    /// returns true. By default that means the user is hovering the node.
    /// ``LiveNodeMountPolicy/persistent`` differs
    /// from ``LiveNodeMountPolicy/onInteraction`` only in **mount**
    /// behaviour — the underlying native view stays in the SwiftUI
    /// tree so its CARemoteLayer pipeline doesn't stall — not in
    /// **drawing** behaviour. That is why this method ignores mount
    /// policy and answers solely on `renderedInteractive`.
    func overlayIsDrawing(_ nodeID: String) -> Bool {
        guard liveNodeIDs.contains(nodeID) else { return false }
        return renderedInteractive.contains(nodeID)
    }

    /// Whether the overlay row should accept hit-testing. Distinct from
    /// ``overlayIsDrawing(_:)`` because `.persistent` rows stay drawn
    /// (opacity 1) the whole time they are mounted, but their underlying
    /// `WKWebView` / `MKMapView` should only intercept scroll / click
    /// while the user is actually interacting with the node. When the
    /// row is not interactive, hit-testing is off so a click passes through
    /// to Canvas — letting the Canvas continue to own selection and drag
    /// gestures while the node is not live.
    func overlayIsHittable(_ nodeID: String) -> Bool {
        liveNodeIDs.contains(nodeID) && renderedInteractive.contains(nodeID)
    }
}

// MARK: - Environment

private struct LiveNodeInteractionCoordinatorKey: EnvironmentKey {
    static let defaultValue: LiveNodeInteractionCoordinator? = nil
}

extension EnvironmentValues {
    /// The coordinator that `LiveNode` uses to register its capture
    /// handler with the overlay's interaction-end pipeline. Injected by
    /// `FlowCanvas`; `nil` when a `LiveNode` is rendered outside a
    /// `FlowCanvas` (the rasterize-only preview case), in which case
    /// `LiveNode` skips registration and falls back to best-effort
    /// capture semantics.
    var liveNodeInteractionCoordinator: LiveNodeInteractionCoordinator? {
        get { self[LiveNodeInteractionCoordinatorKey.self] }
        set { self[LiveNodeInteractionCoordinatorKey.self] = newValue }
    }
}
