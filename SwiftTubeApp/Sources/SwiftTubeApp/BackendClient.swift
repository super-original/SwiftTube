import Foundation

@MainActor
final class BackendClient {
    static let shared = BackendClient()

    private let backend = SwiftTubeBackend.shared

    private init() {}

    func fetchRecommendations(continuation: String? = nil) async throws -> RecommendationsResponse {
        try await backend.fetchRecommendations(continuation: continuation)
    }

    func fetchChannelAvatar(channelID: String) async throws -> ChannelAvatarResponse {
        try await backend.fetchChannelAvatar(channelID: channelID)
    }

    func fetchSearch(query: String, continuation: String? = nil) async throws -> SearchResponse {
        try await backend.fetchSearch(query: query, continuation: continuation)
    }

    func fetchWatchHistory(query: String? = nil, continuation: String? = nil) async throws -> WatchHistoryResponse {
        try await backend.fetchWatchHistory(query: query, continuation: continuation)
    }

    func fetchSearchSuggestions(query: String) async throws -> SearchSuggestionsResponse {
        try await backend.fetchSearchSuggestions(query: query)
    }

    func fetchVideo(id: String) async throws -> VideoPlayback {
        try await backend.fetchVideo(id: id)
    }

    func fetchComments(id: String) async throws -> CommentsResponse {
        try await backend.fetchComments(id: id, continuation: nil)
    }

    func fetchComments(id: String, continuation: String? = nil) async throws -> CommentsResponse {
        try await backend.fetchComments(id: id, continuation: continuation)
    }

    func fetchPlaylistOptions(id: String) async throws -> PlaylistOptionsResponse {
        try await backend.fetchPlaylistOptions(id: id)
    }

    func fetchPlaylistLibrary(continuation: String? = nil) async throws -> PlaylistLibraryResponse {
        try await backend.fetchPlaylistLibrary(continuation: continuation)
    }

    func fetchPlaylistFeed(id: String, continuation: String? = nil) async throws -> PlaylistFeed {
        try await backend.fetchPlaylistFeed(id: id, continuation: continuation)
    }

    func fetchRelatedVideos(id: String, continuation: String? = nil) async throws -> RecommendationsResponse {
        try await backend.fetchRelatedVideos(id: id, continuation: continuation)
    }

    func updateSubscription(id: String, subscribed: Bool) async throws -> SubscriptionResponse {
        try await backend.updateSubscription(id: id, subscribed: subscribed)
    }

    func updateRating(id: String, action: String) async throws -> RatingResponse {
        try await backend.updateRating(id: id, action: action)
    }

    func updateWatchLater(id: String, saved: Bool) async throws -> WatchLaterResponse {
        try await backend.updateWatchLater(id: id, saved: saved)
    }

    func updatePlaylist(id: String, playlistId: String, saved: Bool) async throws -> PlaylistMutationResponse {
        try await backend.updatePlaylist(id: id, playlistID: playlistId, saved: saved)
    }

    func removePlaylistItem(playlistId: String, setVideoId: String) async throws -> PlaylistItemMutationResponse {
        try await backend.removePlaylistItem(playlistID: playlistId, setVideoID: setVideoId)
    }

    func reorderPlaylistItem(
        playlistId: String,
        setVideoId: String,
        position: String
    ) async throws -> PlaylistItemMutationResponse {
        try await backend.reorderPlaylistItem(playlistID: playlistId, setVideoID: setVideoId, position: position)
    }

    func fetchAuthStatus() async throws -> AuthStatusResponse {
        try await backend.authStatus()
    }

    func connectBrowserAuth(browser: String) async throws -> AuthStatusResponse {
        try await backend.connectBrowserAuth(browser: browser)
    }

    func clearAuthSession() async throws -> AuthStatusResponse {
        try await backend.clearAuthSession()
    }

    func recordPlaybackProgress(
        id videoID: String,
        currentTime: Double,
        duration: Double?,
        didFinish: Bool
    ) async throws -> PlaybackProgressMutationResponse {
        try await backend.recordPlaybackProgress(
            videoID: videoID,
            currentTime: currentTime,
            duration: duration,
            didFinish: didFinish
        )
    }
}

struct BackendClientError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
