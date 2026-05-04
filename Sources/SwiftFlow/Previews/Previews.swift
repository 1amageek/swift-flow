#if DEBUG

import SwiftUI
import UniformTypeIdentifiers
import WebKit
import MapKit

// MARK: - Generic Preview

/// Data model for preview nodes.
private struct PreviewNodeData: Sendable, Hashable, Codable {
    let title: String
    let category: String
    let icon: String
    var badge: String?
    var subtitle: String?
}

/// Unified draggable payload. Uses `public.json` (a well-known system UTType)
/// so that the pasteboard, registerForDraggedTypes, and NSItemProvider all
/// work without custom UTType registration in Info.plist.
/// The `kind` field discriminates the three item categories.
private struct DragPayload: Sendable, Hashable, Codable, Transferable {
    enum Kind: String, Codable {
        case nodeTemplate
        case nodeAttribute
        case edgeAttribute
    }

    let kind: Kind
    let title: String
    let subtitle: String?
    let icon: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

private struct PreviewNode: View {

    let node: FlowNode<PreviewNodeData>
    let context: NodeRenderContext
    static var handleInset: CGFloat { FlowHandle.diameter / 2 }

    init(node: FlowNode<PreviewNodeData>, context: NodeRenderContext) {
        self.node = node
        self.context = context
    }

    var body: some View {
        let inset = Self.handleInset

        ZStack {
            card.padding(inset)

            ForEach(node.handles, id: \.id) { handle in
                FlowHandle(handle.id, type: handle.type, position: handle.position)
                    .overlay {
                        if context.connectedHandleID == handle.id {
                            Circle()
                                .strokeBorder(handleHighlightColor, lineWidth: 2)
                                .padding(-4)
                        }
                    }
                    .scaleEffect(context.connectedHandleID == handle.id ? 1.15 : 1.0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: handleAlignment(handle.position))
            }
        }
        .frame(width: node.size.width + inset * 2, height: node.size.height + inset * 2)
        .opacity(cardOpacity)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(cardFillStyle)
            .shadow(color: baseShadowColor, radius: 1, y: 1)
            .shadow(
                color: focusShadowColor,
                radius: focusShadowRadius,
                y: focusShadowYOffset
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(borderColor, style: StrokeStyle(lineWidth: borderLineWidth, dash: borderDash))
            }
            .overlay(alignment: .leading) { cardContent }
            .scaleEffect(node.isDropTarget ? 1.04 : 1.0)
            .animation(.spring(duration: 0.2), value: node.isDropTarget)
    }

    @ViewBuilder
    private var cardContent: some View {
        switch node.data.category {
        case "Trigger":
            triggerContent
        case "Logic":
            logicContent
        case "Network":
            networkContent
        case "Output":
            outputContent
        default:
            standardContent
        }
    }

    private var triggerContent: some View {
        HStack(spacing: 10) {
            iconView
            Text(node.data.title)
                .font(.system(.subheadline, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
                .overlay { Circle().stroke(.green.opacity(0.4), lineWidth: 2) }
        }
        .padding(.horizontal, 10)
    }

    private var logicContent: some View {
        VStack(spacing: 2) {
            Image(systemName: node.data.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(categoryColor)
            Text(node.data.title)
                .font(.system(.caption, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var networkContent: some View {
        HStack(spacing: 10) {
            iconView
            VStack(alignment: .leading, spacing: 1) {
                Text(node.data.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if let subtitle = node.data.subtitle {
                    Text(subtitle)
                        .font(.system(.caption2, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let badge = node.data.badge {
                Text(badge)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(categoryColor, in: Capsule())
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
    }

    private var outputContent: some View {
        HStack(spacing: 10) {
            iconView
            Text(node.data.title)
                .font(.system(.subheadline, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            if let badge = node.data.badge {
                Text(badge)
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(categoryColor, in: Circle())
            }
        }
        .padding(.horizontal, 10)
    }

    private var standardContent: some View {
        HStack(spacing: 10) {
            iconView
            VStack(alignment: .leading, spacing: 1) {
                Text(node.data.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(node.data.subtitle ?? node.data.category)
                    .font(.system(.caption2))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
    }

    private var iconView: some View {
        Image(systemName: node.data.icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(categoryColor, in: RoundedRectangle(cornerRadius: 7))
    }

    private var categoryColor: Color {
        switch node.data.category {
        case "Trigger":   .orange
        case "Security":  .red
        case "Logic":     .pink
        case "Data":      .blue
        case "Transform": .teal
        case "Storage":   .indigo
        case "Network":   .cyan
        case "Queue":     .brown
        case "Output":    .green
        default:          .gray
        }
    }

    private var cardFillStyle: AnyShapeStyle {
        switch node.phase {
        case .normal:
            return node.isDropTarget
                ? AnyShapeStyle(Color.accentColor.opacity(0.08))
                : AnyShapeStyle(.background)
        case .draft(.neutral):
            return AnyShapeStyle(categoryColor.opacity(0.08))
        case .draft(.valid):
            return AnyShapeStyle(Color.accentColor.opacity(0.12))
        case .draft(.invalid):
            return AnyShapeStyle(Color.red.opacity(0.1))
        }
    }

    private var baseShadowColor: Color {
        switch node.phase {
        case .normal:
            return .black.opacity(0.06)
        case .draft:
            return .clear
        }
    }

    private var focusShadowColor: Color {
        switch node.phase {
        case .normal:
            if node.isDropTarget { return Color.accentColor.opacity(0.5) }
            if node.isSelected { return Color.accentColor.opacity(0.4) }
            if node.isHovered { return .black.opacity(0.14) }
            return .black.opacity(0.08)
        case .draft(.neutral):
            return categoryColor.opacity(0.18)
        case .draft(.valid):
            return Color.accentColor.opacity(0.26)
        case .draft(.invalid):
            return Color.red.opacity(0.22)
        }
    }

    private var focusShadowRadius: CGFloat {
        switch node.phase {
        case .normal:
            if node.isDropTarget { return 10 }
            if node.isSelected { return 8 }
            if node.isHovered { return 5 }
            return 3
        case .draft:
            return 0
        }
    }

    private var focusShadowYOffset: CGFloat {
        switch node.phase {
        case .normal:
            if node.isDropTarget || node.isSelected { return 0 }
            if node.isHovered { return 1 }
            return 2
        case .draft:
            return 0
        }
    }

    private var borderColor: Color {
        switch node.phase {
        case .normal:
            if node.isDropTarget || node.isSelected { return .accentColor }
            if node.isHovered { return Color.primary.opacity(0.25) }
            return Color.primary.opacity(0.1)
        case .draft(.neutral):
            return categoryColor.opacity(0.5)
        case .draft(.valid):
            return Color.accentColor.opacity(0.85)
        case .draft(.invalid):
            return Color.red.opacity(0.85)
        }
    }

    private var borderLineWidth: CGFloat {
        switch node.phase {
        case .normal:
            if node.isDropTarget { return 2.0 }
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
            return [7, 4]
        }
    }

    private var cardOpacity: CGFloat {
        switch node.phase {
        case .normal:
            return 1
        case .draft(.neutral):
            return 0.78
        case .draft(.valid):
            return 0.92
        case .draft(.invalid):
            return 0.86
        }
    }

    private var handleHighlightColor: Color {
        switch node.phase {
        case .draft(.invalid):
            return .red
        case .draft(.neutral), .draft(.valid), .normal:
            return .accentColor
        }
    }

    private func handleAlignment(_ position: HandlePosition) -> Alignment {
        switch position {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }
}

@MainActor
@Observable
private final class PreviewInteractionState {
    var lastEvent: String = "Double-tap the canvas, drag into Notify to reject, or inject a draft node."
    var lastCanvasDoubleTap: String = "Not yet"
    var lastRejectedConnection: String = "Drag any output into Notify"
    var draftStatus: String = "Hidden"
    var draftTarget: String = "No target"
    var edgePathStyle: String = "Bezier"
}

private struct PreviewConnectionValidator: ConnectionValidating {
    func validate(_ proposal: ConnectionProposal) -> Bool {
        guard DefaultConnectionValidator().validate(proposal) else { return false }
        return proposal.targetNodeID != "notify" || proposal.sourceNodeID == "format"
    }
}

private struct PreviewStatusPanel: View {
    let interaction: PreviewInteractionState
    let toggleDraft: () -> Void
    let cycleDraftState: () -> Void
    let toggleDraftTarget: () -> Void
    let commitDraft: () -> Void
    let cycleEdgePathStyle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview Checks")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Text(interaction.lastEvent)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(3)

            statusRow("Canvas Double-Tap", interaction.lastCanvasDoubleTap)
            statusRow("Rejected Connection", interaction.lastRejectedConnection)
            statusRow("Draft Node", interaction.draftStatus)
            statusRow("Draft Target", interaction.draftTarget)
            statusRow("Edge Path", interaction.edgePathStyle)

            HStack(spacing: 6) {
                Button(action: toggleDraft) {
                    Label(
                        interaction.draftStatus == "Hidden" ? "Inject" : "Clear",
                        systemImage: interaction.draftStatus == "Hidden" ? "plus.circle" : "xmark.circle"
                    )
                    .font(.caption2)
                }
                .buttonStyle(.bordered)

                Button(action: cycleDraftState) {
                    Label("State", systemImage: "paintpalette")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .disabled(interaction.draftStatus == "Hidden")

                Button(action: toggleDraftTarget) {
                    Label("Target", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .disabled(interaction.draftStatus == "Hidden")
            }
            .controlSize(.small)

            Button(action: commitDraft) {
                Label("Commit", systemImage: "checkmark.circle")
                    .font(.caption2)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(interaction.draftStatus == "Hidden" || interaction.draftStatus.hasPrefix("Normal"))

            Button(action: cycleEdgePathStyle) {
                Label("Path", systemImage: "arrow.triangle.swap")
                    .font(.caption2)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            statusRow("Handle", "\(Int(FlowHandle.diameter))pt")
            statusRow("Platform", platformNote)
        }
        .padding(10)
        .frame(width: 220, alignment: .leading)
    }

    private var platformNote: String {
        #if os(macOS)
        "Command-click multi-select available"
        #else
        "iOS build excludes command-click path"
        #endif
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
    }
}

private func previewPointText(_ point: CGPoint) -> String {
    "x: \(Int(point.x.rounded())), y: \(Int(point.y.rounded()))"
}

private func previewProposalText(_ proposal: ConnectionProposal) -> String {
    "\(proposal.sourceNodeID) -> \(proposal.targetNodeID)"
}

private let previewDraftNodeID = "draft-preview"

private func previewDraftPhaseText(_ phase: FlowNodePhase?) -> String {
    guard let phase else { return "Hidden" }
    switch phase {
    case .normal:
        return "Normal"
    case .draft(.neutral):
        return "Neutral"
    case .draft(.valid):
        return "Valid"
    case .draft(.invalid):
        return "Invalid"
    }
}

private func previewDraftTargetText(_ targetHandleID: String?) -> String {
    if let targetHandleID {
        return "Handle \(targetHandleID)"
    }
    return "Free point"
}

private func previewDraftStatusText(_ node: FlowNode<PreviewNodeData>?) -> String {
    guard let node else { return "Hidden" }
    let scope = node.persistence == .persistent ? "Persistent" : "Transient"
    return "\(previewDraftPhaseText(node.phase)) · \(scope)"
}

private func previewEdgePathStyleText(_ pathType: EdgePathType) -> String {
    switch pathType {
    case .bezier:
        return "Bezier"
    case .straight:
        return "Straight"
    case .smoothStep:
        return "Right Angle"
    case .simpleBezier:
        return "Simple Bezier"
    }
}

private func previewNextEdgePathType(after pathType: EdgePathType) -> EdgePathType {
    switch pathType {
    case .bezier:
        return .straight
    case .straight:
        return .smoothStep
    case .smoothStep:
        return .simpleBezier
    case .simpleBezier:
        return .bezier
    }
}

private func makePreviewDraftNode(phase: FlowNodePhase) -> FlowNode<PreviewNodeData> {
    FlowNode(
        id: previewDraftNodeID,
        position: CGPoint(x: 660, y: 430),
        size: CGSize(width: 160, height: 50),
        data: PreviewNodeData(
            title: "Review Draft",
            category: "Network",
            icon: "wand.and.stars",
            badge: "TMP",
            subtitle: "Transient node"
        ),
        phase: phase,
        persistence: .transient,
        handles: [
            HandleDeclaration(id: "in", type: .target, position: .left),
            HandleDeclaration(id: "out", type: .source, position: .right),
        ]
    )
}

#Preview("FlowCanvas") {
    @Previewable @State var store: FlowStore<PreviewNodeData> = {
        let hOut: [HandleDeclaration] = [
            HandleDeclaration(id: "out", type: .source, position: .right),
        ]
        let hIn: [HandleDeclaration] = [
            HandleDeclaration(id: "in", type: .target, position: .left),
        ]
        let hLR: [HandleDeclaration] = [
            HandleDeclaration(id: "in", type: .target, position: .left),
            HandleDeclaration(id: "out", type: .source, position: .right),
        ]

        let s = CGSize(width: 160, height: 50)

        func n(_ id: String, x: CGFloat, y: CGFloat, title: String, category: String, icon: String, handles: [HandleDeclaration] = hLR, badge: String? = nil, subtitle: String? = nil) -> FlowNode<PreviewNodeData> {
            FlowNode(id: id, position: CGPoint(x: x, y: y), size: s, data: PreviewNodeData(title: title, category: category, icon: icon, badge: badge, subtitle: subtitle), handles: handles)
        }

        let store = FlowStore<PreviewNodeData>(
            nodes: [
                // Entry
                n("webhook", x: 30,   y: 200, title: "Webhook",   category: "Trigger",   icon: "bolt.fill",             handles: hOut),
                n("auth",    x: 240,  y: 200, title: "Auth",      category: "Security",  icon: "lock.fill",             subtitle: "OAuth 2.0"),
                n("router",  x: 450,  y: 200, title: "Router",    category: "Logic",     icon: "arrow.triangle.branch"),
                // Top branch
                n("parse",     x: 660,  y: 60,  title: "Parse",     category: "Data",      icon: "doc.text.fill",       subtitle: "JSON"),
                n("transform", x: 870,  y: 60,  title: "Transform", category: "Transform", icon: "wand.and.stars",      subtitle: "Map fields"),
                n("dbwrite",   x: 1080, y: 60,  title: "DB Write",  category: "Storage",   icon: "internaldrive.fill",  subtitle: "PostgreSQL"),
                // Middle branch
                n("validate", x: 660,  y: 200, title: "Validate",  category: "Logic",     icon: "checkmark.shield.fill"),
                n("enrich",   x: 870,  y: 200, title: "Enrich",    category: "Data",      icon: "plus.magnifyingglass", subtitle: "Metadata"),
                n("apicall",  x: 1080, y: 200, title: "API Call",  category: "Network",   icon: "network",              badge: "POST", subtitle: "api.example.com"),
                // Bottom branch
                n("cache",  x: 660,  y: 340, title: "Cache",  category: "Storage", icon: "tray.full.fill",         subtitle: "Redis"),
                n("queue",  x: 870,  y: 340, title: "Queue",  category: "Queue",   icon: "list.bullet",            subtitle: "3 pending"),
                n("retry",  x: 1080, y: 340, title: "Retry",  category: "Logic",   icon: "arrow.counterclockwise"),
                // Exit
                n("merge",  x: 1290, y: 200, title: "Merge",  category: "Logic",     icon: "arrow.triangle.merge"),
                n("format", x: 1500, y: 200, title: "Format", category: "Transform", icon: "text.alignleft",       subtitle: "Template"),
                n("notify", x: 1710, y: 200, title: "Notify", category: "Output",    icon: "bell.fill",            handles: hIn, badge: "3"),
            ],
            edges: [
                // Entry (animated to show dash phase)
                FlowEdge(id: "e01", sourceNodeID: "webhook", sourceHandleID: "out", targetNodeID: "auth",     targetHandleID: "in"),
                FlowEdge(id: "e02", sourceNodeID: "auth",    sourceHandleID: "out", targetNodeID: "router",   targetHandleID: "in"),
                // Fan-out from router
                FlowEdge(id: "e03", sourceNodeID: "router",  sourceHandleID: "out", targetNodeID: "parse",    targetHandleID: "in", label: "JSON"),
                FlowEdge(id: "e04", sourceNodeID: "router",  sourceHandleID: "out", targetNodeID: "validate", targetHandleID: "in"),
                FlowEdge(id: "e05", sourceNodeID: "router",  sourceHandleID: "out", targetNodeID: "cache",    targetHandleID: "in", label: "Static"),
                // Top branch
                FlowEdge(id: "e06", sourceNodeID: "parse",     sourceHandleID: "out", targetNodeID: "transform", targetHandleID: "in"),
                FlowEdge(id: "e07", sourceNodeID: "transform", sourceHandleID: "out", targetNodeID: "dbwrite",   targetHandleID: "in"),
                FlowEdge(id: "e08", sourceNodeID: "dbwrite",   sourceHandleID: "out", targetNodeID: "merge",     targetHandleID: "in"),
                // Middle branch
                FlowEdge(id: "e09", sourceNodeID: "validate", sourceHandleID: "out", targetNodeID: "enrich",  targetHandleID: "in"),
                FlowEdge(id: "e10", sourceNodeID: "enrich",   sourceHandleID: "out", targetNodeID: "apicall", targetHandleID: "in"),
                FlowEdge(id: "e11", sourceNodeID: "apicall",  sourceHandleID: "out", targetNodeID: "merge",   targetHandleID: "in"),
                // Bottom branch
                FlowEdge(id: "e12", sourceNodeID: "cache", sourceHandleID: "out", targetNodeID: "queue", targetHandleID: "in"),
                FlowEdge(id: "e13", sourceNodeID: "queue", sourceHandleID: "out", targetNodeID: "retry", targetHandleID: "in"),
                FlowEdge(id: "e14", sourceNodeID: "retry", sourceHandleID: "out", targetNodeID: "merge", targetHandleID: "in"),
                // Exit
                FlowEdge(id: "e15", sourceNodeID: "merge",  sourceHandleID: "out", targetNodeID: "format", targetHandleID: "in"),
                FlowEdge(id: "e16", sourceNodeID: "format", sourceHandleID: "out", targetNodeID: "notify", targetHandleID: "in"),
            ],
            configuration: FlowConfiguration(
                backgroundStyle: BackgroundStyle(pattern: .dot),
                connectionValidator: PreviewConnectionValidator()
            )
        )
        // Animate entry edges to show dash phase
        store.setAnimatedEdges(["e01", "e02"])
        store.onConnect = { [weak store] proposal in
            guard let store else { return }
            let edge = FlowEdge(
                id: "e-\(UUID().uuidString.prefix(8))",
                sourceNodeID: proposal.sourceNodeID,
                sourceHandleID: proposal.sourceHandleID,
                targetNodeID: proposal.targetNodeID,
                targetHandleID: proposal.targetHandleID,
                pathType: store.configuration.defaultEdgePathType
            )
            store.addEdge(edge)
        }
        return store
    }()
    @Previewable @State var interaction = PreviewInteractionState()
    GeometryReader { geometry in
        let previewDraftPoint = store.viewport.canvasToScreen(CGPoint(x: 760, y: 455))

        ZStack {
            FlowCanvas(store: store) { node, context in
                PreviewNode(node: node, context: context)
            }
            .nodeAccessory(placement: { node in
                switch node.data.category {
                case "Trigger", "Data", "Transform":
                    return .bottom
                default:
                    return .top
                }
            }) { node in
                VStack(alignment: .leading, spacing: 6) {
                    Text(node.data.title)
                        .font(.headline)
                    Text(node.data.category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    HStack(spacing: 12) {
                        Button {
                        } label: {
                            Label("Edit", systemImage: "pencil")
                                .font(.caption)
                        }
                        Button(role: .destructive) {
                            store.removeNode(node.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                                .font(.caption)
                        }
                    }
                }
                .padding(12)
                .frame(width: 180)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            }
            .edgeAccessory { edge in
                HStack(spacing: 8) {
                    if let label = edge.label {
                        Text(label)
                            .font(.caption.bold())
                    } else {
                        Text("Edge")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        store.removeEdge(edge.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            }
            .dropDestination(for: [UTType.json]) { phase in
                switch phase {
                case .updated(_, _, let target):
                    // All items use .json — accept all targets during hover.
                    // Kind-based filtering happens on performed.
                    switch target {
                    case .canvas, .node, .edge:
                        return true
                    }

                case .performed(let providers, let location, let target):
                    let jsonType = UTType.json.identifier
                    for provider in providers {
                        provider.loadDataRepresentation(forTypeIdentifier: jsonType) { data, error in
                            guard let data else { return }
                            let payload: DragPayload
                            do {
                                payload = try JSONDecoder().decode(DragPayload.self, from: data)
                            } catch {
                                return
                            }
                            Task { @MainActor in
                                switch (payload.kind, target) {
                                case (.nodeTemplate, .canvas):
                                    let id = "new-\(UUID().uuidString.prefix(8))"
                                    let node = FlowNode(
                                        id: id,
                                        position: location,
                                        size: CGSize(width: 160, height: 50),
                                        data: PreviewNodeData(
                                            title: payload.title,
                                            category: payload.subtitle ?? "Default",
                                            icon: payload.icon
                                        ),
                                        handles: [
                                            HandleDeclaration(id: "in", type: .target, position: .left),
                                            HandleDeclaration(id: "out", type: .source, position: .right),
                                        ]
                                    )
                                    store.addNode(node)

                                case (.nodeAttribute, .node(let nodeID)):
                                    store.updateNode(nodeID) { node in
                                        node.data.badge = payload.title
                                        node.data.subtitle = payload.subtitle
                                    }

                                case (.edgeAttribute, .edge(let edgeID)):
                                    store.updateEdge(edgeID) { edge in
                                        edge.label = payload.title
                                    }

                                default:
                                    break
                                }
                            }
                        }
                    }
                    return true

                case .exited:
                    return false
                }
            }

            DragPalette()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)

            PreviewStatusPanel(
                interaction: interaction,
                toggleDraft: {
                    if store.nodeLookup[previewDraftNodeID] == nil {
                        store.addNode(makePreviewDraftNode(phase: .draft(.neutral)))
                        store.connectionDraft = ConnectionDraft(
                            sourceNodeID: "router",
                            sourceHandleID: "out",
                            sourceHandleType: .source,
                            sourceHandlePosition: .right,
                            targetNodeID: previewDraftNodeID,
                            targetHandleID: "in",
                            currentPoint: previewDraftPoint
                        )
                        interaction.draftStatus = previewDraftStatusText(store.nodeLookup[previewDraftNodeID])
                        interaction.draftTarget = previewDraftTargetText("in")
                        interaction.lastEvent = "Injected a transient draft node with a snapped draft edge."
                    } else {
                        store.connectionDraft = nil
                        store.removeNode(previewDraftNodeID)
                        interaction.draftStatus = "Hidden"
                        interaction.draftTarget = "No target"
                        interaction.lastEvent = "Cleared the transient draft node."
                    }
                },
                cycleDraftState: {
                    guard let node = store.nodeLookup[previewDraftNodeID] else { return }
                    let nextState: DraftPresentationState
                    switch node.phase {
                    case .draft(.neutral):
                        nextState = .valid
                    case .draft(.valid):
                        nextState = .invalid
                    case .draft(.invalid), .normal:
                        nextState = .neutral
                    }
                    store.updateNode(previewDraftNodeID) { draftNode in
                        draftNode.phase = .draft(nextState)
                    }
                    interaction.draftStatus = previewDraftStatusText(store.nodeLookup[previewDraftNodeID])
                    interaction.lastEvent = "Draft node switched to \(previewDraftPhaseText(.draft(nextState)).lowercased())."
                },
                toggleDraftTarget: {
                    guard store.nodeLookup[previewDraftNodeID] != nil else { return }
                    if store.connectionDraft == nil {
                        store.connectionDraft = ConnectionDraft(
                            sourceNodeID: "router",
                            sourceHandleID: "out",
                            sourceHandleType: .source,
                            sourceHandlePosition: .right,
                            currentPoint: previewDraftPoint
                        )
                    }
                    let nextTargetHandleID: String? =
                        store.connectionDraft?.targetHandleID == nil ? "in" : nil
                    store.connectionDraft?.targetNodeID = nextTargetHandleID == nil ? nil : previewDraftNodeID
                    store.connectionDraft?.targetHandleID = nextTargetHandleID
                    store.connectionDraft?.currentPoint = previewDraftPoint
                    interaction.draftTarget = previewDraftTargetText(nextTargetHandleID)
                    interaction.lastEvent =
                        nextTargetHandleID == nil
                        ? "Draft edge released from the node and now points at a free location."
                        : "Draft edge snapped to the draft node handle."
                },
                commitDraft: {
                    guard store.nodeLookup[previewDraftNodeID] != nil else { return }

                    if let draft = store.connectionDraft,
                       let targetNodeID = draft.targetNodeID,
                       targetNodeID == previewDraftNodeID {
                        let proposal: ConnectionProposal
                        if draft.sourceHandleType == .source {
                            proposal = ConnectionProposal(
                                sourceNodeID: draft.sourceNodeID,
                                sourceHandleID: draft.sourceHandleID,
                                targetNodeID: targetNodeID,
                                targetHandleID: draft.targetHandleID
                            )
                        } else {
                            proposal = ConnectionProposal(
                                sourceNodeID: targetNodeID,
                                sourceHandleID: draft.targetHandleID,
                                targetNodeID: draft.sourceNodeID,
                                targetHandleID: draft.sourceHandleID
                            )
                        }

                        let validator = store.configuration.connectionValidator ?? DefaultConnectionValidator()
                        if validator.validate(proposal) {
                            store.onConnect?(proposal)
                        } else {
                            store.onConnectionRejected?(proposal)
                        }
                    }

                    store.updateNode(previewDraftNodeID) { draftNode in
                        draftNode.phase = .normal
                        draftNode.persistence = .persistent
                    }
                    store.connectionDraft = nil
                    interaction.draftStatus = previewDraftStatusText(store.nodeLookup[previewDraftNodeID])
                    interaction.draftTarget = "No target"
                    interaction.lastEvent = "Committed the draft node and cleared the draft edge."
                },
                cycleEdgePathStyle: {
                    let nextPathType = previewNextEdgePathType(after: store.configuration.defaultEdgePathType)
                    store.configuration.defaultEdgePathType = nextPathType
                    store.updateEdges { edge in
                        edge.pathType = nextPathType
                    }
                    interaction.edgePathStyle = previewEdgePathStyleText(nextPathType)
                    interaction.lastEvent = "Switched all edges to \(previewEdgePathStyleText(nextPathType))."
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(12)

            VStack(alignment: .trailing, spacing: 8) {
                MiniMap(store: store, canvasSize: geometry.size)

                AnimationToolbar(store: store, canvasSize: geometry.size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(12)
        }
        .onAppear {
            store.onConnect = { [weak store, interaction] proposal in
                guard let store else { return }
                interaction.lastEvent = "Connected \(previewProposalText(proposal))."
                let edge = FlowEdge(
                    id: "e-\(UUID().uuidString.prefix(8))",
                    sourceNodeID: proposal.sourceNodeID,
                    sourceHandleID: proposal.sourceHandleID,
                    targetNodeID: proposal.targetNodeID,
                    targetHandleID: proposal.targetHandleID,
                    pathType: store.configuration.defaultEdgePathType
                )
                store.addEdge(edge)
            }
            store.onCanvasDoubleTap = { [interaction] point in
                interaction.lastCanvasDoubleTap = previewPointText(point)
                interaction.lastEvent = "Canvas double-tapped at \(previewPointText(point))."
            }
            store.onConnectionRejected = { [interaction] proposal in
                interaction.lastRejectedConnection = previewProposalText(proposal)
                interaction.lastEvent = "Rejected \(previewProposalText(proposal))."
            }
            if let draft = store.nodeLookup[previewDraftNodeID] {
                interaction.draftStatus = previewDraftStatusText(draft)
            }
            interaction.draftTarget =
                store.connectionDraft == nil
                ? "No target"
                : previewDraftTargetText(store.connectionDraft?.targetHandleID)
            interaction.edgePathStyle = previewEdgePathStyleText(store.configuration.defaultEdgePathType)
            store.fitToContent(canvasSize: geometry.size)
        }
    }
    .frame(minWidth: 800, minHeight: 600)
}

private struct AnimationToolbar: View {

    let store: FlowStore<PreviewNodeData>
    let canvasSize: CGSize

    @State private var isScattered = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                store.fitToContent(canvasSize: canvasSize, animation: .smooth)
            } label: {
                Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
            }

            Button {
                store.zoom(by: 1.5, anchor: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2), animation: .spring())
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
                    .font(.caption)
            }

            Button {
                store.zoom(by: 0.67, anchor: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2), animation: .spring())
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
                    .font(.caption)
            }

            Button {
                if isScattered {
                    // Restore original layout
                    var positions: [String: CGPoint] = [:]
                    let originalPositions: [(String, CGFloat, CGFloat)] = [
                        ("webhook", 30, 200), ("auth", 240, 200), ("router", 450, 200),
                        ("parse", 660, 60), ("transform", 870, 60), ("dbwrite", 1080, 60),
                        ("validate", 660, 200), ("enrich", 870, 200), ("apicall", 1080, 200),
                        ("cache", 660, 340), ("queue", 870, 340), ("retry", 1080, 340),
                        ("merge", 1290, 200), ("format", 1500, 200), ("notify", 1710, 200),
                    ]
                    for (id, x, y) in originalPositions {
                        positions[id] = CGPoint(x: x, y: y)
                    }
                    store.setNodePositions(positions, animation: .spring(response: 0.6, dampingFraction: 0.8))
                } else {
                    // Scatter nodes randomly
                    var positions: [String: CGPoint] = [:]
                    for node in store.nodes {
                        positions[node.id] = CGPoint(
                            x: CGFloat.random(in: 0...1500),
                            y: CGFloat.random(in: 0...600)
                        )
                    }
                    store.setNodePositions(positions, animation: .spring(response: 0.6, dampingFraction: 0.8))
                }
                isScattered.toggle()
            } label: {
                Label(isScattered ? "Restore" : "Scatter", systemImage: isScattered ? "arrow.uturn.backward" : "sparkles")
                    .font(.caption)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DragPalette: View {

    static let nodeTemplates: [DragPayload] = [
        DragPayload(kind: .nodeTemplate, title: "HTTP", subtitle: "Trigger", icon: "globe"),
        DragPayload(kind: .nodeTemplate, title: "Filter", subtitle: "Logic", icon: "line.3.horizontal.decrease"),
        DragPayload(kind: .nodeTemplate, title: "Map", subtitle: "Transform", icon: "arrow.left.arrow.right"),
        DragPayload(kind: .nodeTemplate, title: "Storage", subtitle: "Storage", icon: "cylinder"),
    ]

    static let nodeAttributes: [DragPayload] = [
        DragPayload(kind: .nodeAttribute, title: "Auth", subtitle: "Bearer Token", icon: "lock.shield"),
        DragPayload(kind: .nodeAttribute, title: "Cache", subtitle: "TTL 60s", icon: "clock.arrow.circlepath"),
        DragPayload(kind: .nodeAttribute, title: "Retry", subtitle: "Max 3", icon: "arrow.counterclockwise"),
    ]

    static let edgeAttributes: [DragPayload] = [
        DragPayload(kind: .edgeAttribute, title: "Success", subtitle: "solid", icon: "checkmark.circle"),
        DragPayload(kind: .edgeAttribute, title: "Error", subtitle: "dashed", icon: "xmark.circle"),
        DragPayload(kind: .edgeAttribute, title: "Async", subtitle: "animated", icon: "arrow.triangle.swap"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            paletteSection(title: "Nodes", color: .blue) {
                ForEach(Self.nodeTemplates, id: \.title) { item in
                    paletteDragRow(icon: item.icon, label: item.title, color: .blue)
                        .draggable(item) { dragPreview(icon: item.icon, label: item.title, color: .blue) }
                }
            }

            paletteSection(title: "Node Attrs", color: .orange) {
                ForEach(Self.nodeAttributes, id: \.title) { item in
                    paletteDragRow(icon: item.icon, label: item.title, color: .orange)
                        .draggable(item) { dragPreview(icon: item.icon, label: item.title, color: .orange) }
                }
            }

            paletteSection(title: "Edge Attrs", color: .green) {
                ForEach(Self.edgeAttributes, id: \.title) { item in
                    paletteDragRow(icon: item.icon, label: item.title, color: .green)
                        .draggable(item) { dragPreview(icon: item.icon, label: item.title, color: .green) }
                }
            }
        }
        .padding(8)
        .frame(width: 130)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func paletteSection<Content: View>(
        title: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func paletteDragRow(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 16)
            Text(label)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func dragPreview(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 16)
            Text(label)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Live Preview

/// Per-node payload for the unified Live preview. Cases pick which native
/// surface (or pure-SwiftUI body) the node renders. Each case carries the
/// minimal data needed to construct its body without consulting an external
/// lookup.
private enum LivePreviewData: Sendable, Hashable {
    case web(url: URL, title: String)
    case map(latitude: Double, longitude: Double, title: String)
    case resizable(title: String, color: String)

    var title: String {
        switch self {
        case let .web(_, title), let .map(_, _, title), let .resizable(title, _):
            return title
        }
    }

    var headerColor: Color {
        switch self {
        case .web:       return .blue
        case .map:       return .green
        case .resizable: return .orange
        }
    }

    var headerSymbol: String {
        switch self {
        case .web:       return "globe"
        case .map:       return "map"
        case .resizable: return "square.resize"
        }
    }
}

// MARK: - Resize support

private enum ResizeCorner {
    case topLeft, topRight, bottomLeft, bottomRight

    func apply(startFrame: CGRect, canvasDelta: CGSize, minSize: CGSize) -> CGRect {
        var x = startFrame.minX
        var y = startFrame.minY
        var width = startFrame.width
        var height = startFrame.height

        switch self {
        case .topLeft:
            x = min(startFrame.minX + canvasDelta.width, startFrame.maxX - minSize.width)
            y = min(startFrame.minY + canvasDelta.height, startFrame.maxY - minSize.height)
            width = max(minSize.width, startFrame.width - canvasDelta.width)
            height = max(minSize.height, startFrame.height - canvasDelta.height)

        case .topRight:
            y = min(startFrame.minY + canvasDelta.height, startFrame.maxY - minSize.height)
            width = max(minSize.width, startFrame.width + canvasDelta.width)
            height = max(minSize.height, startFrame.height - canvasDelta.height)

        case .bottomLeft:
            x = min(startFrame.minX + canvasDelta.width, startFrame.maxX - minSize.width)
            width = max(minSize.width, startFrame.width - canvasDelta.width)
            height = max(minSize.height, startFrame.height + canvasDelta.height)

        case .bottomRight:
            width = max(minSize.width, startFrame.width + canvasDelta.width)
            height = max(minSize.height, startFrame.height + canvasDelta.height)
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private struct ResizeHandleOverlay<Data: Sendable & Hashable>: View {
    let store: FlowStore<Data>
    let nodeID: String

    private let handleSize: CGFloat = 10
    private let minSize = CGSize(width: 40, height: 30)

    @State private var startFrame: CGRect?

    var body: some View {
        if let node = store.nodeLookup[nodeID] {
            let frameOnScreen = CGRect(
                origin: store.viewport.canvasToScreen(node.position),
                size: CGSize(
                    width: node.size.width * store.viewport.zoom,
                    height: node.size.height * store.viewport.zoom
                )
            )

            ZStack {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .frame(width: frameOnScreen.width, height: frameOnScreen.height)
                    .position(x: frameOnScreen.midX, y: frameOnScreen.midY)
                    .allowsHitTesting(false)

                handle(at: CGPoint(x: frameOnScreen.minX, y: frameOnScreen.minY), corner: .topLeft)
                handle(at: CGPoint(x: frameOnScreen.maxX, y: frameOnScreen.minY), corner: .topRight)
                handle(at: CGPoint(x: frameOnScreen.minX, y: frameOnScreen.maxY), corner: .bottomLeft)
                handle(at: CGPoint(x: frameOnScreen.maxX, y: frameOnScreen.maxY), corner: .bottomRight)
            }
        }
    }

    @ViewBuilder
    private func handle(at point: CGPoint, corner: ResizeCorner) -> some View {
        Rectangle()
            .fill(Color.white)
            .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5))
            .frame(width: handleSize, height: handleSize)
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard let node = store.nodeLookup[nodeID] else { return }

                        if startFrame == nil {
                            startFrame = node.frame
                            store.beginInteractiveUpdates()
                        }

                        guard let startFrame else { return }

                        let zoom = store.viewport.zoom
                        let canvasDelta = CGSize(
                            width: value.translation.width / zoom,
                            height: value.translation.height / zoom
                        )

                        let newFrame = corner.apply(
                            startFrame: startFrame,
                            canvasDelta: canvasDelta,
                            minSize: minSize
                        )

                        store.updateNode(nodeID) { node in
                            node.position = newFrame.origin
                            node.size = newFrame.size
                        }
                    }
                    .onEnded { _ in
                        guard let startFrame else { return }
                        self.startFrame = nil
                        store.endInteractiveUpdates()
                        store.completeResizeNodes(from: [nodeID: startFrame])
                    }
            )
    }
}

// MARK: - Platform image helpers

#if os(iOS)
private typealias LivePreviewPlatformImage = UIImage
#elseif os(macOS)
private typealias LivePreviewPlatformImage = NSImage
#endif

private extension LivePreviewPlatformImage {
    var flowNodeSnapshot: FlowNodeSnapshot? {
        #if os(iOS)
        guard let cgImage else { return nil }
        return FlowNodeSnapshot(cgImage: cgImage, scale: scale)
        #elseif os(macOS)
        var rect = CGRect(origin: .zero, size: size)
        guard let cgImage = cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        let scale = CGFloat(cgImage.width) / max(size.width, 1)
        return FlowNodeSnapshot(cgImage: cgImage, scale: scale)
        #endif
    }
}

// MARK: - Web support

@MainActor
private final class WebNodeCoordinator: NSObject, WKNavigationDelegate {
    var onSnapshotReady: (FlowNodeSnapshot) -> Void

    init(onSnapshotReady: @escaping (FlowNodeSnapshot) -> Void) {
        self.onSnapshotReady = onSnapshotReady
        super.init()
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard let snapshot = await webView.makeFlowNodeSnapshot() else { return }
            self?.onSnapshotReady(snapshot)
        }
    }
}

private final class LiveWebView: WKWebView {
    /// DEBUG-only workaround for SwiftUI Preview windows whose occlusion state
    /// can make WebKit pause WebContent rendering even while visible.
    func disableWindowOcclusionDetection() {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if responds(to: selector) {
            perform(selector, with: NSNumber(value: false))
        }
    }

    #if os(iOS)
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        wakeCompositor()
    }
    #elseif os(macOS)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        wakeCompositor()
    }
    #endif

    private func wakeCompositor() {
        evaluateJavaScript("document.documentElement.offsetHeight", completionHandler: nil)
    }
}

private extension WKWebView {
    @MainActor
    func makeFlowNodeSnapshot() async -> FlowNodeSnapshot? {
        let configuration = WKSnapshotConfiguration()

        do {
            let image = try await takeSnapshot(configuration: configuration)
            return image.flowNodeSnapshot
        } catch {
            return nil
        }
    }
}

#if os(iOS)
private struct WebNodeRepresentable: UIViewRepresentable {
    let webView: LiveWebView
    let url: URL
    let cornerRadius: CGFloat
    let onSnapshotReady: (FlowNodeSnapshot) -> Void

    func makeCoordinator() -> WebNodeCoordinator {
        WebNodeCoordinator(onSnapshotReady: onSnapshotReady)
    }

    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.layer.cornerRadius = cornerRadius
        webView.layer.masksToBounds = true
        webView.scrollView.layer.cornerRadius = cornerRadius
        webView.scrollView.layer.masksToBounds = true

        if webView.url == nil {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSnapshotReady = onSnapshotReady
        webView.layer.cornerRadius = cornerRadius
        webView.scrollView.layer.cornerRadius = cornerRadius
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: WebNodeCoordinator) {
        webView.navigationDelegate = nil
    }
}
#elseif os(macOS)
private struct WebNodeRepresentable: NSViewRepresentable {
    let webView: LiveWebView
    let url: URL
    let cornerRadius: CGFloat
    let onSnapshotReady: (FlowNodeSnapshot) -> Void

    func makeCoordinator() -> WebNodeCoordinator {
        WebNodeCoordinator(onSnapshotReady: onSnapshotReady)
    }

    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.wantsLayer = true
        webView.layer?.cornerRadius = cornerRadius
        webView.layer?.masksToBounds = true

        if webView.url == nil {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSnapshotReady = onSnapshotReady
        webView.layer?.cornerRadius = cornerRadius
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: WebNodeCoordinator) {
        webView.navigationDelegate = nil
    }
}
#endif

// MARK: - Web node wrapper

/// View that owns a stable `WKWebView` instance via `@StateObject`. The
/// same instance is passed both to ``WebNodeRepresentable`` (for live
/// rendering) and to the ``LiveNode/init(node:mount:snapshot:capture:content:placeholder:)``
/// `capture: .custom` closure (for snapshot generation).
private struct WebNodeView: View {

    let node: FlowNode<LivePreviewData>
    let url: URL
    let title: String
    let cornerRadius: CGFloat
    let store: FlowStore<LivePreviewData>

    @StateObject private var ref = WebNodeRef()

    var body: some View {
        LiveNode(
            node: node,
            mount: .persistent,
            snapshot: .onDeactivation,
            capture: .custom { [ref] in
                await ref.webView.makeFlowNodeSnapshot()
            }
        ) {
            WebNodeRepresentable(
                webView: ref.webView,
                url: url,
                cornerRadius: cornerRadius,
                onSnapshotReady: { [store, nodeID = node.id] snapshot in
                    store.setNodeSnapshot(snapshot, for: nodeID)
                }
            )
        } placeholder: {
            VStack(spacing: 8) {
                ProgressView()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        }
    }
}

@MainActor
private final class WebNodeRef: ObservableObject {
    let webView: LiveWebView

    init() {
        let v = LiveWebView()
        #if os(macOS)
        v.disableWindowOcclusionDetection()
        #endif
        self.webView = v
    }
}

// MARK: - Live preview view

private struct LiveFlowPreview: View {

    @State private var mapStateStore = LiveMapNodeStateStore()
    @State private var store: FlowStore<LivePreviewData> = {
        FlowStore<LivePreviewData>(
            nodes: [
                FlowNode(
                    id: "apple",
                    position: CGPoint(x: 60, y: 80),
                    size: CGSize(width: 360, height: 240),
                    data: .web(url: URL(string: "https://www.apple.com")!, title: "apple.com")
                ),
                FlowNode(
                    id: "developer",
                    position: CGPoint(x: 520, y: 80),
                    size: CGSize(width: 360, height: 240),
                    data: .web(url: URL(string: "https://developer.apple.com")!, title: "developer.apple.com")
                ),
                FlowNode(
                    id: "tokyo",
                    position: CGPoint(x: 60, y: 400),
                    size: CGSize(width: 360, height: 240),
                    data: .map(latitude: 35.6812, longitude: 139.7671, title: "Tokyo Station")
                ),
                FlowNode(
                    id: "kyoto",
                    position: CGPoint(x: 520, y: 400),
                    size: CGSize(width: 360, height: 240),
                    data: .map(latitude: 35.0116, longitude: 135.7681, title: "Kyoto")
                ),
                FlowNode(
                    id: "scratch",
                    position: CGPoint(x: 980, y: 240),
                    size: CGSize(width: 220, height: 140),
                    data: .resizable(title: "Resize Me", color: "orange")
                ),
            ],
            edges: [
                FlowEdge(id: "e1", sourceNodeID: "apple", sourceHandleID: "source", targetNodeID: "developer", targetHandleID: "target"),
                FlowEdge(id: "e2", sourceNodeID: "tokyo", sourceHandleID: "source", targetNodeID: "kyoto", targetHandleID: "target"),
                FlowEdge(id: "e3", sourceNodeID: "developer", sourceHandleID: "source", targetNodeID: "scratch", targetHandleID: "target"),
                FlowEdge(id: "e4", sourceNodeID: "kyoto", sourceHandleID: "source", targetNodeID: "scratch", targetHandleID: "target"),
            ]
        )
    }()

    var body: some View {
        ZStack(alignment: .topLeading) {
            FlowCanvas(store: store) { node, context in
                nodeBody(for: node, context: context)
            }
            .liveNodeActivation { node, store in
                store.selectedNodeIDs.contains(node.id) || store.hoveredNodeID == node.id
            }
            .overlay {
                ForEach(Array(store.selectedNodeIDs), id: \.self) { nodeID in
                    if case .resizable = store.nodeLookup[nodeID]?.data {
                        ResizeHandleOverlay(store: store, nodeID: nodeID)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Live Node Preview")
                    .font(.headline)
                Text("Hover or select a node to switch from snapshot to its live view.")
                Text("Web / map headers use FlowNodeDragHandle so node-move works above scroll-consuming bodies.")
                    .foregroundStyle(.secondary)
                Text("Web nodes mount as .persistent with capture: .custom { webView snapshot }; map nodes use .remountOnActivation.")
                    .foregroundStyle(.secondary)
                Text("Select the orange node and drag a corner handle to resize.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
        }
    }

    @ViewBuilder
    private func nodeBody(for node: FlowNode<LivePreviewData>, context: NodeRenderContext) -> some View {
        LivePreviewNodeBody(
            node: node,
            context: context,
            mapStateStore: mapStateStore,
            store: store
        )
    }

}

/// Node body for the Live preview.
///
/// `LiveNode(node:)` owns its own content-area frame at `node.size`, so
/// this body only composes the surrounding chrome (FlowHandle padding,
/// handle overlay). Modifiers that should apply to both live and
/// rasterize phases — e.g. `clipShape`, `shadow`, `overlay(...)` — are
/// attached directly to the `LiveNode` / `LiveMapNode` so they sit on
/// the outer phase surface and affect both phases uniformly.
private struct LivePreviewNodeBody: View {

    let node: FlowNode<LivePreviewData>
    let context: NodeRenderContext
    let mapStateStore: LiveMapNodeStateStore
    let store: FlowStore<LivePreviewData>

    var body: some View {
        let inset = FlowHandle.diameter / 2

        nodeView
            .padding(inset)
            .overlay {
                FlowNodeHandles(node: node, context: context)
            }
    }

    @ViewBuilder
    private var nodeView: some View {
        let cornerRadius: CGFloat = 12

        switch node.data {
        case let .web(url, title):
            WebNodeView(
                node: node,
                url: url,
                title: title,
                cornerRadius: cornerRadius,
                store: store
            )
            .overlay(alignment: .top) {
                headerOverlay
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)

        case let .map(latitude, longitude, _):
            LiveMapNode(
                node: node,
                initialCoordinate: CLLocationCoordinate2D(
                    latitude: latitude,
                    longitude: longitude
                ),
                stateStore: mapStateStore,
                cornerRadius: cornerRadius
            )
            .overlay(alignment: .top) {
                headerOverlay
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)

        case let .resizable(_, color):
            resizableBody(color: color)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
    }

    private var headerOverlay: some View {
        FlowNodeDragHandle {
            HStack(spacing: 6) {
                Image(systemName: node.data.headerSymbol)
                    .font(.caption)
                Text(node.data.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(node.data.headerColor.opacity(0.9))
        }
    }

    private func resizableBody(color colorName: String) -> some View {
        let color = resizableColor(named: colorName)
        let size = node.size

        return LiveNode(node: node) {
            TimelineView(.animation) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate

                ZStack {
                    color.opacity(0.12 + 0.08 * (0.5 + 0.5 * sin(time * 2)))

                    VStack(spacing: 4) {
                        Text("\(Int(size.width)) × \(Int(size.height))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text("Select & drag a corner")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(time * 180))
                        .frame(width: 22, height: 22)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(8)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func resizableColor(named name: String) -> Color {
        switch name {
        case "blue":   return .blue
        case "orange": return .orange
        case "green":  return .green
        default:       return .gray
        }
    }
}

#Preview("FlowCanvas - Live") {
    LiveFlowPreview()
        .frame(minWidth: 1200, minHeight: 800)
}

#endif
