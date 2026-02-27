import Foundation

public protocol ConnectionValidating: Sendable {
    func validate(_ proposal: ConnectionProposal) -> Bool
}

public struct DefaultConnectionValidator: ConnectionValidating, Sendable {
    public init() {}

    public func validate(_ proposal: ConnectionProposal) -> Bool {
        proposal.sourceNodeID != proposal.targetNodeID
    }
}
