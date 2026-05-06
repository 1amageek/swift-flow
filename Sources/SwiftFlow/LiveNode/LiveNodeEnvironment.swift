import CoreGraphics
import SwiftUI

/// Lightweight, non-generic snapshot of the surrounding `FlowNode` used
/// by `LiveNode` to operate without knowing the host store's `NodeData`
/// generic.
///
/// `FlowCanvas` injects this value through the SwiftUI environment every
/// time it evaluates `nodeContent`, so any `LiveNode` placed inside the
/// node body can recover the node's identity, size, and current snapshot
/// without taking them as initializer arguments.
public struct LiveNodeEnvironment: Sendable, Hashable {
    public let id: String
    public let size: CGSize
    public let snapshot: FlowNodeSnapshot?

    public init(
        id: String,
        size: CGSize,
        snapshot: FlowNodeSnapshot?
    ) {
        self.id = id
        self.size = size
        self.snapshot = snapshot
    }
}

private struct LiveNodeEnvironmentKey: EnvironmentKey {
    static let defaultValue: LiveNodeEnvironment? = nil
}

public extension EnvironmentValues {
    /// Identity, size, and snapshot of the surrounding `FlowNode`.
    /// Populated by `FlowCanvas` for each `nodeContent` evaluation; `nil`
    /// when read outside a Flow node body.
    var liveNodeEnvironment: LiveNodeEnvironment? {
        get { self[LiveNodeEnvironmentKey.self] }
        set { self[LiveNodeEnvironmentKey.self] = newValue }
    }
}

/// Type-erased subset of `FlowNode` that `LiveNode` needs to operate
/// without exposing the host store's `NodeData` generic.
///
/// `LiveNode(node:)` extracts a descriptor from the surrounding
/// `FlowNode<Data>` and uses it to override the environment-injected
/// identity / size when `FlowCanvas` is not the source of truth (e.g.
/// when `LiveNode` is used outside a flow body, or when the developer
/// wants to bind a `LiveNode` to a node value explicitly).
public struct LiveNodeDescriptor: Sendable, Hashable {
    public let id: String
    public let size: CGSize

    public init(id: String, size: CGSize) {
        self.id = id
        self.size = size
    }

    public init<Data>(node: FlowNode<Data>) where Data: Sendable & Hashable {
        self.id = node.id
        self.size = node.size
    }
}

/// Read-only context passed to a `LiveNode` content closure.
///
/// Use the `(LiveNodeContentContext) -> Content` initializer when the
/// content view needs to react to the node's own interaction state — for
/// example to gate hit testing on `live.isInteractive`.
public struct LiveNodeContentContext: Sendable, Hashable {
    public let id: String
    public let size: CGSize
    public let snapshot: FlowNodeSnapshot?
    public let isInteractive: Bool

    public init(
        id: String,
        size: CGSize,
        snapshot: FlowNodeSnapshot?,
        isInteractive: Bool
    ) {
        self.id = id
        self.size = size
        self.snapshot = snapshot
        self.isInteractive = isInteractive
    }
}
