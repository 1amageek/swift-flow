/// Target that receives keyboard-directed flow actions.
///
/// Focus is intentionally separate from selection and hover. A node can be
/// hovered without focus, and a selected node can lose focus when keyboard
/// routing moves elsewhere.
public enum FlowFocusTarget: Hashable, Sendable {
    case node(String)
    case edge(String)
}
