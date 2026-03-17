import Foundation

enum AppRoute: Equatable {
    case home
    case video(VideoItem)

    var video: VideoItem? {
        if case .video(let item) = self {
            return item
        }
        return nil
    }
}

@MainActor
final class AppNavigationModel: ObservableObject {
    @Published private(set) var currentRoute: AppRoute = .home

    private var backStack: [AppRoute] = []
    private var forwardStack: [AppRoute] = []

    var canGoBack: Bool {
        !backStack.isEmpty
    }

    var canGoForward: Bool {
        !forwardStack.isEmpty
    }

    func showHome() {
        navigate(to: .home)
    }

    func showVideo(_ video: VideoItem) {
        navigate(to: .video(video))
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentRoute)
        currentRoute = previous
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentRoute)
        currentRoute = next
    }

    private func navigate(to route: AppRoute) {
        guard route != currentRoute else { return }
        backStack.append(currentRoute)
        currentRoute = route
        forwardStack.removeAll()
    }
}
