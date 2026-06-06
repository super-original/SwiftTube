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
        snapTask?.cancel()
        expandedFrame = panel.frame
        let edge = nearestHorizontalEdge(for: panel.frame, on: panel.screen)
        collapsedEdge = edge
        isCollapsed = true
        applyFrame(collapsedFrame(from: panel.frame, edge: edge, screen: panel.screen), to: panel, animate: true)
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

    fileprivate func completeMove(optionHeld: Bool) {
        guard isActive, !isCollapsed, let panel else { return }
        expandedFrame = panel.frame
        guard !optionHeld else { return }
        snapToNearestCorner(panel: panel)
    }
}

extension PlayerPictureInPictureCoordinator: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard !isApplyingProgrammaticFrame, isActive, !isCollapsed, let panel = notification.object as? NSPanel else { return }
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
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .black
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
            self.snapToNearestCorner(panel: panel)
        }
    }

    func snapToNearestCorner(panel: NSPanel) {
        let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let size = panel.frame.size
        let candidates = [
            NSPoint(x: visibleFrame.minX + padding, y: visibleFrame.minY + padding),
            NSPoint(x: visibleFrame.maxX - size.width - padding, y: visibleFrame.minY + padding),
            NSPoint(x: visibleFrame.minX + padding, y: visibleFrame.maxY - size.height - padding),
            NSPoint(x: visibleFrame.maxX - size.width - padding, y: visibleFrame.maxY - size.height - padding)
        ]
        let current = panel.frame.origin
        let nearest = candidates.min { lhs, rhs in
            squaredDistance(lhs, current) < squaredDistance(rhs, current)
        } ?? current
        let snappedFrame = NSRect(origin: nearest, size: size)
        expandedFrame = snappedFrame
        applyFrame(snappedFrame, to: panel, animate: true)
    }

    func squaredDistance(_ lhs: NSPoint, _ rhs: NSPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    func applyFrame(_ frame: NSRect, to panel: NSPanel, animate: Bool) {
        isApplyingProgrammaticFrame = true
        panel.setFrame(frame, display: true, animate: animate)
        Task { @MainActor [weak self] in
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
        pipCoordinator?.completeMove(optionHeld: event.modifierFlags.contains(.option))
    }
}

@MainActor
private final class PlayerPictureInPicturePanelContentView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

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
        ZStack {
            Color.black

            if pictureInPicture.isCollapsed {
                collapsedButton
            } else {
                MPVMetalRenderView(
                    engine: engine,
                    onLayoutChange: playbackCoordinator.handlePlayerSurfaceLayoutChange
                )
                .id(engine.id)

                PlayerPictureInPictureHoverTrackingView { hovering in
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
                } onMove: {
                    if playbackCoordinator.controlsVisible == false {
                        playbackCoordinator.setHovering(true)
                    }
                    playbackCoordinator.handlePointerMovement()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                pipChrome
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
                    HStack {
                        Spacer()
                        collapseButton
                            .scaleEffect(scale, anchor: .topTrailing)
                            .frame(width: 30 * scale, height: 30 * scale)
                    }
                    .padding(.top, 12 * scale)
                    .padding(.horizontal, 12 * scale)

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

    private var collapseButton: some View {
        Button {
            pictureInPicture.collapse()
        } label: {
            Image(systemName: collapseSymbolName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass(.regular.interactive()))
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .accessibilityLabel("Collapse Picture in Picture")
    }

    private var collapsedButton: some View {
        Button {
            pictureInPicture.expand()
        } label: {
            Image(systemName: expandSymbolName)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 42, height: 84)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel("Show Picture in Picture")
    }

    private var collapseSymbolName: String {
        pictureInPicture.collapsedEdge == .left ? "chevron.left" : "chevron.right"
    }

    private var expandSymbolName: String {
        pictureInPicture.collapsedEdge == .left ? "chevron.right" : "chevron.left"
    }
}

private struct PlayerPictureInPictureHoverTrackingView: NSViewRepresentable {
    let onHover: (Bool) -> Void
    let onMove: () -> Void

    func makeNSView(context: Context) -> PlayerPictureInPictureHoverView {
        let view = PlayerPictureInPictureHoverView()
        view.onHover = onHover
        view.onMove = onMove
        return view
    }

    func updateNSView(_ nsView: PlayerPictureInPictureHoverView, context: Context) {
        nsView.onHover = onHover
        nsView.onMove = onMove
    }
}

@MainActor
private final class PlayerPictureInPictureHoverView: NSView {
    var onHover: ((Bool) -> Void)?
    var onMove: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
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
}
