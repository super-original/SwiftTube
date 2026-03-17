import AppKit
import SwiftUI

@main
struct SwiftTubeApp: App {
    @StateObject private var backendManager = BackendManager()
    @StateObject private var navigationModel = AppNavigationModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 960, minHeight: 640)
                .environmentObject(backendManager)
                .environmentObject(navigationModel)
                .onAppear {
                    backendManager.start()
                    BrandAssets.installApplicationIcon()
                }
        }
    }
}
