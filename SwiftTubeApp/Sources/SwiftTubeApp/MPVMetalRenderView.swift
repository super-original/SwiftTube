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
        autoresizingMask = [.width, .height]
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Called immediately when frame changes — update the Metal layer right away
    // so the drawable size is current before MPV renders the next frame.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyMetalLayerSize()
    }

    override func layout() {
        super.layout()
        applyMetalLayerSize()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func applyMetalLayerSize() {
        let scale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let newDrawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        // Only fire the callback when the size actually changes to avoid redundant reconfigs
        guard newDrawableSize != lastDrawableSize,
              Int(newDrawableSize.width) > 1,
              Int(newDrawableSize.height) > 1 else { return }
        lastDrawableSize = newDrawableSize
        metalLayer.frame = bounds
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = newDrawableSize
        onLayoutChange?()
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

    func waitForDisplayReady() async -> MPVMetalLayer {
        _ = view
        while true {
            if let layer = readyLayerIfAvailable() {
                return layer
            }
            await Task.yield()
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

struct MPVMetalRenderView: NSViewControllerRepresentable {
    let engine: MPVPlaybackEngine
    let onLayoutChange: () -> Void

    func makeNSViewController(context: Context) -> MPVRenderViewController {
        let controller = engine.renderController
        controller.configure(onLayoutChange: onLayoutChange)
        return controller
    }

    func updateNSViewController(_ controller: MPVRenderViewController, context: Context) {
        controller.configure(onLayoutChange: onLayoutChange)
    }
}
