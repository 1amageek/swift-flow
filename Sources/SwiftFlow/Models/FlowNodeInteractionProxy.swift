import CoreGraphics
import SwiftUI

/// Per-node bridge that lets node-chrome views (drag handles, headers,
/// future shells) drive the host store without taking a generic
/// `FlowStore<NodeData>` reference.
///
/// `FlowCanvas` builds one of these for every node it evaluates and
/// publishes it through the SwiftUI environment. Views like
/// ``FlowNodeDragHandle`` read `\.flowNodeInteraction` and call the
/// closures, so they can implement local gestures (drag-to-move,
/// tap-to-select) without knowing how the store is wired up.
///
/// Move semantics mirror what the central canvas drag gesture does for
/// rasterized nodes:
///
/// 1. ``beginMove`` snapshots the start positions of every node that
///    should follow the drag (the dragged node alone, or the whole
///    selection if the dragged node is part of a multi-selection).
/// 2. ``updateMove`` applies the screen-space translation, dividing by
///    the current viewport zoom so cursor distance and node distance
///    stay aligned.
/// 3. ``endMove`` finalizes the drag — registers it as one undoable
///    operation via `FlowStore.completeMoveNodes`.
public struct FlowNodeInteractionProxy: Sendable {
    public let nodeID: String

    public let beginMove: @MainActor () -> [String: CGPoint]
    public let updateMove: @MainActor (_ startPositions: [String: CGPoint], _ translation: CGSize) -> Void
    public let endMove: @MainActor (_ startPositions: [String: CGPoint]) -> Void

    public let selectNode: @MainActor (_ additive: Bool) -> Void

    public init(
        nodeID: String,
        beginMove: @escaping @MainActor () -> [String: CGPoint],
        updateMove: @escaping @MainActor (_ startPositions: [String: CGPoint], _ translation: CGSize) -> Void,
        endMove: @escaping @MainActor (_ startPositions: [String: CGPoint]) -> Void,
        selectNode: @escaping @MainActor (_ additive: Bool) -> Void
    ) {
        self.nodeID = nodeID
        self.beginMove = beginMove
        self.updateMove = updateMove
        self.endMove = endMove
        self.selectNode = selectNode
    }
}

private struct FlowNodeInteractionProxyKey: EnvironmentKey {
    static let defaultValue: FlowNodeInteractionProxy? = nil
}

public extension EnvironmentValues {
    /// Per-node interaction bridge published by `FlowCanvas`. `nil` when
    /// read outside a Flow node body.
    var flowNodeInteraction: FlowNodeInteractionProxy? {
        get { self[FlowNodeInteractionProxyKey.self] }
        set { self[FlowNodeInteractionProxyKey.self] = newValue }
    }
}
