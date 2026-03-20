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
        // Use a regular layer-backed view (NOT layer-hosting via layer = metalLayer).
        // With layer-hosting, Apple docs state AppKit does NOT manage the custom layer's
        // geometry — so the layer stays at its original position when SwiftUI repositions
        // the view. Instead, add metalLayer as a sublayer so the AppKit-managed backing
        // layer handles positioning, and we only manage the sublayer size in layout().
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        let backing = CALayer()
        backing.backgroundColor = NSColor.black.cgColor
        return backing
    }

    // Called immediately when frame changes — update the Metal sublayer right away.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyMetalLayerBounds()
    }

    override func layout() {
        super.layout()
        // Attach sublayer on first layout
        if metalLayer.superlayer == nil, let hostLayer = layer {
            hostLayer.addSublayer(metalLayer)
        }
        applyMetalLayerBounds()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func applyMetalLayerBounds() {
        let scale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let newDrawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard newDrawableSize != lastDrawableSize,
              Int(newDrawableSize.width) > 1,
              Int(newDrawableSize.height) > 1 else { return }
        lastDrawableSize = newDrawableSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        metalLayer.contentsScale = scale
        CATransaction.commit()
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

// NSViewRepresentable (not NSViewControllerRepresentable) so SwiftUI directly
// manages the NSView's frame, guaranteeing the view — and thus its sublayers —
// resize and reposition correctly when the overlay rect changes.
struct MPVMetalRenderView: NSViewRepresentable {
    let engine: MPVPlaybackEngine
    let onLayoutChange: () -> Void

    func makeNSView(context: Context) -> MPVRenderContainerView {
        engine.renderController.configure(onLayoutChange: onLayoutChange)
        return engine.renderController.view as! MPVRenderContainerView
    }

    func updateNSView(_ nsView: MPVRenderContainerView, context: Context) {
        nsView.onLayoutChange = onLayoutChange
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MPVRenderContainerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
