import SwiftUI

/// Bundle of mount, snapshot, and capture policies that govern a single
/// `LiveNode` instance.
///
/// `LiveNode` constructs this internally from its initializer arguments;
/// callers do not build it directly.
public struct LiveNodeConfiguration: Sendable {
    public var mountPolicy: LiveNodeMountPolicy
    public var snapshotPolicy: LiveNodeSnapshotPolicy
    public var capture: LiveNodeCapture

    public init(
        mountPolicy: LiveNodeMountPolicy = .onActivation,
        snapshotPolicy: LiveNodeSnapshotPolicy = .automatic,
        capture: LiveNodeCapture = .auto
    ) {
        self.mountPolicy = mountPolicy
        self.snapshotPolicy = snapshotPolicy
        self.capture = capture
    }

    public static let `default` = LiveNodeConfiguration()
}
