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
    @Published private(set) var activePlaylistReference: PlaylistReference? = nil
    @Published private(set) var activePlaylistFeed: PlaylistFeed? = nil
    @Published private(set) var activePlaylistCurrentVideoID: String? = nil
    @Published var activePlaylistLoopMode: PlaylistLoopMode = .off
    @Published var activePlaylistShuffleEnabled = false
    @Published private(set) var pendingVideoStartTime: Double? = nil
    @Published private(set) var pendingVideoStartVideoID: String? = nil

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

    func showVideo(
        _ video: VideoItem,
        startTime: Double? = nil,
        playlistContext: (reference: PlaylistReference, feed: PlaylistFeed)? = nil
    ) {
        pendingVideoStartVideoID = startTime != nil ? video.id : nil
        pendingVideoStartTime = startTime
        if let playlistContext {
            activatePlaylistSession(
                reference: playlistContext.reference,
                feed: playlistContext.feed,
                currentVideoID: video.id
            )
        } else if activePlaylistFeed?.items.contains(where: { $0.id == video.id }) == true {
            activePlaylistCurrentVideoID = video.id
        } else {
            clearPlaylistSession()
        }
        navigate(to: .video(video))
    }

    func consumePendingStartTime(for videoID: String) -> Double? {
        guard pendingVideoStartVideoID == videoID else { return nil }
        let resolved = pendingVideoStartTime
        pendingVideoStartVideoID = nil
        pendingVideoStartTime = nil
        return resolved
    }

    func activatePlaylistSession(
        reference: PlaylistReference,
        feed: PlaylistFeed,
        currentVideoID: String? = nil
    ) {
        let isSamePlaylist = activePlaylistReference?.playlistId == reference.playlistId
        activePlaylistReference = reference
        activePlaylistFeed = feed
        activePlaylistCurrentVideoID = currentVideoID ?? activePlaylistCurrentVideoID
        if !isSamePlaylist {
            activePlaylistLoopMode = .off
            activePlaylistShuffleEnabled = false
        }
    }

    func syncActivePlaylistFeed(reference: PlaylistReference, feed: PlaylistFeed) {
        guard activePlaylistReference?.playlistId == reference.playlistId else { return }
        activePlaylistFeed = feed
    }

    func setActivePlaylistCurrentVideo(_ videoID: String) {
        guard activePlaylistFeed?.items.contains(where: { $0.id == videoID }) == true else { return }
        activePlaylistCurrentVideoID = videoID
    }

    func clearPlaylistSession() {
        activePlaylistReference = nil
        activePlaylistFeed = nil
        activePlaylistCurrentVideoID = nil
        activePlaylistLoopMode = .off
        activePlaylistShuffleEnabled = false
    }

    func replaceActivePlaylistItems(_ items: [VideoItem]) {
        guard let activePlaylistFeed else { return }
        self.activePlaylistFeed = activePlaylistFeed.with(items: items)
    }

    var hasActivePlaylist: Bool {
        activePlaylistFeed?.items.isEmpty == false
    }

    var activePlaylistItems: [VideoItem] {
        activePlaylistFeed?.items ?? []
    }

    var activePlaylistTitle: String? {
        activePlaylistFeed?.title ?? activePlaylistReference?.title
    }

    var activePlaylistDetailsLine: String {
        [activePlaylistFeed?.itemCountText, activePlaylistFeed?.privacy, activePlaylistFeed?.ownerText]
            .compactMap { $0 }
            .joined(separator: " • ")
    }

    func toggleActivePlaylistShuffle() {
        activePlaylistShuffleEnabled.toggle()
    }

    func cycleActivePlaylistLoopMode() {
        switch activePlaylistLoopMode {
        case .off:
            activePlaylistLoopMode = .all
        case .all:
            activePlaylistLoopMode = .one
        case .one:
            activePlaylistLoopMode = .off
        }
    }

    func nextVideoForActivePlaylist() -> VideoItem? {
        let items = activePlaylistItems
        guard !items.isEmpty else { return nil }

        guard let currentVideoID = activePlaylistCurrentVideoID,
              let currentIndex = items.firstIndex(where: { $0.id == currentVideoID }) else {
            return items.first
        }

        if activePlaylistLoopMode == .one {
            return items[currentIndex]
        }

        if activePlaylistShuffleEnabled {
            let candidateIndices = items.indices.filter { $0 != currentIndex }
            if let nextIndex = candidateIndices.randomElement() {
                return items[nextIndex]
            }
            return activePlaylistLoopMode == .all ? items[currentIndex] : nil
        }

        let nextIndex = currentIndex + 1
        if items.indices.contains(nextIndex) {
            return items[nextIndex]
        }

        if activePlaylistLoopMode == .all {
            return items.first
        }

        return nil
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
