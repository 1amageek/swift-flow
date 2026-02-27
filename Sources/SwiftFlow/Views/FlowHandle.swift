import SwiftUI

public struct FlowHandle: View {

    /// Handle diameter used by DefaultNodeContent for layout.
    static let diameter: CGFloat = 10

    let handleID: String
    let type: HandleType
    let position: HandlePosition

    public init(_ handleID: String, type: HandleType, position: HandlePosition = .right) {
        self.handleID = handleID
        self.type = type
        self.position = position
    }

    public var body: some View {
        Circle()
            .fill(Color.gray)
            .overlay {
                Circle()
                    .strokeBorder(.background, lineWidth: 1.5)
            }
            .frame(width: Self.diameter, height: Self.diameter)
    }
}
