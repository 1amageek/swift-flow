import CoreGraphics

public struct FlowNode<Data: Sendable & Hashable>: Identifiable, Sendable, Hashable {

    public let id: String
    public var position: CGPoint
    public var size: CGSize
    public var data: Data
    public var isSelected: Bool
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
        self.isDraggable = isDraggable
        self.zIndex = zIndex
        self.handles = handles
    }

    public var frame: CGRect {
        CGRect(origin: position, size: size)
    }
}

extension FlowNode: Codable where Data: Codable {}
