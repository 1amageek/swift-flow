public struct HandleDeclaration: Sendable, Hashable, Codable {

    public let id: String
    public let type: HandleType
    public let position: HandlePosition
    public let connectionStartArea: HandleHitArea?
    public let connectionTargetArea: HandleHitArea?

    public init(
        id: String,
        type: HandleType,
        position: HandlePosition,
        connectionStartArea: HandleHitArea? = nil,
        connectionTargetArea: HandleHitArea? = nil
    ) {
        self.id = id
        self.type = type
        self.position = position
        self.connectionStartArea = connectionStartArea
        self.connectionTargetArea = connectionTargetArea
    }
}
