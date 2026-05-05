public struct HandleDeclaration: Sendable, Hashable, Codable {

    public let id: String
    public let type: HandleType
    public let position: HandlePosition

    public init(id: String, type: HandleType, position: HandlePosition) {
        self.id = id
        self.type = type
        self.position = position
    }
}
