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
applies to the Bezier style and takes precedence over the legacy waypoint list.
The label and arrow are derived from the same cubic path used for drawing and
hit testing. Nonfinite or degenerate geometry cannot produce an explicit path.

An explicit route passes through its ordered waypoints between the live handle
anchors. The cubic Bezier style interpolates the points with a shared tangent
at each turn; straight portions keep their original track and exact reversals
may have a cusp. The endpoint tangents follow
the first and last chords. At most six canvas units separate a cubic segment
from its chord, as exported by `BezierEdgePath.maximumWaypointDeviation`.
Applications can reserve that much clearance plus their stroke margin. The
maximum span along either incident chord is exported by
`BezierEdgePath.maximumWaypointSpan`. Applications can use
`FlowEdge.sharpWaypointIndices` to preserve specific joins; when consecutive
points coincide, a sharp designation on any of them is sufficient.
Other styles retain straight segments for explicit routes. The label is on a
segment and the final nonzero segment supplies the arrow direction. An empty
list uses the existing path calculator. Nonfinite coordinates produce no route.

## Verification and Change Impact
Store tests exercise route ordering, label placement, endpoint movement,
hit testing, Bezier tangents and rectangle selection. Document tests exercise persistence
and decoding of older Edges. Verify routed geometry at the client boundary.
