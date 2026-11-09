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
A nonempty waypoint list overrides the default path style. The polyline starts
and ends at the live handles and passes through all points in order without
rounding. The label is on a segment and the final nonzero segment supplies
the direction. An empty list uses the existing path calculator. Nonfinite
coordinates cannot produce a routed path.

## Verification and Change Impact
Store tests exercise route ordering, label placement, endpoint movement,
hit testing and rectangle selection. Document tests exercise persistence
and decoding of older Edges. Verify routed geometry at the client boundary.
