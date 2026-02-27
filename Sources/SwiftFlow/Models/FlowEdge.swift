import Foundation

public struct FlowEdge: Identifiable, Sendable, Hashable, Codable {

    public let id: String
    public var sourceNodeID: String
    public var sourceHandleID: String?
    public var targetNodeID: String
    public var targetHandleID: String?
    public var pathType: EdgePathType
    public var isSelected: Bool
    public var label: String?
    public var isAnimated: Bool

    public init(
        id: String,
        sourceNodeID: String,
        sourceHandleID: String? = nil,
        targetNodeID: String,
        targetHandleID: String? = nil,
        pathType: EdgePathType = .bezier,
        isSelected: Bool = false,
        label: String? = nil,
        isAnimated: Bool = false
    ) {
        self.id = id
        self.sourceNodeID = sourceNodeID
        self.sourceHandleID = sourceHandleID
        self.targetNodeID = targetNodeID
        self.targetHandleID = targetHandleID
        self.pathType = pathType
        self.isSelected = isSelected
        self.label = label
        self.isAnimated = isAnimated
    }
}
