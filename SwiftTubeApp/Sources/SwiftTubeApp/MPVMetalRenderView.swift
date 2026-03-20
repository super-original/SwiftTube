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

    // When first added to a superview, fill it immediately.
    // autoresizingMask = [.width, .height] does proportional resize, so if the view
    // starts at .zero (from loadView's init(frame: .zero)) it stays at .zero forever.
    // Setting the frame here bootstraps the proportional fill correctly.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let sv = superview, sv.bounds.width > 1, sv.bounds.height > 1 else { return }
        frame = sv.bounds
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
