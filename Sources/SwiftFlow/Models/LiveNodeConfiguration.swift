import SwiftUI

/// Bundle of policies that govern a single `LiveNode` instance.
///
/// `LiveNode` constructs this internally from its initializer arguments;
/// callers do not build it directly.
public struct LiveNodeConfiguration: Sendable {
    public var mountPolicy: LiveNodeMountPolicy

    public init(mountPolicy: LiveNodeMountPolicy = .onActivation) {
        self.mountPolicy = mountPolicy
    }

    public static let `default` = LiveNodeConfiguration()
}
