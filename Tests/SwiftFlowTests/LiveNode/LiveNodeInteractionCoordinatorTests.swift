import Testing
@testable import SwiftFlow

@Suite("LiveNodeInteractionCoordinator Tests")
@MainActor
struct LiveNodeInteractionCoordinatorTests {

    @Test("Atomic preferences replace scoped entries and preserve outside scope")
    func atomicPreferencesReplaceScopedEntriesAndPreserveOutsideScope() {
        let coordinator = LiveNodeInteractionCoordinator()

        coordinator.applyPreferences(
            evaluated: ["a", "b"],
            present: ["a", "b"],
            policies: [
                "a": .persistent,
                "b": .onInteraction,
            ],
            storeNodeIDs: ["a", "b"]
        )

        #expect(coordinator.liveNodeIDs == ["a", "b"])
        #expect(coordinator.liveNodeMountPolicies["a"] == .persistent)
        #expect(coordinator.liveNodeMountPolicies["b"] == .onInteraction)

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
