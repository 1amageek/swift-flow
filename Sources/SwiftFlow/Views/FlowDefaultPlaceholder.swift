import SwiftUI

/// Default placeholder used by `LiveNode` when the rasterize path has no
/// snapshot to draw yet.
public struct FlowDefaultPlaceholder: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.08))
    }
}
