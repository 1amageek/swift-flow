# SwiftFlow

## Purpose and Scope
SwiftPM package for interactive flow diagrams on macOS and iOS26+. This is the
package master; its child is the [SwiftFlow module](Sources/SwiftFlow/DESIGN.md).

## Responsibilities and Boundaries
Own diagram state, viewport interaction and rendering. Applications own domain
models, labels and actions. Existing library conventions remain in [AGENTS.md](AGENTS.md).

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Module](Sources/SwiftFlow/DESIGN.md) | child | FlowCanvas / FlowStore | Diagram composition | UI isolated to MainActor |

## Architecture
```text
Application -> FlowCanvas -> platform event host -> FlowStore
                         -> Canvas and hosted overlays
```

## Contracts and Invariants
FlowStore is the authoritative observable diagram state. Viewport input handling
belongs to the platform host. Custom content does not duplicate scroll scaling.
The new canvasOverlay modifier is additive; existing clients keep their rendering
and event behavior when no overlay is supplied.

## Verification and Change Impact
Module tests verify state and platform interaction; macOS and iOS builds verify
platform composition. Application integration verifies its actual label buttons.
