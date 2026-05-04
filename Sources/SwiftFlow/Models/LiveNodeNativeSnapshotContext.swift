import SwiftUI

/// Environment value exposed to native-backed node content.
///
/// A `UIViewRepresentable` / `NSViewRepresentable` can use this context to:
///
/// - write a ready-driven snapshot when the native view becomes meaningful
/// - register a capture handler that `LiveNode` calls before deactivation
/// - request a capture manually
///
/// Example shape:
///
/// ```swift
/// struct WebViewNode: UIViewRepresentable {
///     @Environment(\.liveNodeNativeSnapshotContext) private var snapshotContext
///
///     func updateUIView(_ webView: WKWebView, context: Context) {
///         snapshotContext?.registerCapture {
///             await webView.makeFlowNodeSnapshot()
///         }
///     }
/// }
/// ```
public struct LiveNodeNativeSnapshotContext: Sendable {
    public let nodeID: String

    public let write: @MainActor (FlowNodeSnapshot) -> Void

    public let registerCapture: @MainActor (
        @escaping @MainActor () async -> FlowNodeSnapshot?
    ) -> Void

    public let unregisterCapture: @MainActor () -> Void

    public let requestCapture: @MainActor () async -> Void
}

private struct LiveNodeNativeSnapshotContextKey: EnvironmentKey {
    static let defaultValue: LiveNodeNativeSnapshotContext? = nil
}

public extension EnvironmentValues {
    var liveNodeNativeSnapshotContext: LiveNodeNativeSnapshotContext? {
        get { self[LiveNodeNativeSnapshotContextKey.self] }
        set { self[LiveNodeNativeSnapshotContextKey.self] = newValue }
    }
}
