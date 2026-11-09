# Edge Paths

## Purpose and Scope
Canvas-space Edge geometry. Parent: [SwiftFlow](../DESIGN.md). No children.

## Responsibilities and Boundaries
Convert resolved handle anchors and ordered waypoints to one drawable path.
Clients own obstacle avoidance and the choice of waypoint coordinates.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [SwiftFlow](../DESIGN.md) | parent | FlowStore path resolution | Resolves Edge handles | Missing handles produce no path |
| [Views](../Views/DESIGN.md) | used by | EdgePath | Render and place labels | Transform from canvas space |

## Architecture
```text
FlowEdge + handle anchors -> FlowStore -> EdgePath -> drawing, labels, hit tests
```

## Contracts and Invariants
A polyline uses ordered canvas-space points. An explicit cubic route uses
`EdgeBezierRoute`, which owns its own ordered middle points. Each middle point
has independent incoming and outgoing control offsets. The endpoint controls
are offsets from the live handle anchors. Offsets set the direction and
magnitude of the bow and are distinct from the points the path visits.
Opposing collinear offsets give a visually smooth join. The explicit route
applies to the Bezier style and takes precedence over the polyline waypoint list.
The label and arrow are derived from the same cubic path used for drawing and
hit testing. Nonfinite or degenerate geometry cannot produce an explicit path.

Polyline waypoints are connected by straight segments between the live handle
anchors. Documents saved with the former corner-rounding option still resolve
their waypoint lists as polylines. The label is on a segment and the final
nonzero segment supplies the arrow direction. When an edge has neither
polyline waypoints nor an explicit cubic route, the chosen style calculator
resolves its default path. Nonfinite coordinates produce no route.

## Verification and Change Impact
Store tests exercise route ordering, label placement, endpoint movement,
hit testing, Bezier tangents and rectangle selection. Document tests exercise persistence
and decoding of older Edges. Verify routed geometry at the client boundary.
