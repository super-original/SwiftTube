import AppKit
import SwiftUI

enum SettingsWindowSupport {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("SwiftTubeSettingsWindow")
    static let fixedSize = CGSize(width: 980, height: 650)
    static let minSize = CGSize(width: 760, height: 520)
    static let maxSize = CGSize(width: 1_440, height: 1_000)

    @MainActor
    static func configure(_ window: NSWindow) {
        window.identifier = windowIdentifier
        window.title = "SwiftTube Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
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

        window.standardWindowButton(.zoomButton)?.isEnabled = true
        removeSidebarToggle(from: window)
    }

    @MainActor
    static func preventSidebarCollapse(in window: NSWindow) {
        applySidebarConstraint(in: window)
        Task { @MainActor in
            for _ in 0..<20 {
                await Task.yield()
                applySidebarConstraint(in: window)
                removeSidebarToggle(from: window)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    @MainActor
    private static func applySidebarConstraint(in window: NSWindow) {
        guard let splitViewController = findSplitViewController(in: window.contentViewController),
              let sidebarItem = splitViewController.splitViewItems.first else { return }
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 205
    }

    @MainActor
    private static func removeSidebarToggle(from window: NSWindow) {
        guard let toolbar = window.toolbar else { return }
        while let index = toolbar.items.firstIndex(where: { item in
            item.itemIdentifier == .toggleSidebar
                || item.itemIdentifier.rawValue.localizedCaseInsensitiveContains("sidebar")
                || item.label.localizedCaseInsensitiveContains("sidebar")
                || item.toolTip?.localizedCaseInsensitiveContains("sidebar") == true
        }) {
            toolbar.removeItem(at: index)
        }
    }

    @MainActor
    private static func findSplitViewController(in controller: NSViewController?) -> NSSplitViewController? {
        guard let controller else { return nil }
        if let splitViewController = controller as? NSSplitViewController {
            return splitViewController
        }
        for child in controller.children {
            if let match = findSplitViewController(in: child) {
                return match
            }
        }
        return nil
    }
}

extension View {
    func removeSidebarToggle() -> some View {
        toolbar(removing: .sidebarToggle)
    }
}
