import SwiftUI

/// Bundle of mount + snapshot policies that flow through the SwiftUI
/// environment to every `LiveNode` in a subtree.
///
/// Apply via the View modifiers ``SwiftUI/View/liveNodeMount(_:)`` and
/// ``SwiftUI/View/liveNodeSnapshot(_:)`` rather than constructing directly.
public struct LiveNodeConfiguration: Sendable, Hashable {
    public var mountPolicy: LiveNodeMountPolicy
    public var snapshotPolicy: LiveNodeSnapshotPolicy

    public init(
        mountPolicy: LiveNodeMountPolicy = .onActivation,
        snapshotPolicy: LiveNodeSnapshotPolicy = .automatic
    ) {
        self.mountPolicy = mountPolicy
        self.snapshotPolicy = snapshotPolicy
    }

    public static let `default` = LiveNodeConfiguration()
}

private struct LiveNodeConfigurationKey: EnvironmentKey {
    static let defaultValue = LiveNodeConfiguration.default
}

public extension EnvironmentValues {
    var liveNodeConfiguration: LiveNodeConfiguration {
        get { self[LiveNodeConfigurationKey.self] }
        set { self[LiveNodeConfigurationKey.self] = newValue }
    }
}

public extension View {
    /// Controls when the live subtree is mounted, kept alive, or recreated.
    func liveNodeMount(_ policy: LiveNodeMountPolicy) -> some View {
        transformEnvironment(\.liveNodeConfiguration) { configuration in
            configuration.mountPolicy = policy
        }
    }

    /// Controls how and when snapshots are captured.
    func liveNodeSnapshot(_ policy: LiveNodeSnapshotPolicy) -> some View {
        transformEnvironment(\.liveNodeConfiguration) { configuration in
            configuration.snapshotPolicy = policy
        }
    }
}
