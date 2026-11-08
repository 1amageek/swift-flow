#if os(macOS)
import AppKit
import SwiftUI
import Testing

@testable import SwiftFlow

@MainActor @Suite struct CanvasOverlayTests {
    @Test func wheelOverInteractiveOverlayPansCanvasAndPreservesClicks() throws {
        let store = FlowStore<String>()
        let recorder = ClickRecorder()
        let root = NSHostingView(
            rootView: FlowCanvas(store: store).canvasOverlay {
                ButtonProbe(recorder: recorder)
                    .frame(width: 130, height: 22)
            })
        root.frame = .init(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(
            contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        root.layoutSubtreeIfNeeded()

        func findButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton { return button }
            for child in view.subviews {
                if let button = findButton(in: child) { return button }
            }
            return nil
        }
        let button = try #require(findButton(in: root))
        let point = root.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
        #expect(root.hitTest(point) === button)
        button.performClick(nil)
        #expect(recorder.count == 1)

        let raw = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 2, wheel1: 14, wheel2: 9, wheel3: 0))
        raw.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let event = try #require(NSEvent(cgEvent: raw))
        let before = store.viewport
        let receiver = try #require(root.hitTest(point))
        receiver.scrollWheel(with: event)
        #expect(store.viewport.offset.x == before.offset.x + event.scrollingDeltaX)
        #expect(store.viewport.offset.y == before.offset.y + event.scrollingDeltaY)
        #expect(store.viewport.zoom == before.zoom)
        #expect(recorder.count == 1)
        #expect(root.hitTest(point) === button)
        button.performClick(nil)
        #expect(recorder.count == 2)
    }

    private final class ClickRecorder: NSObject {
        var count = 0
        @objc func press(_ sender: NSButton) { count += 1 }
    }

    private struct ButtonProbe: NSViewRepresentable {
        let recorder: ClickRecorder

        func makeNSView(context: Context) -> NSButton {
            NSButton(title: "Connection", target: recorder, action: #selector(ClickRecorder.press(_:)))
        }

        func updateNSView(_ nsView: NSButton, context: Context) {}
    }
}
#endif
