/// Short-lived operation currently owning flow interaction.
///
/// This is not selection. It describes what the user is doing right now so
/// rendering and tools can distinguish a selected item from an item being
/// dragged, connected, resized, or edited.
public enum FlowActiveInteraction: Hashable, Sendable {
    case draggingNodes(Set<String>)
    case connecting(sourceNodeID: String, sourceHandleID: String?)
    case selectingRect
    case resizingNodes(Set<String>)
    case editingText(nodeID: String)
}
