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
        // Layer-hosting: the metal layer IS the view's backing layer.
        // AppKit places it in the layer tree at the view's position.
        layer = metalLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Called when SwiftUI explicitly sets the view's frame — update the drawable
    // size immediately so it's correct before moltenvk_reconfig reads it.
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
    // Explicit surface size passed from the overlay's geometry so we can force
    // the NSView frame directly — bypassing any SwiftUI/AppKit sizing ambiguity.
    let forcedSize: CGSize

    func makeNSViewController(context: Context) -> MPVRenderViewController {
        let controller = engine.renderController
        controller.configure(onLayoutChange: onLayoutChange)
        return controller
    }

    func updateNSViewController(_ controller: MPVRenderViewController, context: Context) {
        controller.configure(onLayoutChange: onLayoutChange)
        // Explicitly set the view's frame to the known surface size.
        // This guarantees setFrameSize is called with the correct dimensions,
        // which updates metalLayer.drawableSize before moltenvk_reconfig reads it.
        let targetFrame = CGRect(origin: .zero, size: forcedSize)
        if controller.view.frame != targetFrame, forcedSize.width > 1, forcedSize.height > 1 {
            controller.view.frame = targetFrame
        }
    }
}
