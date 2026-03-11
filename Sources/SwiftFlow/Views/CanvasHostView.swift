import Foundation

/// Internal drop event used between CanvasHostView and FlowCanvas.
/// Contains raw screen-coordinate data before hit testing.
enum CanvasDropEvent {
    case updated([NSItemProvider], CGPoint)
    case exited
    case performed([NSItemProvider], CGPoint)
}

#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct CanvasHostView<Content: View>: NSViewRepresentable {

    let onScroll: @MainActor (CGSize, CGPoint) -> Void
    let onMagnify: @MainActor (CGFloat, CGPoint) -> Void
    let cursorAt: @MainActor (CGPoint) -> NSCursor
    let onMouseExited: @MainActor () -> Void
    var registeredDropTypes: [String] = []
    var onDrop: (@MainActor (CanvasDropEvent) -> Bool)? = nil
    var onKeyDown: (@MainActor (UInt16) -> Bool)? = nil
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> CanvasNSHostView<Content> {
        let hostView = CanvasNSHostView<Content>()
        hostView.onScroll = onScroll
        hostView.onMagnify = onMagnify
        hostView.cursorAt = cursorAt
        hostView.onMouseExited = onMouseExited
        hostView.onDrop = onDrop
        hostView.onKeyDown = onKeyDown
        hostView.updateRegisteredTypes(registeredDropTypes)
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
        nsView.onDrop = onDrop
        nsView.onKeyDown = onKeyDown
        nsView.updateRegisteredTypes(registeredDropTypes)
        nsView.hostingView?.rootView = content
    }
}

final class CanvasNSHostView<Content: View>: NSView {

    var onScroll: (@MainActor (CGSize, CGPoint) -> Void)?
    var onMagnify: (@MainActor (CGFloat, CGPoint) -> Void)?
    var cursorAt: (@MainActor (CGPoint) -> NSCursor)?
    var onMouseExited: (@MainActor () -> Void)?
    var hostingView: NSHostingView<Content>?
    var onDrop: (@MainActor (CanvasDropEvent) -> Bool)?
    var onKeyDown: (@MainActor (UInt16) -> Bool)?

    private var currentDropTypes: [String] = []

    func updateRegisteredTypes(_ types: [String]) {
        guard types != currentDropTypes else { return }
        currentDropTypes = types
        if types.isEmpty {
            unregisterDraggedTypes()
        } else {
            registerForDraggedTypes(types.map { NSPasteboard.PasteboardType($0) })
        }
    }

    private var cachedProviders: [NSItemProvider] = []

    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        var handled = false
        MainActor.assumeIsolated {
            handled = onKeyDown?(event.keyCode) ?? false
        }
        if !handled {
            super.keyDown(with: event)
        }
    }

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

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        cachedProviders = extractProviders(from: sender)
        let location = flippedLocation(from: sender)
        var accepted = false
        MainActor.assumeIsolated {
            accepted = onDrop?(.updated(cachedProviders, location)) ?? false
        }
        return accepted ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let location = flippedLocation(from: sender)
        var accepted = false
        MainActor.assumeIsolated {
            accepted = onDrop?(.updated(cachedProviders, location)) ?? false
        }
        return accepted ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        cachedProviders = []
        MainActor.assumeIsolated {
            _ = onDrop?(.exited)
        }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let location = flippedLocation(from: sender)
        var accepted = false
        MainActor.assumeIsolated {
            accepted = onDrop?(.performed(cachedProviders, location)) ?? false
        }
        cachedProviders = []
        return accepted
    }

    // MARK: - Coordinate Helpers

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

    private func flippedLocation(from sender: any NSDraggingInfo) -> CGPoint {
        let location = convert(sender.draggingLocation, from: nil)
        return CGPoint(x: location.x, y: bounds.height - location.y)
    }

    // MARK: - Provider Extraction

    /// Build an NSItemProvider from the dragging pasteboard.
    ///
    /// Uses the fundamental `pasteboard.types` / `pasteboard.data(forType:)` API
    /// which works reliably for both SwiftUI `.draggable()` (NSItemProvider-backed)
    /// and legacy NSPasteboard drags.
    private func extractProviders(from sender: any NSDraggingInfo) -> [NSItemProvider] {
        let pasteboard = sender.draggingPasteboard
        guard let types = pasteboard.types, !types.isEmpty else { return [] }
        let provider = NSItemProvider()
        for type in types {
            guard let data = pasteboard.data(forType: type) else { continue }
            provider.registerDataRepresentation(
                forTypeIdentifier: type.rawValue,
                visibility: .all
            ) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider.registeredTypeIdentifiers.isEmpty ? [] : [provider]
    }
}
#endif

#if os(iOS)
import SwiftUI
import UIKit

struct CanvasHostView<Content: View>: UIViewRepresentable {

    let onPan: @MainActor (CGSize) -> Void
    var registeredDropTypes: [String] = []
    var onDrop: (@MainActor (CanvasDropEvent) -> Bool)? = nil
    @ViewBuilder var content: Content

    func makeUIView(context: Context) -> CanvasUIHostView<Content> {
        let hostView = CanvasUIHostView<Content>()
        hostView.onPan = onPan
        hostView.onDrop = onDrop
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
        uiView.onDrop = onDrop
        uiView.hostingController?.rootView = content
    }
}

final class CanvasUIHostView<Content: View>: UIView, UIDropInteractionDelegate {

    var onPan: (@MainActor (CGSize) -> Void)?
    var hostingController: UIHostingController<Content>?

    var onDrop: (@MainActor (CanvasDropEvent) -> Bool)? {
        didSet {
            setupDropIfNeeded()
        }
    }

    private var dropInteraction: UIDropInteraction?
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

    private func setupDropIfNeeded() {
        guard onDrop != nil, dropInteraction == nil else { return }
        let interaction = UIDropInteraction(delegate: self)
        addInteraction(interaction)
        dropInteraction = interaction
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

    // MARK: - UIDropInteractionDelegate

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        return onDrop != nil
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        let location = session.location(in: self)
        let providers = session.items.map { $0.itemProvider }
        var accepted = false
        MainActor.assumeIsolated {
            accepted = onDrop?(.updated(providers, location)) ?? false
        }
        return UIDropProposal(operation: accepted ? .copy : .cancel)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: any UIDropSession) {
        MainActor.assumeIsolated {
            _ = onDrop?(.exited)
        }
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        let location = session.location(in: self)
        let providers = session.items.map { $0.itemProvider }
        MainActor.assumeIsolated {
            _ = onDrop?(.performed(providers, location))
        }
    }
}
#endif
