import SwiftUI

/// Collects IDs of every node whose `nodeContent` was evaluated this
/// preference cycle. Emitted by the overlay's registrar pass for every
/// node in the store, regardless of whether the body contains a
/// `LiveNode`. Pairs with ``LiveNodePresenceKey`` to bound presence
/// updates: within the evaluated scope, presence is authoritative
/// (assignment, not merge); outside the scope, prior decisions carry
/// over. This is what stops a `LiveNode` that conditionally evaluates
/// to `false` from leaving its id permanently in `liveNodeIDs`.
public struct EvaluatedNodeIDsKey: PreferenceKey {
    public static let defaultValue: Set<String> = []

    public static func reduce(
        value: inout Set<String>,
        nextValue: () -> Set<String>
    ) {
        value.formUnion(nextValue())
    }
}

/// Collects IDs of nodes whose `nodeContent` contains a `LiveNode`.
public struct LiveNodePresenceKey: PreferenceKey {
    public static let defaultValue: Set<String> = []

    public static func reduce(
        value: inout Set<String>,
        nextValue: () -> Set<String>
    ) {
        value.formUnion(nextValue())
    }
}

/// Aggregates per-node mount policies so the overlay/coordinator can
/// decide whether to mount a row only on interaction or keep it
/// persistent.
public struct LiveNodeMountPolicyKey: PreferenceKey {
    public static let defaultValue: [String: LiveNodeMountPolicy] = [:]

    public static func reduce(
        value: inout [String: LiveNodeMountPolicy],
        nextValue: () -> [String: LiveNodeMountPolicy]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}
