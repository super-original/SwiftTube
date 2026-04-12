import AppKit
import SwiftUI

private struct SettingsWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings...") {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

@main
struct SwiftTubeApp: App {
    @StateObject private var backendManager = BackendManager()
    @StateObject private var navigationModel = AppNavigationModel()
    @StateObject private var authSession = AuthSessionModel()
    @ObservedObject private var settings = AppSettings.shared

    init() {
        NSSplitViewItem.swizzleSwiftTubeSettingsCanCollapse()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 960, minHeight: 640)
                .environmentObject(backendManager)
                .environmentObject(navigationModel)
                .environmentObject(authSession)
                .preferredColorScheme(settings.preferredColorScheme)
                .onAppear {
                    backendManager.start()
                    BrandAssets.installApplicationIcon()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            SettingsWindowCommands()
        }

        Window("SwiftTube", id: "settings") {
            SettingsView()
                .preferredColorScheme(settings.preferredColorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentSize)
        .defaultSize(width: 980, height: 650)
    }
}
