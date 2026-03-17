import SwiftUI

@main
struct SwiftTubeApp: App {
    @StateObject private var backendManager = BackendManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 960, minHeight: 640)
                .environmentObject(backendManager)
                .onAppear {
                    backendManager.start()
                }
        }
    }
}
