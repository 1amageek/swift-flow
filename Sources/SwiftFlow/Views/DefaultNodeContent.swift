import SwiftUI

/// Default node view:
/// - Clean card with title centered
/// - Handles protruding on the node border
public struct DefaultNodeContent<NodeData: Sendable & Hashable>: View {

    public let node: FlowNode<NodeData>
    public let context: NodeRenderContext

    static var handleInset: CGFloat { FlowHandle.diameter / 2 }

    public init(node: FlowNode<NodeData>, context: NodeRenderContext) {
        self.node = node
        self.context = context
    }

    public var body: some View {
        let inset = Self.handleInset

        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(fillStyle)
                .shadow(color: shadowColor, radius: 1, y: 1)
                .shadow(
                    color: emphasisShadowColor,
                    radius: emphasisShadowRadius,
                    y: emphasisShadowYOffset
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            borderColor,
                            style: StrokeStyle(lineWidth: borderLineWidth, dash: borderDash)
                        )
                }
                .overlay {
                    Text(String(describing: node.data))
                        .font(.system(.subheadline, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
                .padding(inset)

            FlowNodeHandles(node: node, context: context)
        }
        .frame(width: node.size.width + inset * 2, height: node.size.height + inset * 2)
        .opacity(contentOpacity)
    }

    private var fillStyle: AnyShapeStyle {
        switch node.phase {
        case .normal:
            return AnyShapeStyle(.background)
        case .draft(.neutral):
            return AnyShapeStyle(Color.secondary.opacity(0.08))
        case .draft(.valid):
            return AnyShapeStyle(Color.accentColor.opacity(0.08))
        case .draft(.invalid):
            return AnyShapeStyle(Color.red.opacity(0.08))
        }
    }

    private var shadowColor: Color {
        switch node.phase {
        case .draft:
            return .clear
        case .normal:
            return .black.opacity(0.06)
        }
    }

    private var emphasisShadowColor: Color {
        switch node.phase {
        case .normal:
            if node.isSelected { return Color.accentColor.opacity(0.35) }
            if node.isHovered { return .black.opacity(0.14) }
            return .black.opacity(0.08)
        case .draft(.neutral):
            return Color.secondary.opacity(0.12)
        case .draft(.valid):
            return Color.accentColor.opacity(0.28)
        case .draft(.invalid):
            return Color.red.opacity(0.22)
        }
    }

    private var emphasisShadowRadius: CGFloat {
        switch node.phase {
        case .normal:
            if node.isSelected { return 8 }
            if node.isHovered { return 5 }
            return 3
        case .draft:
            return 0
        }
    }

    private var emphasisShadowYOffset: CGFloat {
        switch node.phase {
        case .normal:
            if node.isSelected { return 0 }
            if node.isHovered { return 1 }
            return 2
        case .draft:
            return 0
        }
    }

    private var borderColor: Color {
        switch node.phase {
        case .normal:
            if node.isSelected { return .accentColor }
            if node.isHovered { return Color.primary.opacity(0.25) }
            return Color.primary.opacity(0.12)
        case .draft(.neutral):
            return Color.secondary.opacity(0.45)
        case .draft(.valid):
            return Color.accentColor.opacity(0.8)
        case .draft(.invalid):
            return Color.red.opacity(0.8)
        }
    }

    private var borderLineWidth: CGFloat {
        switch node.phase {
        case .normal:
            if node.isSelected { return 1.5 }
            if node.isHovered { return 0.75 }
            return 0.5
        case .draft:
            return 1.25
        }
    }

    private var borderDash: [CGFloat] {
        switch node.phase {
        case .normal:
            return []
        case .draft:
            return [6, 4]
        }
    }

    private var contentOpacity: CGFloat {
        switch node.phase {
        case .normal:
            return 1
        case .draft(.neutral):
            return 0.76
        case .draft(.valid):
            return 0.9
        case .draft(.invalid):
            return 0.85
        }
    }

}
