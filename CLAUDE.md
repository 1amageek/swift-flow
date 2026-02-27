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
- Animation: Self-driven `Task` loop (~120fps) with `PropertyAnimation` — SwiftUI `withAnimation` does not work with Canvas

## File Structure

```
Sources/SwiftFlow/
├── Animation/     # FlowAnimation (public API), PropertyAnimation (spring/easeInOut engine)
├── Changes/       # NodeChange, EdgeChange enums
├── EdgePaths/     # BezierEdgePath, StraightEdgePath, SmoothStepEdgePath, SimpleBezierEdgePath
├── Models/        # FlowNode, FlowEdge, FlowDocument, HandleDeclaration, Viewport, etc.
├── Protocols/     # EdgePathCalculating, ConnectionValidating
├── Store/         # FlowStore, FlowConfiguration
├── Styles/        # EdgeStyle
├── Utilities/     # CGPointExtensions, GeometryHelpers
└── Views/         # FlowCanvas, CanvasHostView (macOS), DefaultNodeContent, FlowHandle, MinimapView
```

## Animation System

Canvas + GraphicsContext は SwiftUI の補間パイプラインを経由しないため、自前のアニメーションループで実現。

### Public API (`FlowAnimation`)

| Method | Description |
|---|---|
| `setViewport(_:animation:)` | Viewport を animated に変更 |
| `zoom(by:anchor:animation:)` | Anchor-based animated zoom (offset は zoom から毎フレーム導出) |
| `fitToContent(canvasSize:padding:animation:)` | Animated fit |
| `setNodePositions(_:animation:)` | 複数ノード position を animated に変更 |

### Cancellation

即時メソッドが対応するアニメーションを自動キャンセル:
- `moveNode` → node position animation
- `pan(by:)` → viewport offset animation
- `zoom(by:anchor:)` (non-animated) → all viewport animations
- `fitToContent` (non-animated) → all viewport animations
- `load()` → all animations + dashPhase reset

### Implementation Notes

- `PropertyAnimation`: per-component (CGFloat) interpolation. Spring = semi-implicit Euler, EaseInOut = smoothstep
- Settle threshold: `0.1` for both displacement and velocity — must be small enough for zoom values (0.1–4.0)
- Anchor-based zoom: only zoom is animated; offset is derived each frame via `offset = anchor - (anchor - initialOffset) * (zoom / initialZoom)`
- Animated edges (`FlowEdge.isAnimated`): `edgeDashPhase` increments continuously, read by Canvas `StrokeStyle`
- Animation tick skips `onNodesChange` callbacks, undo registration, and snap-to-grid for lightweight per-frame updates

## Build & Test

```bash
swift build                # macOS build
swift test                 # run tests

# iOS build verification
xcodebuild -scheme SwiftFlow -destination 'generic/platform=iOS Simulator' build
```
