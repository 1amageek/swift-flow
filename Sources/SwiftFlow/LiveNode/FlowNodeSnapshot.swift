import CoreGraphics
import Foundation

/// Rasterized cache of a node's live content.
///
/// Produced by `LiveNode` (or by the app for `.manual` captures of native
/// views) and stored in `FlowStore.nodeSnapshots`. The Canvas rasterize
/// path reads it to avoid an empty frame while the node is not interactive.
///
/// This is a rendering cache rather than document state: it is not part
/// of undo/redo and may be regenerated at any time.
public struct FlowNodeSnapshot: @unchecked Sendable, Hashable {

    /// Rasterized image content. `CGImage` is an immutable Core Graphics
    /// value; treating it as `Sendable` is safe in practice.
    public let cgImage: CGImage

    /// Pixel scale the image was rendered at. Forwarded to
    /// `Image(cgImage:scale:)` so that logical size on screen matches the
    /// node's `size` across display scales.
    public let scale: CGFloat

    /// Capture timestamp. Used by throttled capture cadences (e.g.
    /// `.periodic`) to decide whether a refresh is due.
    public let capturedAt: Date

    public init(cgImage: CGImage, scale: CGFloat, capturedAt: Date = .now) {
        self.cgImage = cgImage
        self.scale = scale
        self.capturedAt = capturedAt
    }

    public static func == (lhs: FlowNodeSnapshot, rhs: FlowNodeSnapshot) -> Bool {
        lhs.cgImage === rhs.cgImage
            && lhs.scale == rhs.scale
            && lhs.capturedAt == rhs.capturedAt
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(cgImage))
        hasher.combine(scale)
        hasher.combine(capturedAt)
    }
}
