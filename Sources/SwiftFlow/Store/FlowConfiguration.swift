import Foundation

public struct FlowConfiguration: Sendable {

    public var defaultEdgePathType: EdgePathType
    public var edgeStyle: EdgeStyle
    public var snapToGrid: Bool
    public var gridSize: CGFloat
    public var minZoom: CGFloat
    public var maxZoom: CGFloat
    public var connectionValidator: (any ConnectionValidating)?
    public var panEnabled: Bool
    public var zoomEnabled: Bool
    public var selectionEnabled: Bool
    public var multiSelectionEnabled: Bool

    public init(
        defaultEdgePathType: EdgePathType = .bezier,
        edgeStyle: EdgeStyle = EdgeStyle(),
        snapToGrid: Bool = false,
        gridSize: CGFloat = 20,
        minZoom: CGFloat = 0.1,
        maxZoom: CGFloat = 4.0,
        connectionValidator: (any ConnectionValidating)? = nil,
        panEnabled: Bool = true,
        zoomEnabled: Bool = true,
        selectionEnabled: Bool = true,
        multiSelectionEnabled: Bool = true
    ) {
        self.defaultEdgePathType = defaultEdgePathType
        self.edgeStyle = edgeStyle
        self.snapToGrid = snapToGrid
        self.gridSize = gridSize
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.connectionValidator = connectionValidator
        self.panEnabled = panEnabled
        self.zoomEnabled = zoomEnabled
        self.selectionEnabled = selectionEnabled
        self.multiSelectionEnabled = multiSelectionEnabled
    }

    func snapped(_ point: CGPoint) -> CGPoint {
        guard snapToGrid else { return point }
        return CGPoint(
            x: (point.x / gridSize).rounded() * gridSize,
            y: (point.y / gridSize).rounded() * gridSize
        )
    }
}
