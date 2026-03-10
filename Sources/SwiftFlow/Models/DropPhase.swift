import Foundation

/// Identifies the element under the drag cursor during a drop interaction.
public enum DropTarget: Sendable, Equatable {
    /// Cursor is over the node with the given ID.
    case node(String)
    /// Cursor is over the edge with the given ID.
    case edge(String)
    /// Cursor is over the canvas background.
    case canvas
}

/// Phase of an external drop interaction on the canvas.
///
/// All locations are in canvas coordinates (converted from screen coordinates by the library).
/// NSItemProviders are available in both `updated` and `performed` phases,
/// allowing inspection of dragged content types during hover.
public enum DropPhase {

    /// A drag is hovering over the canvas.
    ///
    /// - Parameters:
    ///   - providers: The item providers for the dragged content.
    ///   - location: The drag location in canvas coordinates.
    ///   - target: The element under the cursor (node, edge, or background).
    case updated([NSItemProvider], CGPoint, DropTarget)

    /// The drag exited the canvas.
    case exited

    /// Items were dropped at the given location.
    ///
    /// - Parameters:
    ///   - providers: The item providers for the dropped content.
    ///   - location: The drop location in canvas coordinates.
    ///   - target: The element at the drop point (node, edge, or background).
    case performed([NSItemProvider], CGPoint, DropTarget)
}
