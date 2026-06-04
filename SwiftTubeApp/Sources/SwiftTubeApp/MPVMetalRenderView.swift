import AppKit
import SwiftUI

@MainActor
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

@MainActor
final class MPVRenderContainerView: NSView {
    let metalLayer = MPVMetalLayer()
    var onLayoutChange: (() -> Void)?
    private var lastDrawableSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyMetalLayerBounds(size: newSize)
    }

    override func layout() {
        super.layout()
        applyMetalLayerBounds(size: bounds.size)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func applyMetalLayerBounds(size: CGSize) {
        let scale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let newDrawableSize = CGSize(width: size.width * scale, height: size.height * scale)
        guard newDrawableSize != lastDrawableSize,
              Int(newDrawableSize.width) > 1,
              Int(newDrawableSize.height) > 1 else { return }
        lastDrawableSize = newDrawableSize
        metalLayer.frame = CGRect(origin: .zero, size: size)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = newDrawableSize
        PlaybackDebugLogger.log("mpv render surface bounds size=\(Int(size.width))x\(Int(size.height)) drawable=\(Int(newDrawableSize.width))x\(Int(newDrawableSize.height))")
        onLayoutChange?()
    }
}

// Thin NSView wrapper. NSViewRepresentable gives SwiftUI direct frame control —
// it calls setFrame:/setFrameSize: directly when the overlay rect changes.
// We propagate that size immediately to MPVRenderContainerView so drawableSize
// is always current before moltenvk_reconfig reads it.
@MainActor
final class MPVSurfaceHostView: NSView {
    let renderView: MPVRenderContainerView

    init(renderView: MPVRenderContainerView) {
        self.renderView = renderView
        super.init(frame: .zero)
        addSubview(renderView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Directly propagate to the render view — no autoresizing ambiguity.
        if newSize.width > 1, newSize.height > 1 {
            renderView.frame = CGRect(origin: .zero, size: newSize)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class MPVRenderViewController: NSViewController {
    override func loadView() {
        view = MPVRenderContainerView()
    }

    var currentMetalLayer: MPVMetalLayer? {
        (view as? MPVRenderContainerView)?.metalLayer
    }

    var currentDrawableSize: CGSize {
        currentMetalLayer?.drawableSize ?? .zero
    }

    var isDisplayAttached: Bool {
        (view as? MPVRenderContainerView)?.window != nil
    }

    func renderSurfaceDescription() -> String {
        let drawableSize = currentDrawableSize
        return "attached=\(isDisplayAttached) drawable=\(Int(drawableSize.width))x\(Int(drawableSize.height))"
    }

    func waitForDisplayReady(timeout: TimeInterval = 2) async throws -> MPVMetalLayer {
        _ = view
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            try Task.checkCancellation()
            if let layer = readyLayerIfAvailable() {
                return layer
            }
            if Date() >= deadline {
                throw NSError(
                    domain: "SwiftTube.MPVRender",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for mpv render surface."]
                )
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func configure(onLayoutChange: @escaping () -> Void) {
        _ = view
        guard let renderView = view as? MPVRenderContainerView else { return }
        renderView.onLayoutChange = onLayoutChange
    }

    private func readyLayerIfAvailable() -> MPVMetalLayer? {
        guard let renderView = view as? MPVRenderContainerView else { return nil }
        guard renderView.window != nil else { return nil }
        guard renderView.metalLayer.drawableSize.width > 1, renderView.metalLayer.drawableSize.height > 1 else {
            return nil
        }
        return renderView.metalLayer
    }
}

struct MPVMetalRenderView: NSViewRepresentable {
    let engine: MPVPlaybackEngine
    let onLayoutChange: () -> Void

    func makeNSView(context: Context) -> MPVSurfaceHostView {
        engine.renderController.configure(onLayoutChange: onLayoutChange)
        let renderView = engine.renderController.view as! MPVRenderContainerView
        return MPVSurfaceHostView(renderView: renderView)
    }

    func updateNSView(_ nsView: MPVSurfaceHostView, context: Context) {
        nsView.renderView.onLayoutChange = onLayoutChange
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MPVSurfaceHostView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
