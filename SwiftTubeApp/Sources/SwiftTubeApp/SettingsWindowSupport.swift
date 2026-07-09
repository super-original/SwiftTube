import AppKit
import SwiftUI

enum SettingsWindowSupport {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("SwiftTubeSettingsWindow")
    static let fixedSize = CGSize(width: 980, height: 650)
    static let minSize = fixedSize
    static let maxSize = fixedSize

    @MainActor
    static func configure(_ window: NSWindow) {
        window.identifier = windowIdentifier
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = false
        window.minSize = minSize
        window.contentMinSize = minSize
        window.maxSize = maxSize
        window.contentMaxSize = maxSize

        var collectionBehavior = window.collectionBehavior
        collectionBehavior.remove(.fullScreenPrimary)
        collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior = collectionBehavior

        if let zoomButton = window.standardWindowButton(.zoomButton) {
            zoomButton.target = nil
            zoomButton.action = nil
            zoomButton.isEnabled = false
        }
    }
}

extension View {
    func removeSidebarToggle() -> some View {
        toolbar(removing: .sidebarToggle)
    }
}
