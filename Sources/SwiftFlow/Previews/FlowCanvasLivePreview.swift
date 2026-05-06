#if DEBUG

import SwiftUI
import WebKit
import MapKit

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
                            store.beginResizeNodes([nodeID])
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
                        store.endResizeNodes()
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
    var snapshotContext: LiveNodeSnapshotContext?

    override init() {
        super.init()
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            // `didFinish` fires after the load event for the main frame,
            // including its subresources, so the network-side wait already
            // scales with link quality. The remaining delay is a paint
            // settle — the compositor needs a frame or two to commit the
            // final layout before the snapshot reads pixels.
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            guard self?.snapshotContext?.allowsImmediateSnapshotWrites == true else { return }
            guard let snapshot = await webView.makeFlowNodeSnapshot() else { return }
            self?.snapshotContext?.write(snapshot)
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

    @Environment(\.liveNodeSnapshotContext) private var snapshotContext

    func makeCoordinator() -> WebNodeCoordinator {
        WebNodeCoordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        coordinator.snapshotContext = snapshotContext

        webView.navigationDelegate = coordinator
        webView.layer.cornerRadius = cornerRadius
        webView.layer.masksToBounds = true
        webView.scrollView.layer.cornerRadius = cornerRadius
        webView.scrollView.layer.masksToBounds = true

        if webView.url == nil {
            webView.load(URLRequest(url: url))
        }

        // Register the interaction-end capture handler with the surrounding
        // LiveNode. The handler captures `webView` weakly so the
        // representable does not extend its lifetime past the View's.
        snapshotContext?.registerCapture { [weak webView] in
            guard let webView else { return nil }
            return await webView.makeFlowNodeSnapshot()
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.snapshotContext = snapshotContext
        webView.layer.cornerRadius = cornerRadius
        webView.scrollView.layer.cornerRadius = cornerRadius
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: WebNodeCoordinator) {
        coordinator.snapshotContext?.unregisterCapture()
        coordinator.snapshotContext = nil
        webView.navigationDelegate = nil
    }
}
#elseif os(macOS)
private struct WebNodeRepresentable: NSViewRepresentable {
    let webView: LiveWebView
    let url: URL
    let cornerRadius: CGFloat

    @Environment(\.liveNodeSnapshotContext) private var snapshotContext

    func makeCoordinator() -> WebNodeCoordinator {
        WebNodeCoordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        coordinator.snapshotContext = snapshotContext

        webView.navigationDelegate = coordinator
        webView.wantsLayer = true
        webView.layer?.cornerRadius = cornerRadius
        webView.layer?.masksToBounds = true

        if webView.url == nil {
            webView.load(URLRequest(url: url))
        }

        // Register the interaction-end capture handler with the surrounding
        // LiveNode. The handler captures `webView` weakly so the
        // representable does not extend its lifetime past the View's.
        snapshotContext?.registerCapture { [weak webView] in
            guard let webView else { return nil }
            return await webView.makeFlowNodeSnapshot()
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.snapshotContext = snapshotContext
        webView.layer?.cornerRadius = cornerRadius
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: WebNodeCoordinator) {
        coordinator.snapshotContext?.unregisterCapture()
        coordinator.snapshotContext = nil
        webView.navigationDelegate = nil
    }
}
#endif

// MARK: - Web node wrapper

/// View that owns a stable `WKWebView` instance via `@State`. The
/// representable reads `\.liveNodeSnapshotContext` from the surrounding
/// `LiveNode` and uses it for both interaction-end capture registration and
/// post-navigation snapshot pushes — the developer never has to wire a
/// closure through `LiveNode`'s initializer.
private struct WebNodeView: View {

    let node: FlowNode<LivePreviewData>
    let url: URL
    let title: String
    let cornerRadius: CGFloat

    @State private var webView: LiveWebView = {
        let v = LiveWebView()
        #if os(macOS)
        v.disableWindowOcclusionDetection()
        #endif
        return v
    }()

    var body: some View {
        LiveNode(node: node, mount: .persistent) {
            WebNodeRepresentable(
                webView: webView,
                url: url,
                cornerRadius: cornerRadius
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

// MARK: - Live preview view

public struct FlowCanvasLiveDemoView: View {

    public init() {}

    public var body: some View {
        LiveFlowPreview()
    }
}

private struct LiveFlowPreview: View {

    @State private var mapStateStore = LiveMapNodeStateStore()
    @State private var store: FlowStore<LivePreviewData> = {
        FlowStore<LivePreviewData>(
            nodes: [
                FlowNode(
                    id: "developer",
                    position: CGPoint(x: 60, y: 80),
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
                    id: "scratch",
                    position: CGPoint(x: 520, y: 240),
                    size: CGSize(width: 220, height: 140),
                    data: .resizable(title: "Resize Me", color: "orange")
                ),
            ],
            edges: [
                FlowEdge(id: "e1", sourceNodeID: "developer", sourceHandleID: "source", targetNodeID: "tokyo", targetHandleID: "target"),
                FlowEdge(id: "e2", sourceNodeID: "tokyo", sourceHandleID: "source", targetNodeID: "scratch", targetHandleID: "target"),
            ]
        )
    }()

    var body: some View {
        ZStack(alignment: .topLeading) {
            FlowCanvas(store: store) { node, context in
                nodeBody(for: node, context: context)
            }
            .liveNodeInteraction { node, store in
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
                Text("Drag from the header strip — flowDragHandle(for:in:) routes the drag through FlowStore, so the WKWebView / MKMapView body keeps its own scroll/pan.")
                    .foregroundStyle(.secondary)
                Text("Select the orange node and drag a corner handle to resize.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(12)

            LiveMapLifecycleDiagnosticsPanel(
                diagnostics: mapStateStore.diagnostics(for: "tokyo")
            )
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .allowsHitTesting(false)
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

private struct LiveMapLifecycleDiagnosticsPanel: View {

    let diagnostics: LiveMapNodeDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Map lifecycle")
                .font(.caption.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                row("node", diagnostics.nodeID)
                row("mapID", diagnostics.mapID)
                row("make", "\(diagnostics.makeCount)")
                row("dismantle", "\(diagnostics.dismantleCount)")
            }
            Divider()
            Text("Persistent check: make=1, dismantle=0, stable mapID")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .font(.caption.monospaced())
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }
}

/// Node body for the Live preview.
///
/// `LiveNode(node:)` owns its own content-area frame at `node.size`, so
/// this body only composes the surrounding chrome (FlowHandle padding,
/// handle overlay). Modifiers that should apply to both live and
/// rasterize phases — e.g. `clipShape`, selected `shadow`, `overlay(...)`
/// — are attached directly to the `LiveNode` / `LiveMapNode` so they sit
/// on the outer phase surface and affect both phases uniformly.
private struct LivePreviewNodeBody: View {

    private static let headerHeight: CGFloat = 26

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
        let contentSize = CGSize(
            width: node.size.width,
            height: max(1, node.size.height - Self.headerHeight)
        )

        switch node.data {
        case let .web(url, title):
            windowBody(cornerRadius: cornerRadius, contentSize: contentSize) {
                WebNodeView(
                    node: contentNode(size: contentSize),
                    url: url,
                    title: title,
                    cornerRadius: 0
                )
            }

        case let .map(latitude, longitude, _):
            windowBody(cornerRadius: cornerRadius, contentSize: contentSize) {
                LiveMapNode(
                    node: contentNode(size: contentSize),
                    initialCoordinate: CLLocationCoordinate2D(
                        latitude: latitude,
                        longitude: longitude
                    ),
                    stateStore: mapStateStore,
                    cornerRadius: 0
                )
            }

        case let .resizable(_, color):
            windowBody(cornerRadius: cornerRadius, contentSize: contentSize) {
                resizableBody(color: color, contentSize: contentSize)
            }
        }
    }

    private func contentNode(size: CGSize) -> FlowNode<LivePreviewData> {
        var contentNode = node
        contentNode.size = size
        return contentNode
    }

    private func windowBody<Content: View>(
        cornerRadius: CGFloat,
        contentSize: CGSize,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            dragHandleHeader()
                .frame(width: node.size.width, height: Self.headerHeight)

            content()
                .frame(width: contentSize.width, height: contentSize.height)
        }
        .frame(width: node.size.width, height: node.size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .livePreviewSelectionShadow()
    }

    @ViewBuilder
    private func dragHandleHeader() -> some View {
        let isActiveWindow = store.focusedTarget == .node(node.id)
        let headerBackground = isActiveWindow
            ? node.data.headerColor.opacity(0.9)
            : Color.gray.opacity(0.72)

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
        .background(headerBackground)
        .contentShape(Rectangle())
        .flowDragHandle(for: node, in: store)
    }

    private func resizableBody(color colorName: String, contentSize: CGSize) -> some View {
        let color = resizableColor(named: colorName)
        let liveNode = contentNode(size: contentSize)

        return LiveNode(node: liveNode) {
            TimelineView(.animation) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate

                ZStack {
                    color.opacity(0.12 + 0.08 * (0.5 + 0.5 * sin(time * 2)))

                    VStack(spacing: 4) {
                        Text("\(Int(contentSize.width)) × \(Int(contentSize.height))")
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

private extension View {
    func livePreviewSelectionShadow() -> some View {
        modifier(LivePreviewSelectionShadow())
    }
}

private struct LivePreviewSelectionShadow: ViewModifier {
    @Environment(\.isFlowNodeSelected) private var isSelected

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? Color.primary.opacity(0.18) : .clear,
                        lineWidth: isSelected ? 1.5 : 0
                    )
            }
            .shadow(
                color: .black.opacity(0.15),
                radius: 6,
                y: 2
            )
            .shadow(
                color: isSelected ? Color.black.opacity(0.28) : .clear,
                radius: isSelected ? 14 : 0,
                y: isSelected ? 7 : 0
            )
    }
}

#Preview("FlowCanvas - Live") {
    FlowCanvasLiveDemoView()
        .frame(minWidth: 1200, minHeight: 800)
}

#endif
