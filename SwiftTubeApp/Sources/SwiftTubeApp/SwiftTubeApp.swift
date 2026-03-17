import SwiftUI

@main
struct SwiftTubeApp: App {
    @StateObject private var backendManager = BackendManager()
    @StateObject private var navigationModel = AppNavigationModel()
    @StateObject private var authSession = AuthSessionModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 960, minHeight: 640)
                .environmentObject(backendManager)
                .environmentObject(navigationModel)
                .environmentObject(authSession)
                .onAppear {
                    backendManager.start()
                    BrandAssets.installApplicationIcon()
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}
