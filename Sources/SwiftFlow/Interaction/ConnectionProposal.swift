import Foundation

public struct ConnectionProposal: Sendable, Hashable {

    public var sourceNodeID: String
    public var sourceHandleID: String?
    public var targetNodeID: String
    public var targetHandleID: String?

    public init(
        sourceNodeID: String,
        sourceHandleID: String? = nil,
        targetNodeID: String,
        targetHandleID: String? = nil
    ) {
        self.sourceNodeID = sourceNodeID
        self.sourceHandleID = sourceHandleID
        self.targetNodeID = targetNodeID
        self.targetHandleID = targetHandleID
    }
}
