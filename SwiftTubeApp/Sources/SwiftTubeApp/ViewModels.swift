import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var videos: [VideoItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var notice: String? = nil

    private var continuation: String? = nil
    private var hasLoadedInitial = false

    func loadInitial() {
        guard !hasLoadedInitial else { return }
        hasLoadedInitial = true
        Task { await fetchRecommendations(reset: true) }
    }

    func reload() {
        hasLoadedInitial = false
        loadInitial()
    }

    func loadMoreIfNeeded(currentVideo: VideoItem) {
        guard let last = videos.last, last == currentVideo else { return }
        guard !isLoading, continuation != nil else { return }
        Task { await fetchRecommendations(reset: false) }
    }

    private func fetchRecommendations(reset: Bool) async {
        isLoading = true
        defer { isLoading = false }

        if reset {
            continuation = nil
            videos = []
            notice = nil
        }

        do {
            let response = try await BackendClient.shared.fetchRecommendations(continuation: continuation)
            continuation = response.continuation
            videos.append(contentsOf: response.items)
            notice = response.note
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load recommendations."
        }
    }
}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var results: [VideoItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String? = nil
    @Published private(set) var isActive = false

    private var continuation: String? = nil
    @Published private(set) var lastQuery: String = ""

    func submit(navigation: AppNavigationModel) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let videoID = Self.extractVideoID(from: trimmed) {
            let placeholder = VideoItem(
                id: videoID,
                title: "Loading...",
                channel: nil,
                viewCountText: nil,
                publishedTimeText: nil,
                durationText: nil,
                thumbnails: []
            )
            navigation.showVideo(placeholder)
            return
        }

        performSearch(query: trimmed, reset: true)
    }

    func clear() {
        query = ""
        results = []
        isActive = false
        errorMessage = nil
        continuation = nil
        lastQuery = ""
    }

    func loadMoreIfNeeded(currentVideo: VideoItem) {
        guard let last = results.last, last == currentVideo else { return }
        guard !isSearching, continuation != nil else { return }
        performSearch(query: lastQuery, reset: false)
    }

    private func performSearch(query: String, reset: Bool) {
        let searchQuery = query
        if reset {
            results = []
            continuation = nil
            lastQuery = searchQuery
        }
        isActive = true
        isSearching = true
        errorMessage = nil

        Task {
            defer { isSearching = false }
            do {
                let response = try await BackendClient.shared.fetchSearch(
                    query: searchQuery,
                    continuation: reset ? nil : continuation
                )
                continuation = response.continuation
                results.append(contentsOf: response.items)
            } catch {
                errorMessage = "Search failed. Please try again."
            }
        }
    }

    static func extractVideoID(from input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Normalize: add scheme if missing so URL parsing works
        if !text.contains("://") {
            text = "https://" + text
        }

        guard let url = URL(string: text),
              let host = url.host?.lowercased() else {
            return nil
        }

        // youtu.be/VIDEO_ID
        if host == "youtu.be" || host == "www.youtu.be" {
            let videoID = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return videoID.isEmpty ? nil : validVideoID(videoID)
        }

        // youtube.com or m.youtube.com or www.youtube.com
        let youtubeHosts = ["youtube.com", "www.youtube.com", "m.youtube.com"]
        guard youtubeHosts.contains(host) else { return nil }

        // /watch?v=VIDEO_ID
        if url.path == "/watch" || url.path == "/watch/" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let videoID = components?.queryItems?.first(where: { $0.name == "v" })?.value {
                return validVideoID(videoID)
            }
        }

        // /shorts/VIDEO_ID or /embed/VIDEO_ID or /v/VIDEO_ID or /live/VIDEO_ID
        let prefixes = ["/shorts/", "/embed/", "/v/", "/live/"]
        for prefix in prefixes {
            if url.path.hasPrefix(prefix) {
                let videoID = String(url.path.dropFirst(prefix.count)).components(separatedBy: "/").first ?? ""
                if !videoID.isEmpty {
                    return validVideoID(videoID)
                }
            }
        }

        return nil
    }

    private static func validVideoID(_ id: String) -> String? {
        // YouTube video IDs are 11 characters, alphanumeric plus - and _
        let cleaned = id.components(separatedBy: CharacterSet.urlQueryAllowed.inverted).first ?? id
        guard cleaned.count == 11 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard cleaned.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return cleaned
    }
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var playback: VideoPlayback? = nil
    @Published var isLoading = true
    @Published var errorMessage: String? = nil
    @Published var actionMessage: String? = nil
    @Published private(set) var comments: [CommentItem] = []
    @Published private(set) var commentCountText: String? = nil
    @Published private(set) var isLoadingComments = false
    @Published private(set) var playbackLoadID = UUID()
    @Published private(set) var playlistOptions: [PlaylistOption] = []
    @Published private(set) var isLoadingPlaylistOptions = false
    @Published private(set) var isMutatingSubscription = false
    @Published private(set) var isMutatingRating = false
    @Published private(set) var isMutatingWatchLater = false
    @Published private(set) var playlistMutationIDs: Set<String> = []

    let video: VideoItem
    private var loadTask: Task<Void, Never>? = nil
    private var commentsTask: Task<Void, Never>? = nil

    init(video: VideoItem) {
        self.video = video
    }

    func load() {
        loadTask?.cancel()
        commentsTask?.cancel()
        loadTask = Task {
            await fetchPlayback()
        }
    }

    func stop() {
        loadTask?.cancel()
        commentsTask?.cancel()
    }

    private func fetchPlayback() async {
        isLoading = true
        errorMessage = nil
        playback = nil
        playbackLoadID = UUID()
        actionMessage = nil
        comments = []
        commentCountText = nil
        isLoadingComments = false
        playlistOptions = []
        isLoadingPlaylistOptions = false

        do {
            let playback = try await BackendClient.shared.fetchVideo(id: video.id)
            guard !Task.isCancelled else { return }
            self.playback = playback
            self.comments = []
            self.commentCountText = playback.commentCountText
            self.isLoadingComments = false
            isLoading = false
            playbackLoadID = UUID()
            startCommentsLoad()
        } catch {
            guard !Task.isCancelled else { return }
            playback = nil
            comments = []
            commentCountText = nil
            isLoadingComments = false
            errorMessage = "Failed to load video."
            isLoading = false
            playbackLoadID = UUID()
        }
    }

    private func startCommentsLoad() {
        commentsTask?.cancel()
        commentsTask = Task { [weak self] in
            await self?.fetchComments()
        }
    }

    private func fetchComments() async {
        isLoadingComments = true
        defer { isLoadingComments = false }

        do {
            let response = try await BackendClient.shared.fetchComments(id: video.id)
            guard !Task.isCancelled else { return }
            comments = response.comments
            commentCountText = response.commentCountText ?? commentCountText
        } catch {
            guard !Task.isCancelled else { return }
        }
    }

    func loadPlaylistOptions() {
        guard playback?.playlistSaveEnabled == true, !isLoadingPlaylistOptions else { return }

        Task {
            isLoadingPlaylistOptions = true
            defer { isLoadingPlaylistOptions = false }

            do {
                let response = try await BackendClient.shared.fetchPlaylistOptions(id: video.id)
                playlistOptions = response.options.filter { $0.playlistId != "WL" }
                actionMessage = nil
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }

    func toggleSubscription() {
        guard let subscription = playback?.subscription, !isMutatingSubscription else { return }

        Task {
            isMutatingSubscription = true
            defer { isMutatingSubscription = false }

            do {
                let response = try await BackendClient.shared.updateSubscription(
                    id: video.id,
                    subscribed: !subscription.subscribed
                )
                updatePlayback { current in
                    VideoPlayback(
                        id: current.id,
                        title: current.title,
                        channel: current.channel,
                        channelId: current.channelId,
                        channelAvatarUrl: current.channelAvatarUrl,
                        subscriberCountText: response.subscription?.subscriberCountText ?? current.subscriberCountText,
                        viewCountText: current.viewCountText,
                        publishedTimeText: current.publishedTimeText,
                        publishedDateText: current.publishedDateText,
                        likeCountText: current.likeCountText,
                        durationText: current.durationText,
                        description: current.description,
                        commentCountText: current.commentCountText,
                        streams: current.streams,
                        recommendations: current.recommendations,
                        comments: current.comments,
                        playbackStrategy: current.playbackStrategy,
                        preferredManifestStream: current.preferredManifestStream,
                        preferredMuxedStream: current.preferredMuxedStream,
                        preferredVideoStream: current.preferredVideoStream,
                        preferredAudioStream: current.preferredAudioStream,
                        bestStreamUrl: current.bestStreamUrl,
                        bestStream: current.bestStream,
                        subtitles: current.subtitles,
                        storyboard: current.storyboard,
                        subscription: response.subscription,
                        rating: current.rating,
                        watchLater: current.watchLater,
                        playlistSaveEnabled: current.playlistSaveEnabled
                    )
                }
                actionMessage = nil
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }

    func toggleRating(_ target: String) {
        guard playback?.rating != nil, !isMutatingRating else { return }

        Task {
            isMutatingRating = true
            defer { isMutatingRating = false }

            do {
                let response = try await BackendClient.shared.updateRating(id: video.id, action: target)
                updatePlayback { current in
                    VideoPlayback(
                        id: current.id,
                        title: current.title,
                        channel: current.channel,
                        channelId: current.channelId,
                        channelAvatarUrl: current.channelAvatarUrl,
                        subscriberCountText: current.subscriberCountText,
                        viewCountText: current.viewCountText,
                        publishedTimeText: current.publishedTimeText,
                        publishedDateText: current.publishedDateText,
                        likeCountText: response.rating?.likeCountText ?? current.likeCountText,
                        durationText: current.durationText,
                        description: current.description,
                        commentCountText: current.commentCountText,
                        streams: current.streams,
                        recommendations: current.recommendations,
                        comments: current.comments,
                        playbackStrategy: current.playbackStrategy,
                        preferredManifestStream: current.preferredManifestStream,
                        preferredMuxedStream: current.preferredMuxedStream,
                        preferredVideoStream: current.preferredVideoStream,
                        preferredAudioStream: current.preferredAudioStream,
                        bestStreamUrl: current.bestStreamUrl,
                        bestStream: current.bestStream,
                        subtitles: current.subtitles,
                        storyboard: current.storyboard,
                        subscription: current.subscription,
                        rating: response.rating,
                        watchLater: current.watchLater,
                        playlistSaveEnabled: current.playlistSaveEnabled
                    )
                }
                actionMessage = nil
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }

    func toggleWatchLater() {
        guard let watchLater = playback?.watchLater, !isMutatingWatchLater else { return }

        Task {
            isMutatingWatchLater = true
            defer { isMutatingWatchLater = false }

            do {
                let response = try await BackendClient.shared.updateWatchLater(
                    id: video.id,
                    saved: !watchLater.saved
                )
                if let updated = response.watchLater {
                    playlistOptions = playlistOptions.map { $0.playlistId == updated.playlistId ? updated : $0 }
                }
                updatePlaybackWatchLater(response.watchLater)
                actionMessage = nil
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }

    func togglePlaylist(_ option: PlaylistOption) {
        guard !playlistMutationIDs.contains(option.playlistId) else { return }

        Task {
            playlistMutationIDs.insert(option.playlistId)
            defer { playlistMutationIDs.remove(option.playlistId) }

            do {
                let response = try await BackendClient.shared.updatePlaylist(
                    id: video.id,
                    playlistId: option.playlistId,
                    saved: !option.saved
                )
                if let updated = response.playlist {
                    playlistOptions = playlistOptions.map { $0.playlistId == updated.playlistId ? updated : $0 }
                }
                actionMessage = nil
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }

    private func updatePlayback(_ transform: (VideoPlayback) -> VideoPlayback) {
        guard let playback else { return }
        self.playback = transform(playback)
    }

    private func updatePlaybackWatchLater(_ watchLater: PlaylistOption?) {
        updatePlayback { current in
            VideoPlayback(
                id: current.id,
                title: current.title,
                channel: current.channel,
                channelId: current.channelId,
                channelAvatarUrl: current.channelAvatarUrl,
                subscriberCountText: current.subscriberCountText,
                viewCountText: current.viewCountText,
                publishedTimeText: current.publishedTimeText,
                publishedDateText: current.publishedDateText,
                likeCountText: current.likeCountText,
                durationText: current.durationText,
                description: current.description,
                commentCountText: current.commentCountText,
                streams: current.streams,
                recommendations: current.recommendations,
                comments: current.comments,
                playbackStrategy: current.playbackStrategy,
                preferredManifestStream: current.preferredManifestStream,
                preferredMuxedStream: current.preferredMuxedStream,
                preferredVideoStream: current.preferredVideoStream,
                preferredAudioStream: current.preferredAudioStream,
                bestStreamUrl: current.bestStreamUrl,
                bestStream: current.bestStream,
                subtitles: current.subtitles,
                storyboard: current.storyboard,
                subscription: current.subscription,
                rating: current.rating,
                watchLater: watchLater,
                playlistSaveEnabled: current.playlistSaveEnabled
            )
        }
    }
}
