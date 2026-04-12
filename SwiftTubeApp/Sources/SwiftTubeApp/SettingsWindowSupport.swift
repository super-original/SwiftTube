import AppKit
import SwiftUI

enum SettingsWindowSupport {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("SwiftTubeSettingsWindow")
    static let minSize = CGSize(width: 920, height: 620)
    static let maxSize = CGSize(width: 1360, height: 920)

    @MainActor
    static func configure(_ window: NSWindow) {
        window.identifier = windowIdentifier
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = true
        window.minSize = minSize
        window.contentMinSize = minSize
        window.maxSize = maxSize
        window.contentMaxSize = maxSize

        var collectionBehavior = window.collectionBehavior
        collectionBehavior.remove(.fullScreenPrimary)
        collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior = collectionBehavior

        if let zoomButton = window.standardWindowButton(.zoomButton) {
            zoomButton.target = window
            zoomButton.action = #selector(NSWindow.performZoom(_:))
        }
    }
}

extension View {
    func removeSidebarToggle() -> some View {
        toolbar(removing: .sidebarToggle)
            .toolbar {
                Color.clear
            }
    }
}

extension NSSplitViewItem {
    @nonobjc private static let swiftTubeSettingsSwizzler: Void = {
        let originalSelector = #selector(getter: canCollapse)
        let swizzledSelector = #selector(getter: swiftTubeSettingsCanCollapse)

        guard let originalMethod = class_getInstanceMethod(NSSplitViewItem.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(NSSplitViewItem.self, swizzledSelector) else {
            return
        }

        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()

    @MainActor @objc private var swiftTubeSettingsCanCollapse: Bool {
        if viewController.view.window?.identifier == SettingsWindowSupport.windowIdentifier {
            return false
        }
        return self.swiftTubeSettingsCanCollapse
    }

    static func swizzleSwiftTubeSettingsCanCollapse() {
        _ = swiftTubeSettingsSwizzler
    }
}
