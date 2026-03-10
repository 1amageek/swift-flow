import CoreGraphics

public struct FlowNode<Data: Sendable & Hashable>: Identifiable, Sendable, Hashable {

    public let id: String
    public var position: CGPoint
    public var size: CGSize
    public var data: Data
    public var isSelected: Bool
    public var isHovered: Bool
    public var isDropTarget: Bool
    public var isDraggable: Bool
    public var zIndex: Int
    public var handles: [HandleDeclaration]

    public init(
        id: String,
        position: CGPoint,
        size: CGSize = CGSize(width: 150, height: 60),
        data: Data,
        isSelected: Bool = false,
        isDraggable: Bool = true,
        zIndex: Int = 0,
        handles: [HandleDeclaration] = [
            HandleDeclaration(id: "target", type: .target, position: .top),
            HandleDeclaration(id: "source", type: .source, position: .bottom),
        ]
    ) {
        self.id = id
        self.position = position
        self.size = size
        self.data = data
        self.isSelected = isSelected
        self.isHovered = false
        self.isDropTarget = false
        self.isDraggable = isDraggable
        self.zIndex = zIndex
        self.handles = handles
    }

    public var frame: CGRect {
        CGRect(origin: position, size: size)
    }
}

extension FlowNode: Codable where Data: Codable {

    private enum CodingKeys: String, CodingKey {
        case id, position, size, data, isSelected, isDraggable, zIndex, handles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        position = try container.decode(CGPoint.self, forKey: .position)
        size = try container.decode(CGSize.self, forKey: .size)
        data = try container.decode(Data.self, forKey: .data)
        isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected) ?? false
        isHovered = false
        isDropTarget = false
        isDraggable = try container.decodeIfPresent(Bool.self, forKey: .isDraggable) ?? true
        zIndex = try container.decodeIfPresent(Int.self, forKey: .zIndex) ?? 0
        handles = try container.decodeIfPresent([HandleDeclaration].self, forKey: .handles) ?? [
            HandleDeclaration(id: "target", type: .target, position: .top),
            HandleDeclaration(id: "source", type: .source, position: .bottom),
        ]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(position, forKey: .position)
        try container.encode(size, forKey: .size)
        try container.encode(data, forKey: .data)
        try container.encode(isSelected, forKey: .isSelected)
        try container.encode(isDraggable, forKey: .isDraggable)
        try container.encode(zIndex, forKey: .zIndex)
        try container.encode(handles, forKey: .handles)
    }
}
