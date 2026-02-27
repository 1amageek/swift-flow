#if os(macOS)
import SwiftUI

struct CanvasHostView<Content: View>: NSViewRepresentable {

    let onScroll: @MainActor (CGSize, CGPoint) -> Void
    let onMagnify: @MainActor (CGFloat, CGPoint) -> Void
    let cursorAt: @MainActor (CGPoint) -> NSCursor
    let onMouseExited: @MainActor () -> Void
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> CanvasNSHostView<Content> {
        let hostView = CanvasNSHostView<Content>()
        hostView.onScroll = onScroll
        hostView.onMagnify = onMagnify
        hostView.cursorAt = cursorAt
        hostView.onMouseExited = onMouseExited
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: hostView.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
        ])
        hostView.hostingView = hosting
        return hostView
    }

    func updateNSView(_ nsView: CanvasNSHostView<Content>, context: Context) {
        nsView.onScroll = onScroll
        nsView.onMagnify = onMagnify
        nsView.cursorAt = cursorAt
        nsView.onMouseExited = onMouseExited
        nsView.hostingView?.rootView = content
    }
}

final class CanvasNSHostView<Content: View>: NSView {

    var onScroll: (@MainActor (CGSize, CGPoint) -> Void)?
    var onMagnify: (@MainActor (CGFloat, CGPoint) -> Void)?
    var cursorAt: (@MainActor (CGPoint) -> NSCursor)?
    var onMouseExited: (@MainActor () -> Void)?
    var hostingView: NSHostingView<Content>?

    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        MainActor.assumeIsolated {
            onMouseExited?()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let dx: CGFloat
        let dy: CGFloat
        if event.hasPreciseScrollingDeltas {
            dx = event.scrollingDeltaX
            dy = event.scrollingDeltaY
        } else {
            dx = event.scrollingDeltaX * 10
            dy = event.scrollingDeltaY * 10
        }
        let location = flippedLocation(from: event)
        MainActor.assumeIsolated {
            onScroll?(CGSize(width: dx, height: dy), location)
        }
    }

    override func magnify(with event: NSEvent) {
        let location = flippedLocation(from: event)
        MainActor.assumeIsolated {
            onMagnify?(event.magnification, location)
        }
    }

    private func updateCursor(for event: NSEvent) {
        let location = flippedLocation(from: event)
        MainActor.assumeIsolated {
            let cursor = cursorAt?(location) ?? .arrow
            cursor.set()
        }
    }

    private func flippedLocation(from event: NSEvent) -> CGPoint {
        let location = convert(event.locationInWindow, from: nil)
        return CGPoint(x: location.x, y: bounds.height - location.y)
    }
}
#endif

#if os(iOS)
import SwiftUI
import UIKit

struct CanvasHostView<Content: View>: UIViewRepresentable {

    let onPan: @MainActor (CGSize) -> Void
    @ViewBuilder var content: Content

    func makeUIView(context: Context) -> CanvasUIHostView<Content> {
        let hostView = CanvasUIHostView<Content>()
        hostView.onPan = onPan
        let hosting = UIHostingController(rootView: content)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear
        hostView.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: hostView.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
        ])
        hostView.hostingController = hosting
        return hostView
    }

    func updateUIView(_ uiView: CanvasUIHostView<Content>, context: Context) {
        uiView.onPan = onPan
        uiView.hostingController?.rootView = content
    }
}

final class CanvasUIHostView<Content: View>: UIView {

    var onPan: (@MainActor (CGSize) -> Void)?
    var hostingController: UIHostingController<Content>?

    private var lastPanTranslation: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGestures()
    }

    private func setupGestures() {
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.minimumNumberOfTouches = 2
        panGesture.maximumNumberOfTouches = 2
        addGestureRecognizer(panGesture)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            lastPanTranslation = .zero
        case .changed:
            let delta = CGSize(
                width: translation.x - lastPanTranslation.x,
                height: translation.y - lastPanTranslation.y
            )
            lastPanTranslation = CGPoint(x: translation.x, y: translation.y)
            MainActor.assumeIsolated {
                onPan?(delta)
            }
        case .ended, .cancelled:
            lastPanTranslation = .zero
        default:
            break
        }
    }
}
#endif
