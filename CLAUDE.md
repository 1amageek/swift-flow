# SwiftFlow

Canvas-based flow diagram library for SwiftUI (iOS 26+ / macOS 26+).

## Architecture

- **Rendering**: Single `Canvas` + `GraphicsContext` — edges are batch-drawn via `context.stroke()`, nodes via `resolveSymbol()`
- **State**: `FlowStore<Data>` is `@Observable` + `@MainActor`, single source of truth
- **Extensibility**: `@ViewBuilder` closures for custom node/edge views, `EdgePathCalculating` for edge routing

## Key Conventions

- Edges: GraphicsContext direct draw (batch normal/selected into separate Paths)
- Nodes: `resolveSymbol` to render SwiftUI Views inside Canvas
- Handle positions: computed from `HandleDeclaration` on `FlowNode`, not PreferenceKey
- Hit testing: Canvas-level, priority order: handle > node > edge
- Platform split: `#if os(macOS)` for `CanvasHostView` (NSCursor, scroll/magnify), selection gesture

## File Structure

```
Sources/SwiftFlow/
├── Changes/       # NodeChange, EdgeChange enums
├── EdgePaths/     # BezierEdgePath, StraightEdgePath, SmoothStepEdgePath, SimpleBezierEdgePath
├── Models/        # FlowNode, FlowEdge, FlowDocument, HandleDeclaration, Viewport, etc.
├── Protocols/     # EdgePathCalculating, ConnectionValidating
├── Store/         # FlowStore, FlowConfiguration
├── Styles/        # EdgeStyle
├── Utilities/     # CGPointExtensions, GeometryHelpers
└── Views/         # FlowCanvas, CanvasHostView (macOS), DefaultNodeContent, FlowHandle, MinimapView
```

## Build & Test

```bash
swift build                # macOS build
swift test                 # run tests

# iOS build verification
xcodebuild -scheme SwiftFlow -destination 'generic/platform=iOS Simulator' build
```
