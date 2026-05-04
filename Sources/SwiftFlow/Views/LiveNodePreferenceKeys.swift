import SwiftUI

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
/// decide whether to mount a row only on activation, keep it persistent,
/// or remount it when activation begins.
public struct LiveNodeMountPolicyKey: PreferenceKey {
    public static let defaultValue: [String: LiveNodeMountPolicy] = [:]

    public static func reduce(
        value: inout [String: LiveNodeMountPolicy],
        nextValue: () -> [String: LiveNodeMountPolicy]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}
