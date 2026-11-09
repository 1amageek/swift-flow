# SwiftFlow Module

## Purpose and Scope
Public library module. Parent: [package](../../DESIGN.md). The affected view
composition is specified by [Views](Views/DESIGN.md); other library areas retain
existing implementation and documented contracts in the [README](../../README.md).

## Responsibilities and Boundaries
FlowStore owns diagram state. FlowCanvas composes rendering and platform input.
Applications supply domain data and view-builder actions.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | Platform support | Library boundary | No domain processing |
| [Views](Views/DESIGN.md) | child | canvasOverlay | Native host composition | Screen-local coordinates |

## Architecture
```text
Application view builder -> FlowCanvas -> platform host -> FlowStore viewport
```

## Contracts and Invariants
Custom overlays retain their SwiftUI identity inside the platform host. They may
consume clicks; unconsumed viewport events reach the existing platform handler.
No global event monitor or separate viewport state is introduced.

## Verification and Change Impact
[CanvasOverlayTests](../../Tests/SwiftFlowTests/Views/CanvasOverlayTests.swift)
verifies native hit testing, click actions and real scroll-event propagation to
FlowStore. Changes to host composition require package and client revalidation.

## Explicit Edge routes
[EdgePaths](EdgePaths/DESIGN.md) defines the geometry contract for ordered
waypoints. FlowStore resolves handles and exposes the resulting canvas path
to the Canvas and clients. The document stores waypoints in order and decodes
older Edges with an empty list. Fit includes the extent of explicit routes.
