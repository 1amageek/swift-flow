import SwiftUI

public struct FlowHandle: View {

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
            .fill(type == .source ? Color.blue : Color.green)
            .frame(width: 12, height: 12)
    }
}
