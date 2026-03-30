import CoreGraphics
import SwiftFlow
import Testing

@Suite("ConnectionDraft Public API")
struct ConnectionDraftPublicAPITests {

    @Test("ConnectionDraft can be constructed and assigned from public API")
    @MainActor
    func connectionDraftIsExternallyUsable() {
        let store = FlowStore<String>()
        let draft = ConnectionDraft(
            sourceNodeID: "n1",
            sourceHandleID: "out",
            sourceHandleType: .source,
            sourceHandlePosition: .right,
            targetNodeID: "n2",
            targetHandleID: "in",
            currentPoint: CGPoint(x: 120, y: 80)
        )

        store.connectionDraft = draft

        #expect(store.connectionDraft?.sourceNodeID == "n1")
        #expect(store.connectionDraft?.sourceHandleID == "out")
        #expect(store.connectionDraft?.targetNodeID == "n2")
        #expect(store.connectionDraft?.targetHandleID == "in")
        #expect(store.connectionDraft?.currentPoint == CGPoint(x: 120, y: 80))
    }
}
