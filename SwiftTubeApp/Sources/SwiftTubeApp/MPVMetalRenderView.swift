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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let scale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        metalLayer.frame = bounds
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        onLayoutChange?()
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

    func waitForRenderLayer() async -> MPVMetalLayer {
        while currentMetalLayer == nil {
            _ = view
            await Task.yield()
        }
        return currentMetalLayer!
    }

    func configure(onLayoutChange: @escaping () -> Void) {
        _ = view
        guard let renderView = view as? MPVRenderContainerView else { return }
        renderView.onLayoutChange = onLayoutChange
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
