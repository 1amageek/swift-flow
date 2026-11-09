# Canvas View Composition

## Purpose and Scope
Own FlowCanvas rendering and native host composition. Parent:
[SwiftFlow module](../DESIGN.md). No new child component.

## Responsibilities and Boundaries
FlowCanvas owns layer placement. CanvasHostView owns platform event delivery and
normalization. Caller-supplied overlays own content and actions, not viewport math.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Module](../DESIGN.md) | parent | FlowCanvas / FlowStore | Public composition | Preserve existing clients |

## Architecture
```text
FlowCanvas
  -> CanvasHostView
       -> CanvasNSHostingView / UIHostingController
            -> canvasView + canvasOverlay content
  -> LiveNodeOverlay and selection accessories
```

## Contracts and Invariants
`canvasOverlay(content:)` replaces the optional overlay builder on a copied
FlowCanvas value. Content uses local screen coordinates and is laid over the
batch Canvas, below live Nodes and selection accessories. It shares the native
host's responder/gesture hierarchy. Unlike an outer SwiftUI overlay, its
unconsumed scroll events reach the existing macOS CanvasNSHostingView handler.
Controls that consume scrolling (such as scroll views) keep their own behavior.
The modifier does not transform coordinates or install event monitors.

The macOS Canvas accepts keyboard focus without drawing a focus ring around
the whole surface. Node and Edge selection belong to FlowStore.

## State, Ownership, and Lifecycle
The builder is retained by the FlowCanvas value; native hosts update their
existing root view. All callbacks follow SwiftUI/AppKit MainActor isolation.
No new task, shared storage, subscription or teardown requirement is introduced.

## Verification and Change Impact
[CanvasOverlayTests](../../../Tests/SwiftFlowTests/Views/CanvasOverlayTests.swift)
uses a real NSWindow and child button hit target, delivers a real wheel event and
observes FlowStore pan and unchanged click activation. The integration client
must check its actual SwiftUI buttons. Build both macOS and iOS host branches.
Existing host scroll normalization, pan-disable guard and interaction lifetime
remain the sole implementation path and are not reimplemented by the overlay.

Verification receipt (2026-11-09): bounded macOS `swift test` passed205tests in
25suites, including CanvasOverlayTests; Xcode Default iOS Simulator build passed
arm64/x86_64. Vision Studio's actual SwiftUI Edge button scrolled its Canvas,
opened the output Grid and returned successfully. This qualifies native wheel
routing, not physical trackpad gestures or iOS runtime interaction.

## Routed Edge rendering
The default Canvas draws the resolved path and, for waypoint routes, an
arrowhead aligned to its last segment. It culls against the path bounds.
Custom Edge symbols receive the same path in symbol-local coordinates.
