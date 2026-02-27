# SwiftFlow

A Canvas-based flow diagram library for SwiftUI, supporting iOS and macOS.

## Features

- **Canvas rendering** - Edges drawn via `GraphicsContext` for batch performance; nodes rendered as SwiftUI views via `resolveSymbol`
- **Customizable nodes** - Implement the `NodeContent` protocol to define your own node appearance
- **Multiple edge styles** - Bezier, SimpleBezier, SmoothStep, and Straight path types
- **Interactive** - Drag nodes, pan/zoom the viewport, create connections by dragging handles
- **Selection** - Single tap, Shift+drag rectangle (macOS), long-press+drag (iOS)
- **Cursor feedback** (macOS) - Contextual cursor changes for handles, nodes, and canvas
- **Serialization** - Export/import via `FlowDocument` (Codable)
- **Minimap** - Overview of the entire canvas

## Requirements

- Swift 6.2+
- iOS 26+ / macOS 26+

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/1amageek/swift-flow.git", from: "0.1.0")
]
```

## Quick Start

```swift
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

## Custom Nodes

Implement `NodeContent` to create your own node views:

```swift
struct MyNodeContent: NodeContent {
    typealias NodeData = String
    let node: FlowNode<String>

    init(node: FlowNode<String>) {
        self.node = node
    }

    var body: some View {
        Text(node.data)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                ForEach(node.handles, id: \.id) { handle in
                    FlowHandle(handle.id, type: handle.type, position: handle.position)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: handleAlignment(handle.position))
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

## Architecture

```
User Input (Gestures)
    |
FlowCanvas (hit testing, rendering)
    |
FlowStore (state management, @Observable)
    |
Callbacks (onNodesChange, onEdgesChange, onConnect)
```

| Layer | Responsibility |
|---|---|
| **Models** | `FlowNode`, `FlowEdge`, `Viewport`, `HandleDeclaration` |
| **Store** | `FlowStore` - single source of truth with O(1) lookups |
| **Views** | `FlowCanvas` - Canvas API rendering with resolveSymbol |
| **Protocols** | `NodeContent`, `EdgePathCalculating`, `ConnectionValidating` |
| **EdgePaths** | Bezier, SimpleBezier, SmoothStep, Straight |

## License

MIT License. See [LICENSE](LICENSE) for details.
