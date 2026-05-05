import SwiftUI

/// Per-`LiveNode` channel that descendant views — typically
/// `UIViewRepresentable` / `NSViewRepresentable` wrappers around `WKWebView`,
/// `MKMapView`, `AVPlayerView` — use to participate in the snapshot
/// pipeline without taking on `LiveNode`'s internal coordinator wiring.
///
/// Read it from the environment:
///
/// ```swift
/// @Environment(\.liveNodeSnapshotContext) private var snapshot
/// ```
///
/// Three things the context lets a descendant do:
///
/// - ``write(_:)`` — push a snapshot directly. Use after a navigation
///   completes (`WKWebView`) or a tile pass lands (`MKMapView`).
/// - ``registerCapture(_:)`` — install an async capture handler that
///   `LiveNode` invokes during the deactivation pipeline (and via
///   ``requestCapture()``). The handler typically reads from the live
///   native view weakly and produces a `FlowNodeSnapshot`.
/// - ``requestCapture()`` — explicitly drive a capture pass on demand,
///   e.g. 500 ms after first attach so the poster has a real frame
///   before the user ever hovers out.
///
/// The context is `nil` when a `LiveNode` is rendered outside a
/// `FlowCanvas` (rasterize-only previews) — there is nowhere to deposit
/// snapshots in that case, so all four operations become no-ops.
public struct LiveNodeSnapshotContext: Sendable {

    public let nodeID: String

    let _write: @MainActor @Sendable (FlowNodeSnapshot) -> Void
    let _registerCapture: @MainActor @Sendable (
        @escaping @MainActor () async -> FlowNodeSnapshot?
    ) -> Void
    let _unregisterCapture: @MainActor @Sendable () -> Void
    let _requestCapture: @MainActor @Sendable () async -> Void

    public init(
        nodeID: String,
        write: @escaping @MainActor @Sendable (FlowNodeSnapshot) -> Void,
        registerCapture: @escaping @MainActor @Sendable (
            @escaping @MainActor () async -> FlowNodeSnapshot?
        ) -> Void,
        unregisterCapture: @escaping @MainActor @Sendable () -> Void,
        requestCapture: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.nodeID = nodeID
        self._write = write
        self._registerCapture = registerCapture
        self._unregisterCapture = unregisterCapture
        self._requestCapture = requestCapture
    }

    @MainActor
    public func write(_ snapshot: FlowNodeSnapshot) {
        _write(snapshot)
    }

    @MainActor
    public func registerCapture(
        _ handler: @escaping @MainActor () async -> FlowNodeSnapshot?
    ) {
        _registerCapture(handler)
    }

    @MainActor
    public func unregisterCapture() {
        _unregisterCapture()
    }

    @MainActor
    public func requestCapture() async {
        await _requestCapture()
    }
}

private struct LiveNodeSnapshotContextKey: EnvironmentKey {
    static let defaultValue: LiveNodeSnapshotContext? = nil
}

public extension EnvironmentValues {
    /// Snapshot channel published by the surrounding `LiveNode`. Native
    /// representables hosted inside the `LiveNode` content closure read
    /// this value and use it to register capture handlers and push
    /// snapshots when their internal events (navigation finish, tile
    /// render) arrive.
    var liveNodeSnapshotContext: LiveNodeSnapshotContext? {
        get { self[LiveNodeSnapshotContextKey.self] }
        set { self[LiveNodeSnapshotContextKey.self] = newValue }
    }
}
