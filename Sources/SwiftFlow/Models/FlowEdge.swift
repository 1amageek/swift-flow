import Foundation

public struct FlowEdge: Identifiable, Sendable, Hashable, Codable {

    public let id: String
    public var sourceNodeID: String
    public var sourceHandleID: String?
    public var targetNodeID: String
    public var targetHandleID: String?
    public var pathType: EdgePathType
    public var isSelected: Bool
    public var isDropTarget: Bool
    public var label: String?

    public init(
        id: String,
        sourceNodeID: String,
        sourceHandleID: String? = nil,
        targetNodeID: String,
        targetHandleID: String? = nil,
        pathType: EdgePathType = .bezier,
        isSelected: Bool = false,
        label: String? = nil
    ) {
        self.id = id
        self.sourceNodeID = sourceNodeID
        self.sourceHandleID = sourceHandleID
        self.targetNodeID = targetNodeID
        self.targetHandleID = targetHandleID
        self.pathType = pathType
        self.isSelected = isSelected
        self.isDropTarget = false
        self.label = label
    }
}

extension FlowEdge {

    private enum CodingKeys: String, CodingKey {
        case id, sourceNodeID, sourceHandleID, targetNodeID, targetHandleID, pathType, isSelected, label
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceNodeID = try container.decode(String.self, forKey: .sourceNodeID)
        sourceHandleID = try container.decodeIfPresent(String.self, forKey: .sourceHandleID)
        targetNodeID = try container.decode(String.self, forKey: .targetNodeID)
        targetHandleID = try container.decodeIfPresent(String.self, forKey: .targetHandleID)
        pathType = try container.decodeIfPresent(EdgePathType.self, forKey: .pathType) ?? .bezier
        isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected) ?? false
        isDropTarget = false
        label = try container.decodeIfPresent(String.self, forKey: .label)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceNodeID, forKey: .sourceNodeID)
        try container.encodeIfPresent(sourceHandleID, forKey: .sourceHandleID)
        try container.encode(targetNodeID, forKey: .targetNodeID)
        try container.encodeIfPresent(targetHandleID, forKey: .targetHandleID)
        try container.encode(pathType, forKey: .pathType)
        try container.encode(isSelected, forKey: .isSelected)
        try container.encodeIfPresent(label, forKey: .label)
    }
}
