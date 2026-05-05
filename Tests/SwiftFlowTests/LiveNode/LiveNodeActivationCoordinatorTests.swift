import Testing
@testable import SwiftFlow

@Suite("LiveNodeActivationCoordinator Tests")
@MainActor
struct LiveNodeActivationCoordinatorTests {

    @Test("Atomic preferences replace scoped entries and preserve outside scope")
    func atomicPreferencesReplaceScopedEntriesAndPreserveOutsideScope() {
        let coordinator = LiveNodeActivationCoordinator()

        coordinator.applyPreferences(
            evaluated: ["a", "b"],
            present: ["a", "b"],
            policies: [
                "a": .persistent,
                "b": .remountOnActivation,
            ],
            storeNodeIDs: ["a", "b"]
        )

        #expect(coordinator.liveNodeIDs == ["a", "b"])
        #expect(coordinator.liveNodeMountPolicies["a"] == .persistent)
        #expect(coordinator.liveNodeMountPolicies["b"] == .remountOnActivation)

        coordinator.applyPreferences(
            evaluated: ["b"],
            present: [],
            policies: [:],
            storeNodeIDs: ["a", "b"]
        )

        #expect(coordinator.liveNodeIDs == ["a"])
        #expect(coordinator.liveNodeMountPolicies["a"] == .persistent)
        #expect(coordinator.liveNodeMountPolicies["b"] == nil)

        coordinator.applyPreferences(
            evaluated: ["a", "b"],
            present: ["b"],
            policies: ["b": .persistent],
            storeNodeIDs: ["a", "b"]
        )

        #expect(coordinator.liveNodeIDs == ["b"])
        #expect(coordinator.liveNodeMountPolicies["a"] == nil)
        #expect(coordinator.liveNodeMountPolicies["b"] == .persistent)
    }
}
