# SwiftFlow

A Canvas-based flow diagram library for SwiftUI, supporting iOS and macOS.

Edges are batch-drawn via `GraphicsContext` for performance. Nodes are rendered as SwiftUI views via `resolveSymbol`, so you can use any SwiftUI view as a node.

## Requirements

- Swift 6.2+
- iOS 26+ / macOS 26+

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/1amageek/swift-flow.git", from: "0.1.0")
]
```

## Quick Start

```swift
import SwiftUI
import SwiftFlow

struct ContentView: View {
    @State var store = FlowStore<String>(
        nodes: [
            FlowNode(id: "a", position: CGPoint(x: 50, y: 100), size: CGSize(width: 120, height: 50), data: "Start"),
            FlowNode(id: "b", position: CGPoint(x: 250, y: 100), size: CGSize(width: 120, height: 50), data: "End"),
        ],
        edges: [
            FlowEdge(id: "e1", sourceNodeID: "a", sourceHandleID: "source", targetNodeID: "b", targetHandleID: "target"),
        ]
    )

    var body: some View {
        FlowCanvas<String, DefaultNodeContent<String>>(store: store)
    }
}
```

This renders two nodes connected by a bezier edge. Nodes are draggable, the canvas supports pan and zoom out of the box.

## Core Concepts

### FlowStore

`FlowStore<Data>` is the single source of truth. It is `@Observable` and `@MainActor`.

The generic parameter `Data` is the payload each node carries. It must conform to `Sendable & Hashable` (add `Codable` for serialization).

```swift
// Initialize with nodes and edges
let store = FlowStore<String>(
    nodes: [node1, node2],
    edges: [edge1],
    configuration: FlowConfiguration(
        defaultEdgePathType: .smoothStep,
        snapToGrid: true,
        gridSize: 20
    )
)
```

### FlowNode

Each node has a position, size, and custom data payload.

```swift
FlowNode(
    id: "node-1",
    position: CGPoint(x: 100, y: 200),
    size: CGSize(width: 150, height: 60),     // default: 150x60
    data: "My Node",
    isDraggable: true,                         // default: true
    zIndex: 0,                                 // default: 0
    handles: [                                 // default: target(top), source(bottom)
        HandleDeclaration(id: "in", type: .target, position: .left),
        HandleDeclaration(id: "out", type: .source, position: .right),
    ]
)
```

#### Handles

Handles are connection points on a node. Each handle has an `id`, a `type` (.source or .target), and a `position` (.top, .bottom, .left, .right).

- `.source` handles can connect **to** `.target` handles
- `.target` handles can receive connections **from** `.source` handles

Default handles are `target` at top and `source` at bottom (vertical flow). Override for horizontal layouts:

```swift
let horizontalHandles = [
    HandleDeclaration(id: "target", type: .target, position: .left),
    HandleDeclaration(id: "source", type: .source, position: .right),
]
```

A node can have multiple handles:

```swift
let multiHandles = [
    HandleDeclaration(id: "in", type: .target, position: .left),
    HandleDeclaration(id: "out-yes", type: .source, position: .right),
    HandleDeclaration(id: "out-no", type: .source, position: .bottom),
]
```

### FlowEdge

Edges connect a source handle on one node to a target handle on another node.

```swift
FlowEdge(
    id: "edge-1",
    sourceNodeID: "node-1",
    sourceHandleID: "out",        // matches HandleDeclaration.id on source node
    targetNodeID: "node-2",
    targetHandleID: "in",         // matches HandleDeclaration.id on target node
    pathType: .bezier,            // .bezier | .straight | .smoothStep | .simpleBezier
    label: "Yes",                 // optional label displayed on the edge
    isAnimated: false             // animated dash pattern
)
```

### FlowCanvas

The main view. Generic over `Data` and a `NodeContent` conforming view.

```swift
FlowCanvas<String, DefaultNodeContent<String>>(store: store)
```

Or with a custom node view:

```swift
FlowCanvas<MyData, MyNodeView>(store: store)
```

## Custom Node Views

Implement the `NodeContent` protocol to define your own node appearance:

```swift
struct StatusNodeContent: NodeContent {
    typealias NodeData = TaskData

    let node: FlowNode<TaskData>

    init(node: FlowNode<TaskData>) {
        self.node = node
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(node.data.title)
                .font(.caption.bold())
            Text(node.data.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(width: node.size.width, height: node.size.height)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(node.isSelected ? .blue : .gray.opacity(0.3))
        }
        .overlay {
            ForEach(node.handles, id: \.id) { handle in
                FlowHandle(handle.id, type: handle.type, position: handle.position)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: handleAlignment(handle.position)
                    )
            }
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
```

Key points for custom nodes:
- Set `frame(width: node.size.width, height: node.size.height)` to match the node's declared size
- Use `overlay` with `FlowHandle` views to render connection points at the node edges
- Use `node.isSelected` to show selection state
- Use `FlowHandle(id, type:, position:)` for each handle in `node.handles`

## Handling Connections

When a user drags from a source handle to a target handle, `onConnect` is called. You must create the edge yourself:

```swift
store.onConnect = { [weak store] proposal in
    guard let store else { return }
    let edge = FlowEdge(
        id: UUID().uuidString,
        sourceNodeID: proposal.sourceNodeID,
        sourceHandleID: proposal.sourceHandleID,
        targetNodeID: proposal.targetNodeID,
        targetHandleID: proposal.targetHandleID
    )
    store.addEdge(edge)
}
```

### Connection Validation

By default, self-loop connections (same source and target node) are rejected. Provide a custom validator for more rules:

```swift
struct MyValidator: ConnectionValidating {
    func validate(_ proposal: ConnectionProposal) -> Bool {
        // Reject self-loops
        guard proposal.sourceNodeID != proposal.targetNodeID else { return false }
        // Add custom rules here
        return true
    }
}

let config = FlowConfiguration(connectionValidator: MyValidator())
let store = FlowStore<String>(configuration: config)
```

## Observing Changes

React to state changes via callbacks:

```swift
store.onNodesChange = { changes in
    for change in changes {
        switch change {
        case .add(let node):       print("Added: \(node.id)")
        case .remove(let nodeID):  print("Removed: \(nodeID)")
        case .position(let id, let pos): print("Moved \(id) to \(pos)")
        case .select(let id, let selected): print("\(id) selected: \(selected)")
        case .dimensions(let id, let size): print("\(id) resized to \(size)")
        case .replace(let node):   print("Replaced: \(node.id)")
        }
    }
}

store.onEdgesChange = { changes in
    for change in changes {
        switch change {
        case .add(let edge):       print("Connected: \(edge.id)")
        case .remove(let edgeID):  print("Disconnected: \(edgeID)")
        case .select(let id, let selected): print("\(id) selected: \(selected)")
        case .replace(let edge):   print("Updated: \(edge.id)")
        }
    }
}
```

## FlowConfiguration

All behavior is configurable:

```swift
FlowConfiguration(
    defaultEdgePathType: .bezier,      // .bezier | .straight | .smoothStep | .simpleBezier
    edgeStyle: EdgeStyle(
        strokeColor: .gray,            // normal edge color
        selectedStrokeColor: .blue,    // selected edge color
        lineWidth: 1.5,               // normal width
        selectedLineWidth: 2.5,       // selected width
        dashPattern: [],              // empty = solid line, e.g. [5, 3]
        animatedDashPattern: [5, 5]   // pattern for isAnimated edges
    ),
    snapToGrid: false,                 // snap node positions to grid
    gridSize: 20,                      // grid cell size (when snapToGrid is true)
    minZoom: 0.1,                      // minimum zoom level
    maxZoom: 4.0,                      // maximum zoom level
    connectionValidator: nil,          // custom ConnectionValidating, nil = DefaultConnectionValidator
    panEnabled: true,                  // allow canvas panning
    zoomEnabled: true,                 // allow canvas zooming
    selectionEnabled: true,            // allow node/edge selection
    multiSelectionEnabled: true        // allow multi-selection (Shift+drag on macOS, long-press+drag on iOS)
)
```

## Store Operations

### Node Operations

```swift
store.addNode(node)                     // add a node
store.removeNode("node-1")              // remove node and its connected edges
store.moveNode("node-1", to: point)     // move node (respects snapToGrid)
store.updateNodeSize("node-1", size: size)  // resize node
```

### Edge Operations

```swift
store.addEdge(edge)                     // add an edge
store.removeEdge("edge-1")              // remove an edge
```

### Selection

```swift
store.selectNode("node-1")              // select (clears other selections)
store.selectNode("node-2", exclusive: false)  // add to selection
store.deselectNode("node-1")
store.selectEdge("edge-1")
store.deselectEdge("edge-1")
store.clearSelection()
```

### Viewport

```swift
store.pan(by: CGSize(width: 10, height: 0))  // pan canvas
store.zoom(by: 1.5, anchor: center)           // zoom around anchor point
store.fitToContent(canvasSize: size)           // fit all nodes in view
```

### Queries

```swift
store.edgesForNode("node-1")            // all edges connected to node
store.nodeBounds()                      // bounding rect of all nodes
store.nodeLookup["node-1"]              // O(1) node access by id
store.connectionLookup["node-1"]        // O(1) edges for a node
store.selectedNodeIDs                   // currently selected node IDs
store.selectedEdgeIDs                   // currently selected edge IDs
```

## Serialization

Export and import the entire diagram as JSON (requires `Data: Codable`):

```swift
// Export
let document = store.export()
let jsonData = try document.encoded()

// Import
let document = try FlowDocument<String>.decoded(from: jsonData)
store.load(document)
```

`FlowDocument` contains nodes, edges, and viewport state. Selection state is cleared on export.

## Interaction Reference

| Action | macOS | iOS |
|---|---|---|
| Drag node | Drag on node | Drag on node |
| Pan canvas | Scroll / drag on empty area | Drag on empty area |
| Zoom | Pinch trackpad / scroll+magnify | Pinch gesture |
| Connect | Drag from handle to handle | Drag from handle to handle |
| Select node/edge | Click | Tap |
| Multi-select | Shift + drag rectangle | Long press + drag |
| Cursor feedback | Contextual (hand/crosshair/arrow) | N/A |

## Architecture

```
┌─────────────────────────────────────────────┐
│ FlowCanvas<Data, Content>                   │
│  ├─ Canvas + GraphicsContext (edges)        │
│  ├─ resolveSymbol (nodes as SwiftUI Views)  │
│  └─ Gesture state machine                   │
├─────────────────────────────────────────────┤
│ FlowStore<Data>  (@Observable, @MainActor)  │
│  ├─ nodes: [FlowNode<Data>]                │
│  ├─ edges: [FlowEdge]                      │
│  ├─ viewport: Viewport                      │
│  ├─ nodeLookup / connectionLookup (O(1))   │
│  └─ hit testing, connection workflow        │
├─────────────────────────────────────────────┤
│ Protocols                                    │
│  ├─ NodeContent (custom node views)         │
│  ├─ EdgePathCalculating (custom routing)    │
│  └─ ConnectionValidating (connection rules) │
└─────────────────────────────────────────────┘
```

## License

MIT License. See [LICENSE](LICENSE) for details.
