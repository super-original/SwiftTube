import AppKit
import SwiftUI

@MainActor
final class PlayerPictureInPictureCoordinator: NSObject, ObservableObject {
    enum CollapsedEdge {
        case left
        case right
    }

    @Published private(set) var isSupported = true
    @Published private(set) var isActive = false
    @Published private(set) var isCollapsed = false
    @Published private(set) var isPreparing = false
    @Published private(set) var collapsedEdge: CollapsedEdge = .right

    private var panel: PlayerPictureInPicturePanel?
    private var expandedFrame: NSRect?
    private var snapTask: Task<Void, Never>?
    private var isApplyingProgrammaticFrame = false
    private var isInteractivelyMoving = false

    var symbolName: String {
        isActive ? "pip.exit" : "pip.enter"
    }

    func start(
        playbackCoordinator: PlayerPlaybackCoordinator,
        engine: MPVPlaybackEngine,
        title: String?
    ) {
        guard !isActive else {
            expand()
            return
        }

        let panel = makePanel(title: title ?? "Picture in Picture")
        let rootView = PlayerPictureInPictureContent(
            playbackCoordinator: playbackCoordinator,
            pictureInPicture: self,
            engine: engine
        )
        let contentView = PlayerPictureInPicturePanelContentView()
        let hostingView = PlayerPictureInPictureHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        panel.contentView = contentView
        panel.pipCoordinator = self
        panel.delegate = self
        let aspect = max(playbackCoordinator.videoAspect, 1.0)
        panel.contentAspectRatio = NSSize(width: aspect, height: 1)

        let frame = defaultExpandedFrame(aspect: aspect)
        expandedFrame = frame
        isActive = true
        isCollapsed = false
        applyFrame(frame, to: panel, animate: false)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func stop() {
        snapTask?.cancel()
        snapTask = nil
        guard let panel else {
            isActive = false
            isCollapsed = false
            isPreparing = false
            return
        }
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
        expandedFrame = nil
        isActive = false
        isCollapsed = false
        isPreparing = false
    }

    func reset() {
        stop()
    }

    func toggleCollapsed() {
        isCollapsed ? expand() : collapse()
    }

    func collapse() {
        guard let panel, !isCollapsed else { return }
        collapse(to: nearestHorizontalEdge(for: panel.frame, on: panel.screen), from: panel.frame)
    }

    func collapse(to edge: CollapsedEdge, from sourceFrame: NSRect) {
        guard let panel, !isCollapsed else { return }
        snapTask?.cancel()
        expandedFrame = clampedExpandedFrame(sourceFrame, screen: panel.screen)
        collapsedEdge = edge
        isCollapsed = true
        applyFrame(collapsedFrame(from: sourceFrame, edge: edge, screen: panel.screen), to: panel, animate: true)
    }

    func expand() {
        guard let panel, isCollapsed else { return }
        isCollapsed = false
        let frame = clampedExpandedFrame(
            expandedFrame ?? defaultExpandedFrame(aspect: Double(panel.contentAspectRatio.width)),
            screen: panel.screen
        )
        expandedFrame = frame
        applyFrame(frame, to: panel, animate: true)
    }

    fileprivate func beginInteractiveMove() {
        isInteractivelyMoving = true
        snapTask?.cancel()
    }

    fileprivate func completeMove(optionHeld: Bool, velocity: CGVector) {
        guard isActive, !isCollapsed, let panel else { return }
        isInteractivelyMoving = false
        expandedFrame = panel.frame
        guard !optionHeld else { return }
        if let edge = collapseEdgeIfNeeded(panel: panel, velocity: velocity) {
            collapse(to: edge, from: panel.frame)
            return
        }
        snapToNearestCorner(panel: panel, velocity: velocity)
    }
}

extension PlayerPictureInPictureCoordinator: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard !isApplyingProgrammaticFrame,
              !isInteractivelyMoving,
              isActive,
              !isCollapsed,
              let panel = notification.object as? NSPanel else { return }
        expandedFrame = panel.frame
        scheduleSnap(panel: panel)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        snapTask?.cancel()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, !isCollapsed else { return }
        expandedFrame = panel.frame
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingPanel = notification.object as? NSPanel, closingPanel === panel else { return }
        snapTask?.cancel()
        panel = nil
        expandedFrame = nil
        isActive = false
        isCollapsed = false
        isPreparing = false
    }
}

private extension PlayerPictureInPictureCoordinator {
    var padding: CGFloat { 18 }
    var defaultWidth: CGFloat { 520 }
    var tabSize: CGSize { CGSize(width: 42, height: 84) }

    func makePanel(title: String) -> PlayerPictureInPicturePanel {
        let panel = PlayerPictureInPicturePanel(
            contentRect: .zero,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = NSSize(width: 360, height: 202)

        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { buttonType in
            panel.standardWindowButton(buttonType)?.isHidden = true
        }

        return panel
    }

    func defaultExpandedFrame(aspect: Double) -> NSRect {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let safeAspect = max(aspect, 1.0)
        let width = min(defaultWidth, max(360, visibleFrame.width * 0.42))
        let height = width / safeAspect
        return NSRect(
            x: visibleFrame.maxX - width - padding,
            y: visibleFrame.minY + padding,
            width: width,
            height: max(height, 202)
        )
    }

    func clampedExpandedFrame(_ frame: NSRect, screen: NSScreen?) -> NSRect {
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        let width = min(max(frame.width, 360), visibleFrame.width - padding * 2)
        let height = min(max(frame.height, 202), visibleFrame.height - padding * 2)
        let x = min(max(frame.minX, visibleFrame.minX + padding), visibleFrame.maxX - width - padding)
        let y = min(max(frame.minY, visibleFrame.minY + padding), visibleFrame.maxY - height - padding)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    func nearestHorizontalEdge(for frame: NSRect, on screen: NSScreen?) -> CollapsedEdge {
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        return frame.midX < visibleFrame.midX ? .left : .right
    }

    func collapsedFrame(from frame: NSRect, edge: CollapsedEdge, screen: NSScreen?) -> NSRect {
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        let size = tabSize
        let y = min(max(frame.midY - size.height / 2, visibleFrame.minY + padding), visibleFrame.maxY - size.height - padding)
        let x = edge == .left ? visibleFrame.minX : visibleFrame.maxX - size.width
        return NSRect(origin: CGPoint(x: x, y: y), size: size)
    }

    func scheduleSnap(panel: NSPanel) {
        snapTask?.cancel()
        snapTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled,
                  let currentPanel = self.panel,
                  currentPanel === panel,
                  self.isActive,
                  !self.isCollapsed else { return }
            guard !NSEvent.modifierFlags.contains(.option) else { return }
            self.snapToNearestCorner(panel: panel, velocity: .zero)
        }
    }

    func snapToNearestCorner(panel: NSPanel, velocity: CGVector) {
        let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let size = panel.frame.size
        let currentCenter = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let projectedCenter = projectedPoint(from: currentCenter, velocity: velocity)
        let candidates = [
            NSPoint(x: visibleFrame.minX + padding, y: visibleFrame.minY + padding),
            NSPoint(x: visibleFrame.maxX - size.width - padding, y: visibleFrame.minY + padding),
            NSPoint(x: visibleFrame.minX + padding, y: visibleFrame.maxY - size.height - padding),
            NSPoint(x: visibleFrame.maxX - size.width - padding, y: visibleFrame.maxY - size.height - padding)
        ]
        let nearest = candidates.min { lhs, rhs in
            let lhsCenter = NSPoint(x: lhs.x + size.width / 2, y: lhs.y + size.height / 2)
            let rhsCenter = NSPoint(x: rhs.x + size.width / 2, y: rhs.y + size.height / 2)
            return squaredDistance(lhsCenter, projectedCenter) < squaredDistance(rhsCenter, projectedCenter)
        } ?? panel.frame.origin
        let snappedFrame = NSRect(origin: nearest, size: size)
        expandedFrame = snappedFrame
        applyFrame(snappedFrame, to: panel, animate: true)
    }

    func collapseEdgeIfNeeded(panel: NSPanel, velocity: CGVector) -> CollapsedEdge? {
        let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let frame = panel.frame
        let leftOverlap = max(0, visibleFrame.minX - frame.minX)
        let rightOverlap = max(0, frame.maxX - visibleFrame.maxX)
        let leftIntent = leftOverlap >= min(84, frame.width * 0.22) || (leftOverlap >= 18 && velocity.dx < -420)
        let rightIntent = rightOverlap >= min(84, frame.width * 0.22) || (rightOverlap >= 18 && velocity.dx > 420)

        if leftIntent && leftOverlap >= rightOverlap { return .left }
        if rightIntent { return .right }
        return nil
    }

    func projectedPoint(from point: NSPoint, velocity: CGVector) -> NSPoint {
        let projectionTime: CGFloat = 0.32
        let maxProjection: CGFloat = 520
        let projectedX = max(-maxProjection, min(maxProjection, velocity.dx * projectionTime))
        let projectedY = max(-maxProjection, min(maxProjection, velocity.dy * projectionTime))
        return NSPoint(x: point.x + projectedX, y: point.y + projectedY)
    }

    func squaredDistance(_ lhs: NSPoint, _ rhs: NSPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    func applyFrame(_ frame: NSRect, to panel: NSPanel, animate: Bool) {
        isApplyingProgrammaticFrame = true
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        Task { @MainActor [weak self] in
            if animate {
                try? await Task.sleep(nanoseconds: 260_000_000)
            }
            self?.isApplyingProgrammaticFrame = false
        }
    }
}

@MainActor
private final class PlayerPictureInPicturePanel: NSPanel {
    weak var pipCoordinator: PlayerPictureInPictureCoordinator?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        pipCoordinator?.completeMove(optionHeld: event.modifierFlags.contains(.option), velocity: .zero)
    }
}

@MainActor
private final class PlayerPictureInPicturePanelContentView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
private final class PlayerPictureInPictureHostingView<Content: View>: NSHostingView<Content> {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

private struct PlayerPictureInPictureContent: View {
    @ObservedObject var playbackCoordinator: PlayerPlaybackCoordinator
    @ObservedObject var pictureInPicture: PlayerPictureInPictureCoordinator
    let engine: MPVPlaybackEngine

    @State private var hoverExitTask: Task<Void, Never>? = nil

    var body: some View {
        GeometryReader { geo in
            if pictureInPicture.isCollapsed {
                collapsedButton
                    .frame(width: geo.size.width, height: geo.size.height)
            } else {
                let videoSize = aspectFitSize(container: geo.size, aspect: playbackCoordinator.videoAspect)

                ZStack {
                    Color.black

                    ZStack {
                        MPVMetalRenderView(
                            engine: engine,
                            onLayoutChange: playbackCoordinator.handlePlayerSurfaceLayoutChange
                        )
                        .id(engine.id)

                        PlayerPictureInPictureInteractionView(
                            onHover: handleHover,
                            onMove: handlePointerMove,
                            onClick: playbackCoordinator.togglePlayback,
                            onDragBegan: pictureInPicture.beginInteractiveMove,
                            onDragEnded: { optionHeld, velocity in
                                pictureInPicture.completeMove(optionHeld: optionHeld, velocity: velocity)
                            }
                        )

                        pipChrome
                    }
                    .frame(width: videoSize.width, height: videoSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var pipChrome: some View {
        GeometryReader { geo in
            let scale = controlScale(for: geo.size)
            let chromeWidth = max(1, geo.size.width - 28)

            ZStack {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [Color.black.opacity(0.45), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 84 * scale)

                    Spacer(minLength: 0)

                    LinearGradient(
                        colors: [.clear, Color.black.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 150 * scale)
                }
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    Spacer()

                    PlayerControlBar(coordinator: playbackCoordinator)
                        .frame(width: chromeWidth / scale)
                        .scaleEffect(scale, anchor: .bottom)
                        .frame(width: chromeWidth, height: 96 * scale, alignment: .bottom)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14 * scale)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .opacity(playbackCoordinator.controlsVisible ? 1 : 0)
        .allowsHitTesting(playbackCoordinator.controlsVisible)
        .animation(.linear(duration: 0.1), value: playbackCoordinator.controlsVisible)
    }

    private func controlScale(for size: CGSize) -> CGFloat {
        let widthScale = (size.width - 28) / 720
        let heightScale = size.height / 340
        return min(1, max(0.55, min(widthScale, heightScale)))
    }

    private func aspectFitSize(container: CGSize, aspect: Double) -> CGSize {
        guard container.width > 1, container.height > 1 else { return container }
        let safeAspect = max(aspect, 1)
        let containerAspect = container.width / container.height

        if containerAspect > safeAspect {
            return CGSize(width: container.height * safeAspect, height: container.height)
        }
        return CGSize(width: container.width, height: container.width / safeAspect)
    }

    private func handleHover(_ hovering: Bool) {
        if hovering {
            hoverExitTask?.cancel()
            hoverExitTask = nil
            playbackCoordinator.setHovering(true)
        } else {
            hoverExitTask?.cancel()
            hoverExitTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
                playbackCoordinator.setHovering(false)
            }
        }
    }

    private func handlePointerMove() {
        if playbackCoordinator.controlsVisible == false {
            playbackCoordinator.setHovering(true)
        }
        playbackCoordinator.handlePointerMovement()
    }

    private var collapsedButton: some View {
        Button {
            pictureInPicture.expand()
        } label: {
            ZStack {
                Capsule()
                    .fill(.clear)

                Image(systemName: expandSymbolName)
                    .font(.system(size: 22, weight: .bold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.glass(.regular.interactive()))
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .foregroundStyle(.white)
        .accessibilityLabel("Show Picture in Picture")
    }

    private var expandSymbolName: String {
        pictureInPicture.collapsedEdge == .left ? "chevron.right" : "chevron.left"
    }
}

private struct PlayerPictureInPictureInteractionView: NSViewRepresentable {
    let onHover: (Bool) -> Void
    let onMove: () -> Void
    let onClick: () -> Void
    let onDragBegan: () -> Void
    let onDragEnded: (Bool, CGVector) -> Void

    func makeNSView(context: Context) -> PlayerPictureInPictureInteractionNSView {
        let view = PlayerPictureInPictureInteractionNSView()
        view.onHover = onHover
        view.onMove = onMove
        view.onClick = onClick
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: PlayerPictureInPictureInteractionNSView, context: Context) {
        nsView.onHover = onHover
        nsView.onMove = onMove
        nsView.onClick = onClick
        nsView.onDragBegan = onDragBegan
        nsView.onDragEnded = onDragEnded
    }
}

@MainActor
private final class PlayerPictureInPictureInteractionNSView: NSView {
    var onHover: ((Bool) -> Void)?
    var onMove: (() -> Void)?
    var onClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: ((Bool, CGVector) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var mouseDownLocation: NSPoint?
    private var windowStartOrigin: NSPoint?
    private var lastMouseLocation: NSPoint?
    private var lastMouseTime: TimeInterval?
    private var velocity: CGVector = .zero
    private var didDrag = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        let resizeMargin: CGFloat = 8
        guard bounds.insetBy(dx: resizeMargin, dy: resizeMargin).contains(point) else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [
            .activeAlways,
            .inVisibleRect,
            .mouseEnteredAndExited,
            .mouseMoved
        ]
        let trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func mouseMoved(with event: NSEvent) {
        onMove?()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = NSEvent.mouseLocation
        windowStartOrigin = window?.frame.origin
        lastMouseLocation = mouseDownLocation
        lastMouseTime = event.timestamp
        velocity = .zero
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownLocation, let windowStartOrigin, let window else { return }
        let currentLocation = NSEvent.mouseLocation
        let delta = CGVector(
            dx: currentLocation.x - mouseDownLocation.x,
            dy: currentLocation.y - mouseDownLocation.y
        )

        if !didDrag, hypot(delta.dx, delta.dy) > 4 {
            didDrag = true
            onDragBegan?()
        }

        if didDrag {
            window.setFrameOrigin(NSPoint(
                x: windowStartOrigin.x + delta.dx,
                y: windowStartOrigin.y + delta.dy
            ))
            updateVelocity(currentLocation: currentLocation, timestamp: event.timestamp)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            updateVelocity(currentLocation: NSEvent.mouseLocation, timestamp: event.timestamp)
            onDragEnded?(event.modifierFlags.contains(.option), velocity)
        } else {
            onClick?()
        }

        mouseDownLocation = nil
        windowStartOrigin = nil
        lastMouseLocation = nil
        lastMouseTime = nil
        velocity = .zero
        didDrag = false
    }

    private func updateVelocity(currentLocation: NSPoint, timestamp: TimeInterval) {
        defer {
            lastMouseLocation = currentLocation
            lastMouseTime = timestamp
        }

        guard let lastMouseLocation, let lastMouseTime else { return }
        let elapsed = max(0.001, timestamp - lastMouseTime)
        let instant = CGVector(
            dx: (currentLocation.x - lastMouseLocation.x) / elapsed,
            dy: (currentLocation.y - lastMouseLocation.y) / elapsed
        )
        velocity = CGVector(
            dx: (velocity.dx * 0.45) + (instant.dx * 0.55),
            dy: (velocity.dy * 0.45) + (instant.dy * 0.55)
        )
    }
}
