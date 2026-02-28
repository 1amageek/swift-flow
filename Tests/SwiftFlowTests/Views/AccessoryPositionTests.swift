import Testing
import CoreGraphics
@testable import SwiftFlow

@Suite("Accessory clamped positioning")
struct AccessoryPositionTests {

    private let canvasSize = CGSize(width: 800, height: 600)
    private let accessorySize = CGSize(width: 200, height: 80)

    // MARK: - Default placement (above anchor)

    @Test("Anchor at center places accessory above")
    func centerPlacement() {
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 400, y: 300),
            accessorySize: accessorySize,
            canvasSize: canvasSize
        )
        // Accessory center should be above anchor
        #expect(result.x == 400)
        // y = 300 - 40 - 8 = 252
        #expect(result.y == 252)
    }

    // MARK: - Top edge flip

    @Test("Anchor near top flips accessory below")
    func topEdgeFlip() {
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 400, y: 20),
            accessorySize: accessorySize,
            canvasSize: canvasSize
        )
        // Should flip to below anchor
        #expect(result.y > 20)
    }

    // MARK: - Bottom edge flip

    @Test("Anchor near bottom places accessory above")
    func bottomEdge() {
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 400, y: 580),
            accessorySize: accessorySize,
            canvasSize: canvasSize
        )
        // Should stay above anchor
        #expect(result.y < 580)
    }

    // MARK: - Left edge clamp

    @Test("Anchor near left edge shifts accessory right")
    func leftEdgeClamp() {
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 20, y: 300),
            accessorySize: accessorySize,
            canvasSize: canvasSize
        )
        // minimum x = margin + halfW = 8 + 100 = 108
        #expect(result.x == 108)
    }

    // MARK: - Right edge clamp

    @Test("Anchor near right edge shifts accessory left")
    func rightEdgeClamp() {
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 780, y: 300),
            accessorySize: accessorySize,
            canvasSize: canvasSize
        )
        // maximum x = 800 - 8 - 100 = 692
        #expect(result.x == 692)
    }

    // MARK: - Corner case

    @Test("Anchor near top-left corner adjusts both axes")
    func topLeftCorner() {
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 10, y: 10),
            accessorySize: accessorySize,
            canvasSize: canvasSize
        )
        // Horizontal: clamped to margin + halfW
        #expect(result.x == 108)
        // Vertical: flipped below
        #expect(result.y > 10)
    }

    // MARK: - Zero-size accessory

    @Test("Zero-size accessory positions at anchor with spacing offset")
    func zeroSizeAccessory() {
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 400, y: 300),
            accessorySize: .zero,
            canvasSize: canvasSize
        )
        // y = 300 - 0 - 8 = 292
        #expect(result.x == 400)
        #expect(result.y == 292)
    }

    // MARK: - Custom spacing and margin

    @Test("Custom spacing and margin are respected")
    func customSpacingAndMargin() {
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 400, y: 300),
            accessorySize: accessorySize,
            canvasSize: canvasSize,
            spacing: 16,
            margin: 20
        )
        // y = 300 - 40 - 16 = 244
        #expect(result.x == 400)
        #expect(result.y == 244)
    }

    // MARK: - Bottom placement

    @Test("Bottom placement positions accessory below anchor")
    func bottomPlacement() {
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 400, y: 300),
            accessorySize: accessorySize,
            canvasSize: canvasSize,
            placement: .bottom
        )
        #expect(result.x == 400)
        // y = 300 + 40 + 8 = 348
        #expect(result.y == 348)
    }

    @Test("Bottom placement flips above when clipped")
    func bottomPlacementFlip() {
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 400, y: 570),
            accessorySize: accessorySize,
            canvasSize: canvasSize,
            placement: .bottom
        )
        #expect(result.y < 570)
    }

    // MARK: - Leading placement

    @Test("Leading placement positions accessory left of anchor")
    func leadingPlacement() {
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 400, y: 300),
            accessorySize: accessorySize,
            canvasSize: canvasSize,
            placement: .leading
        )
        // x = 400 - 100 - 8 = 292
        #expect(result.x == 292)
        #expect(result.y == 300)
    }

    @Test("Leading placement flips right when clipped")
    func leadingPlacementFlip() {
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 30, y: 300),
            accessorySize: accessorySize,
            canvasSize: canvasSize,
            placement: .leading
        )
        #expect(result.x > 30)
    }

    // MARK: - Trailing placement

    @Test("Trailing placement positions accessory right of anchor")
    func trailingPlacement() {
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 400, y: 300),
            accessorySize: accessorySize,
            canvasSize: canvasSize,
            placement: .trailing
        )
        // x = 400 + 100 + 8 = 508
        #expect(result.x == 508)
        #expect(result.y == 300)
    }

    @Test("Trailing placement flips left when clipped")
    func trailingPlacementFlip() {
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 770, y: 300),
            accessorySize: accessorySize,
            canvasSize: canvasSize,
            placement: .trailing
        )
        #expect(result.x < 770)
    }

    // MARK: - Anchor size awareness

    private let nodeSize = CGSize(width: 160, height: 60)

    @Test("Top placement offsets by anchor height so accessory does not overlap node")
    func topPlacementWithAnchorSize() {
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 400, y: 300),
            anchorSize: nodeSize,
            accessorySize: accessorySize,
            canvasSize: canvasSize
        )
        #expect(result.x == 400)
        // y = 300 - 30 (anchorHalfH) - 40 (halfH) - 8 (spacing) = 222
        #expect(result.y == 222)
        // Accessory bottom edge = 222 + 40 = 262, node top edge = 300 - 30 = 270
        // 262 < 270 → no overlap
    }

    @Test("Bottom placement offsets by anchor height so accessory does not overlap node")
    func bottomPlacementWithAnchorSize() {
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 400, y: 300),
            anchorSize: nodeSize,
            accessorySize: accessorySize,
            canvasSize: canvasSize,
            placement: .bottom
        )
        #expect(result.x == 400)
        // y = 300 + 30 (anchorHalfH) + 40 (halfH) + 8 (spacing) = 378
        #expect(result.y == 378)
        // Accessory top edge = 378 - 40 = 338, node bottom edge = 300 + 30 = 330
        // 338 > 330 → no overlap
    }

    @Test("Leading placement offsets by anchor width so accessory does not overlap node")
    func leadingPlacementWithAnchorSize() {
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 400, y: 300),
            anchorSize: nodeSize,
            accessorySize: accessorySize,
            canvasSize: canvasSize,
            placement: .leading
        )
        // x = 400 - 80 (anchorHalfW) - 100 (halfW) - 8 (spacing) = 212
        #expect(result.x == 212)
        #expect(result.y == 300)
    }

    @Test("Trailing placement offsets by anchor width so accessory does not overlap node")
    func trailingPlacementWithAnchorSize() {
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 400, y: 300),
            anchorSize: nodeSize,
            accessorySize: accessorySize,
            canvasSize: canvasSize,
            placement: .trailing
        )
        // x = 400 + 80 (anchorHalfW) + 100 (halfW) + 8 (spacing) = 588
        #expect(result.x == 588)
        #expect(result.y == 300)
    }

    @Test("Top placement with anchor size flips below when clipped")
    func topPlacementWithAnchorSizeFlip() {
        // Anchor near top: 300 center with 60 height node → top edge at 50
        // Accessory above: 80 - 30 - 40 - 8 = 2, bottom edge at 42 > margin(8), but top edge at 2-40 = -38 < 0
        let result = accessoryClampedPosition(
            anchor: CGPoint(x: 400, y: 80),
            anchorSize: nodeSize,
            accessorySize: accessorySize,
            canvasSize: canvasSize
        )
        // Should flip below: y = 80 + 30 + 40 + 8 = 158
        #expect(result.y > 80)
    }

}
