import CoreGraphics
import Testing
@testable import SwiftFlow

@Suite("LiveNodeSnapshotContext Tests")
@MainActor
struct LiveNodeSnapshotContextTests {

    @Test("Immediate writes and requests are skipped while deferred")
    func immediateWritesAndRequestsAreSkippedWhileDeferred() async throws {
        let counter = SnapshotWriteCounter()
        let context = LiveNodeSnapshotContext(
            nodeID: "node",
            write: { _ in
                counter.increment()
            },
            registerCapture: { _ in },
            unregisterCapture: {},
            allowsImmediateSnapshotWrites: {
                false
            },
            requestCapture: {
                counter.increment()
            }
        )

        context.write(try makeSnapshot())
        await context.requestCapture()

        #expect(counter.count == 0)
    }

    @Test("Immediate writes and requests run when allowed")
    func immediateWritesAndRequestsRunWhenAllowed() async throws {
        let counter = SnapshotWriteCounter()
        let context = LiveNodeSnapshotContext(
            nodeID: "node",
            write: { _ in
                counter.increment()
            },
            registerCapture: { _ in },
            unregisterCapture: {},
            allowsImmediateSnapshotWrites: {
                true
            },
            requestCapture: {
                counter.increment()
            }
        )

        context.write(try makeSnapshot())
        await context.requestCapture()

        #expect(counter.count == 2)
    }

    private func makeSnapshot() throws -> FlowNodeSnapshot {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SnapshotContextTestError.contextCreationFailed
        }
        guard let image = context.makeImage() else {
            throw SnapshotContextTestError.imageCreationFailed
        }
        return FlowNodeSnapshot(cgImage: image, scale: 1)
    }
}

@MainActor
private final class SnapshotWriteCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private enum SnapshotContextTestError: Error {
    case contextCreationFailed
    case imageCreationFailed
}
