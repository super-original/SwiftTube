import Foundation

enum SidebarItemKind: String, CaseIterable, Identifiable, Codable {
    case home
    case playlists
    case watchLater
    case likedVideos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .playlists: return "Playlists"
        case .watchLater: return "Watch Later"
        case .likedVideos: return "Liked Videos"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .playlists: return "music.note.list"
        case .watchLater: return "clock"
        case .likedVideos: return "hand.thumbsup"
        }
    }
}

struct PlaylistReference: Equatable, Hashable, Identifiable, Sendable {
    enum Kind: String, Equatable, Hashable, Sendable {
        case watchLater
        case likedVideos
        case userPlaylist
    }

    let playlistId: String
    let title: String
    let kind: Kind

    var id: String { playlistId }

    static let watchLater = PlaylistReference(
        playlistId: "WL",
        title: "Watch Later",
        kind: .watchLater
    )

    static let likedVideos = PlaylistReference(
        playlistId: "LL",
        title: "Liked Videos",
        kind: .likedVideos
    )
}

enum AppRoute: Equatable {
    case home
    case playlistLibrary
    case playlistFeed(PlaylistReference)
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
    @Published var selectedSidebarItem: SidebarItemKind = .home
    @Published var routeRefreshID = UUID()

    private var backStack: [AppRoute] = []
    private var forwardStack: [AppRoute] = []

    var canGoBack: Bool {
        !backStack.isEmpty
    }

    var canGoForward: Bool {
        !forwardStack.isEmpty
    }

    func showHome() {
        selectedSidebarItem = .home
        navigate(to: .home)
    }

    func showPlaylistLibrary() {
        selectedSidebarItem = .playlists
        navigate(to: .playlistLibrary)
    }

    func showWatchLater() {
        selectedSidebarItem = .watchLater
        navigate(to: .playlistFeed(.watchLater))
    }

    func showLikedVideos() {
        selectedSidebarItem = .likedVideos
        navigate(to: .playlistFeed(.likedVideos))
    }

    func showPlaylist(_ playlist: PlaylistReference) {
        if playlist.kind == .watchLater {
            selectedSidebarItem = .watchLater
        } else if playlist.kind == .likedVideos {
            selectedSidebarItem = .likedVideos
        } else {
            selectedSidebarItem = .playlists
        }
        navigate(to: .playlistFeed(playlist))
    }

    func showVideo(_ video: VideoItem) {
        navigate(to: .video(video))
    }

    func selectSidebarItem(_ item: SidebarItemKind) {
        switch item {
        case .home:
            showHome()
        case .playlists:
            showPlaylistLibrary()
        case .watchLater:
            showWatchLater()
        case .likedVideos:
            showLikedVideos()
        }
    }

    func ensureValidSidebarSelection(visibleItems: [SidebarItemKind]) {
        guard !visibleItems.isEmpty else {
            selectedSidebarItem = .home
            if currentRoute != .home {
                currentRoute = .home
            }
            return
        }

        if !visibleItems.contains(selectedSidebarItem) {
            selectSidebarItem(visibleItems[0])
            return
        }

        if case .playlistLibrary = currentRoute, !visibleItems.contains(.playlists) {
            selectSidebarItem(visibleItems[0])
        } else if case .playlistFeed(let playlist) = currentRoute {
            switch playlist.kind {
            case .watchLater where !visibleItems.contains(.watchLater):
                selectSidebarItem(visibleItems[0])
            case .likedVideos where !visibleItems.contains(.likedVideos):
                selectSidebarItem(visibleItems[0])
            case .userPlaylist where !visibleItems.contains(.playlists):
                selectSidebarItem(visibleItems[0])
            default:
                break
            }
        }
    }

    func refreshCurrentRoute() {
        routeRefreshID = UUID()
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentRoute)
        currentRoute = previous
        syncSidebarSelection(with: previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentRoute)
        currentRoute = next
        syncSidebarSelection(with: next)
    }

    private func navigate(to route: AppRoute) {
        guard route != currentRoute else { return }
        backStack.append(currentRoute)
        currentRoute = route
        forwardStack.removeAll()
        syncSidebarSelection(with: route)
    }

    private func syncSidebarSelection(with route: AppRoute) {
        switch route {
        case .home:
            selectedSidebarItem = .home
        case .playlistLibrary:
            selectedSidebarItem = .playlists
        case .playlistFeed(let playlist):
            switch playlist.kind {
            case .watchLater:
                selectedSidebarItem = .watchLater
            case .likedVideos:
                selectedSidebarItem = .likedVideos
            case .userPlaylist:
                selectedSidebarItem = .playlists
            }
        case .video:
            break
        }
    }
}
