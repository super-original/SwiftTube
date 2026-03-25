import Foundation

@MainActor
final class BackendClient {
    static let shared = BackendClient()

    private let baseURL = AppConfig.backendBaseURL
    private let decoder = JSONDecoder()

    private init() {}

    func fetchRecommendations(continuation: String? = nil) async throws -> RecommendationsResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("recommendations"), resolvingAgainstBaseURL: false)
        if let continuation {
            components?.queryItems = [URLQueryItem(name: "continuation", value: continuation)]
        }
        let url = components?.url ?? baseURL.appendingPathComponent("recommendations")
        return try await performRequest(url: url)
    }

    func fetchSearch(query: String, continuation: String? = nil) async throws -> SearchResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "q", value: query)]
        if let continuation {
            queryItems.append(URLQueryItem(name: "continuation", value: continuation))
        }
        components?.queryItems = queryItems
        let url = components?.url ?? baseURL.appendingPathComponent("search")
        return try await performRequest(url: url)
    }

    func fetchVideo(id: String) async throws -> VideoPlayback {
        let url = baseURL.appendingPathComponent("video/")
            .appendingPathComponent(id)
        return try await performRequest(url: url)
    }

    func fetchComments(id: String) async throws -> CommentsResponse {
        let url = baseURL.appendingPathComponent("video/")
            .appendingPathComponent(id)
            .appendingPathComponent("comments")
        return try await performRequest(url: url)
    }

    func fetchComments(id: String, continuation: String? = nil) async throws -> CommentsResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("video/")
            .appendingPathComponent(id)
            .appendingPathComponent("comments"), resolvingAgainstBaseURL: false)
        if let continuation {
            components?.queryItems = [URLQueryItem(name: "continuation", value: continuation)]
        }
        let url = components?.url ?? baseURL.appendingPathComponent("video/")
            .appendingPathComponent(id)
            .appendingPathComponent("comments")
        return try await performRequest(url: url)
    }

    func fetchPlaylistOptions(id: String) async throws -> PlaylistOptionsResponse {
        let url = baseURL.appendingPathComponent("video/")
            .appendingPathComponent(id)
            .appendingPathComponent("playlists")
        return try await performRequest(url: url)
    }

    func fetchPlaylistLibrary(continuation: String? = nil) async throws -> PlaylistLibraryResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("library/playlists"), resolvingAgainstBaseURL: false)
        if let continuation {
            components?.queryItems = [URLQueryItem(name: "continuation", value: continuation)]
        }
        let url = components?.url ?? baseURL.appendingPathComponent("library/playlists")
        return try await performRequest(url: url)
    }

    func fetchPlaylistFeed(id: String, continuation: String? = nil) async throws -> PlaylistFeed {
        var components = URLComponents(url: baseURL.appendingPathComponent("library/playlist/")
            .appendingPathComponent(id), resolvingAgainstBaseURL: false)
        if let continuation {
            components?.queryItems = [URLQueryItem(name: "continuation", value: continuation)]
        }
        let url = components?.url ?? baseURL.appendingPathComponent("library/playlist/")
            .appendingPathComponent(id)
        return try await performRequest(url: url)
    }

    func fetchRelatedVideos(id: String, continuation: String? = nil) async throws -> RecommendationsResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("video/")
            .appendingPathComponent(id)
            .appendingPathComponent("related"), resolvingAgainstBaseURL: false)
        if let continuation {
            components?.queryItems = [URLQueryItem(name: "continuation", value: continuation)]
        }
        let url = components?.url ?? baseURL.appendingPathComponent("video/")
            .appendingPathComponent(id)
            .appendingPathComponent("related")
        return try await performRequest(url: url)
    }

    func updateSubscription(id: String, subscribed: Bool) async throws -> SubscriptionResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("video/")
            .appendingPathComponent(id)
            .appendingPathComponent("subscription"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["subscribed": subscribed])
        return try await performRequest(request: request)
    }

    func updateRating(id: String, action: String) async throws -> RatingResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("video/")
            .appendingPathComponent(id)
            .appendingPathComponent("rating"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["action": action])
        return try await performRequest(request: request)
    }

    func updateWatchLater(id: String, saved: Bool) async throws -> WatchLaterResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("video/")
            .appendingPathComponent(id)
            .appendingPathComponent("watch-later"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["saved": saved])
        return try await performRequest(request: request)
    }

    func updatePlaylist(id: String, playlistId: String, saved: Bool) async throws -> PlaylistMutationResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("video/")
            .appendingPathComponent(id)
            .appendingPathComponent("playlist"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PlaylistMutationPayload(playlistId: playlistId, saved: saved))
        return try await performRequest(request: request)
    }

    func removePlaylistItem(playlistId: String, setVideoId: String) async throws -> PlaylistItemMutationResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("library/playlist/")
            .appendingPathComponent(playlistId)
            .appendingPathComponent("item/remove"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PlaylistItemMutationPayload(setVideoId: setVideoId, position: nil))
        return try await performRequest(request: request)
    }

    func reorderPlaylistItem(
        playlistId: String,
        setVideoId: String,
        position: String
    ) async throws -> PlaylistItemMutationResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("library/playlist/")
            .appendingPathComponent(playlistId)
            .appendingPathComponent("item/reorder"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PlaylistItemMutationPayload(setVideoId: setVideoId, position: position))
        return try await performRequest(request: request)
    }

    func fetchAuthStatus() async throws -> AuthStatusResponse {
        try await performRequest(url: baseURL.appendingPathComponent("auth/status"))
    }

    func connectBrowserAuth(browser: String) async throws -> AuthStatusResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/browser"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["browser": browser])
        return try await performRequest(request: request)
    }

    func clearAuthSession() async throws -> AuthStatusResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/session"))
        request.httpMethod = "DELETE"
        return try await performRequest(request: request)
    }

    private func performRequest<T: Decodable>(url: URL) async throws -> T {
        try await performRequest(request: URLRequest(url: url))
    }

    private func performRequest<T: Decodable>(request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if (200..<300).contains(http.statusCode) { return }

        if let payload = try? decoder.decode(BackendErrorPayload.self, from: data) {
            throw BackendClientError(message: payload.detail)
        }

        throw BackendClientError(message: "The backend request failed.")
    }
}

struct BackendClientError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private struct BackendErrorPayload: Decodable {
    let detail: String
}

private struct PlaylistMutationPayload: Encodable {
    let playlistId: String
    let saved: Bool
}

private struct PlaylistItemMutationPayload: Encodable {
    let setVideoId: String
    let position: String?
}
