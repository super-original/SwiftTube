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
    struct ParsedVideoLink: Equatable {
        let videoID: String
        let startTime: Double
    }

    struct LinkPreview: Equatable {
        let videoID: String
        let title: String
        let channel: String?
        let startTime: Double
    }

    @Published var query: String = ""
    @Published private(set) var results: [VideoItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String? = nil
    @Published private(set) var isActive = false
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var linkPreview: LinkPreview? = nil
    @Published private(set) var isLoadingSuggestions = false

    private var continuation: String? = nil
    @Published private(set) var lastQuery: String = ""
    private var suggestionTask: Task<Void, Never>? = nil
    private var linkPreviewTask: Task<Void, Never>? = nil

    func submit(navigation: AppNavigationModel) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let parsedLink = Self.extractVideoLink(from: trimmed) {
            let placeholder = VideoItem(
                id: parsedLink.videoID,
                title: "Loading...",
                channel: nil,
                viewCountText: nil,
                publishedTimeText: nil,
                durationText: nil,
                thumbnails: []
            )
            navigation.showVideo(placeholder, startTime: parsedLink.startTime)
            return
        }

        performSearch(query: trimmed, reset: true)
    }

    func clear() {
        suggestionTask?.cancel()
        linkPreviewTask?.cancel()
        query = ""
        results = []
        isActive = false
        errorMessage = nil
        continuation = nil
        lastQuery = ""
        suggestions = []
        linkPreview = nil
        isLoadingSuggestions = false
    }

    func handleQueryChange() {
        suggestionTask?.cancel()
        linkPreviewTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestions = []
            linkPreview = nil
            isLoadingSuggestions = false
            return
        }

        if let parsedLink = Self.extractVideoLink(from: trimmed) {
            suggestions = []
            isLoadingSuggestions = false
            linkPreview = LinkPreview(
                videoID: parsedLink.videoID,
                title: "YouTube link detected",
                channel: nil,
                startTime: parsedLink.startTime
            )

            linkPreviewTask = Task {
                do {
                    let playback = try await BackendClient.shared.fetchVideo(id: parsedLink.videoID)
                    guard !Task.isCancelled else { return }
                    linkPreview = LinkPreview(
                        videoID: parsedLink.videoID,
                        title: playback.title ?? "YouTube link detected",
                        channel: playback.channel,
                        startTime: parsedLink.startTime
                    )
                } catch {
                    guard !Task.isCancelled else { return }
                }
            }
            return
        }

        linkPreview = nil
        isLoadingSuggestions = true
        suggestionTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }

            do {
                let response = try await BackendClient.shared.fetchSearchSuggestions(query: trimmed)
                guard !Task.isCancelled else { return }
                suggestions = response.suggestions
            } catch {
                guard !Task.isCancelled else { return }
                suggestions = []
            }
            isLoadingSuggestions = false
        }
    }

    func applySuggestion(_ suggestion: String) {
        query = suggestion
        suggestions = []
        linkPreview = nil
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
        suggestions = []
        linkPreview = nil

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

    static func extractVideoLink(from input: String) -> ParsedVideoLink? {
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
            guard let validID = videoID.isEmpty ? nil : validVideoID(videoID) else { return nil }
            return ParsedVideoLink(videoID: validID, startTime: timestamp(from: url))
        }

        // youtube.com or m.youtube.com or www.youtube.com
        let youtubeHosts = ["youtube.com", "www.youtube.com", "m.youtube.com"]
        guard youtubeHosts.contains(host) else { return nil }

        // /watch?v=VIDEO_ID
        if url.path == "/watch" || url.path == "/watch/" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let videoID = components?.queryItems?.first(where: { $0.name == "v" })?.value {
                guard let validID = validVideoID(videoID) else { return nil }
                return ParsedVideoLink(videoID: validID, startTime: timestamp(from: url))
            }
        }

        // /shorts/VIDEO_ID or /embed/VIDEO_ID or /v/VIDEO_ID or /live/VIDEO_ID
        let prefixes = ["/shorts/", "/embed/", "/v/", "/live/"]
        for prefix in prefixes {
            if url.path.hasPrefix(prefix) {
                let videoID = String(url.path.dropFirst(prefix.count)).components(separatedBy: "/").first ?? ""
                if !videoID.isEmpty {
                    guard let validID = validVideoID(videoID) else { return nil }
                    return ParsedVideoLink(videoID: validID, startTime: timestamp(from: url))
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

    private static func timestamp(from url: URL) -> Double {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        if let rawTimestamp = queryItems.first(where: { ["t", "start", "time_continue"].contains($0.name) })?.value,
           let parsed = parseTimestamp(rawTimestamp) {
            return parsed
        }

        if let fragment = components?.fragment {
            let fragmentValue = fragment
                .components(separatedBy: "&")
                .first(where: { $0.hasPrefix("t=") || $0.hasPrefix("start=") })?
                .components(separatedBy: "=")
                .dropFirst()
                .joined(separator: "=")

            if let fragmentValue, let parsed = parseTimestamp(fragmentValue) {
                return parsed
            }
        }

        return 0
    }

    private static func parseTimestamp(_ rawValue: String) -> Double? {
        let cleaned = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return nil }

        if let seconds = Double(cleaned.replacingOccurrences(of: "s", with: "")),
           cleaned.range(of: #"^\d+s?$"#, options: .regularExpression) != nil {
            return seconds
        }

        let pattern = #"(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) else {
            return nil
        }

        func component(at index: Int) -> Double {
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: cleaned) else { return 0 }
            return Double(cleaned[swiftRange]) ?? 0
        }

        let totalSeconds = (component(at: 1) * 3600) + (component(at: 2) * 60) + component(at: 3)
        return totalSeconds > 0 ? totalSeconds : nil
    }
}

@MainActor
final class PlaylistLibraryViewModel: ObservableObject {
    @Published private(set) var playlists: [PlaylistSummary] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String? = nil

    private var continuation: String? = nil
    private var hasLoadedInitial = false

    func loadInitial() {
        guard !hasLoadedInitial else { return }
        hasLoadedInitial = true
        Task { await fetch(reset: true) }
    }

    func reload() {
        hasLoadedInitial = false
        loadInitial()
    }

    func loadMoreIfNeeded(currentPlaylist: PlaylistSummary) {
        guard let last = playlists.last, last == currentPlaylist else { return }
        guard !isLoading, continuation != nil else { return }
        Task { await fetch(reset: false) }
    }

    private func fetch(reset: Bool) async {
        isLoading = true
        defer { isLoading = false }

        if reset {
            continuation = nil
            playlists = []
            errorMessage = nil
        }

        do {
            let response = try await BackendClient.shared.fetchPlaylistLibrary(continuation: continuation)
            continuation = response.continuation
            playlists.append(contentsOf: response.items)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class PlaylistFeedViewModel: ObservableObject {
    @Published private(set) var feed: PlaylistFeed? = nil
    @Published private(set) var items: [VideoItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var mutationIDs: Set<String> = []
    @Published var errorMessage: String? = nil

    let playlist: PlaylistReference
    private var continuation: String? = nil
    private var hasLoadedInitial = false
    private var isReordering = false

    init(playlist: PlaylistReference) {
        self.playlist = playlist
    }

    func loadInitial() {
        guard !hasLoadedInitial else { return }
        hasLoadedInitial = true
        Task { await fetch(reset: true) }
    }

    func reload() {
        hasLoadedInitial = false
        loadInitial()
    }

    func loadMoreIfNeeded(currentVideo: VideoItem) {
        guard !isLoading, continuation != nil else { return }
        guard let currentIndex = items.firstIndex(of: currentVideo) else { return }
        let thresholdIndex = max(items.count - 5, 0)
        guard currentIndex >= thresholdIndex else { return }
        Task { await fetch(reset: false) }
    }

    private func fetch(reset: Bool) async {
        isLoading = true
        defer { isLoading = false }

        if reset {
            continuation = nil
            feed = nil
            items = []
            errorMessage = nil
        }

        do {
            let response = try await BackendClient.shared.fetchPlaylistFeed(
                id: playlist.playlistId,
                continuation: continuation
            )
            let resolvedTitle = response.title == "Playlist"
                ? (feed?.title ?? playlist.title)
                : response.title
            let resolvedFeed = response.with(title: resolvedTitle)
            if reset || feed == nil {
                feed = resolvedFeed
            }
            continuation = response.continuation
            items.append(contentsOf: response.items)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveItemToTop(_ video: VideoItem) {
        guard let setVideoId = video.playlistSetVideoId,
              video.playlistCanMoveToTop,
              !mutationIDs.contains(setVideoId) else { return }

        let previousItems = items
        items = move(video, in: items, toTop: true)

        Task {
            mutationIDs.insert(setVideoId)
            defer { mutationIDs.remove(setVideoId) }

            do {
                _ = try await BackendClient.shared.reorderPlaylistItem(
                    playlistId: playlist.playlistId,
                    setVideoId: setVideoId,
                    position: "top"
                )
                errorMessage = nil
            } catch {
                items = previousItems
                errorMessage = error.localizedDescription
            }
        }
    }

    func moveItemToBottom(_ video: VideoItem) {
        guard let setVideoId = video.playlistSetVideoId,
              video.playlistCanMoveToBottom,
              !mutationIDs.contains(setVideoId) else { return }

        let previousItems = items
        items = move(video, in: items, toTop: false)

        Task {
            mutationIDs.insert(setVideoId)
            defer { mutationIDs.remove(setVideoId) }

            do {
                _ = try await BackendClient.shared.reorderPlaylistItem(
                    playlistId: playlist.playlistId,
                    setVideoId: setVideoId,
                    position: "bottom"
                )
                errorMessage = nil
            } catch {
                items = previousItems
                errorMessage = error.localizedDescription
            }
        }
    }

    func removeItem(_ video: VideoItem) {
        guard let setVideoId = video.playlistSetVideoId,
              video.playlistCanRemove,
              !mutationIDs.contains(setVideoId) else { return }

        let previousItems = items
        items.removeAll { $0.playlistSetVideoId == setVideoId }
        if let feed {
            let newCount = max(previousItems.count - 1, 0)
            self.feed = feed.with(
                itemCountText: newCount > 0 ? "\(newCount) videos" : feed.itemCountText,
                items: items
            )
        }

        Task {
            mutationIDs.insert(setVideoId)
            defer { mutationIDs.remove(setVideoId) }

            do {
                _ = try await BackendClient.shared.removePlaylistItem(
                    playlistId: playlist.playlistId,
                    setVideoId: setVideoId
                )
                errorMessage = nil
            } catch {
                items = previousItems
                if let feed {
                    self.feed = feed.with(items: previousItems)
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    func reorderItem(withID draggedID: String, toInsertionIndex insertionIndex: Int) -> Bool {
        guard !isReordering,
              let sourceIndex = items.firstIndex(where: { $0.id == draggedID }) else {
            return false
        }

        let clampedIndex = max(0, min(insertionIndex, items.count))
        let updated = reorderedItems(items, sourceIndex: sourceIndex, insertionIndex: clampedIndex)
        guard updated != items else { return false }

        let previousItems = items
        items = updated
        if let feed {
            self.feed = feed.with(items: updated)
        }

        Task {
            isReordering = true
            defer { isReordering = false }

            do {
                try await syncPlaylistOrder(updated)
                errorMessage = nil
            } catch {
                items = previousItems
                if let feed {
                    self.feed = feed.with(items: previousItems)
                }
                errorMessage = error.localizedDescription
            }
        }

        return true
    }

    private func move(_ video: VideoItem, in items: [VideoItem], toTop: Bool) -> [VideoItem] {
        guard let currentIndex = items.firstIndex(where: { $0.playlistSetVideoId == video.playlistSetVideoId }) else {
            return items
        }

        var updated = items
        let item = updated.remove(at: currentIndex)
        if toTop {
            updated.insert(item, at: 0)
        } else {
            updated.append(item)
        }
        return updated
    }

    private func reorderedItems(_ items: [VideoItem], sourceIndex: Int, insertionIndex: Int) -> [VideoItem] {
        guard items.indices.contains(sourceIndex) else { return items }

        var updated = items
        let moved = updated.remove(at: sourceIndex)
        let targetIndex = sourceIndex < insertionIndex ? max(insertionIndex - 1, 0) : insertionIndex
        updated.insert(moved, at: min(max(targetIndex, 0), updated.count))
        return updated
    }

    private func syncPlaylistOrder(_ items: [VideoItem]) async throws {
        for item in items.reversed() {
            guard let setVideoId = item.playlistSetVideoId else { continue }
            _ = try await BackendClient.shared.reorderPlaylistItem(
                playlistId: playlist.playlistId,
                setVideoId: setVideoId,
                position: "top"
            )
        }
    }
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var playback: VideoPlayback? = nil
    @Published var isLoading = true
    @Published var errorMessage: String? = nil
    @Published var actionMessage: String? = nil
    @Published private(set) var recommendations: [VideoItem] = []
    @Published private(set) var comments: [CommentItem] = []
    @Published private(set) var commentCountText: String? = nil
    @Published private(set) var isLoadingComments = false
    @Published private(set) var isLoadingRecommendations = false
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
    private var commentsContinuation: String? = nil
    private var recommendationsContinuation: String? = nil

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
        recommendations = []
        commentCountText = nil
        isLoadingComments = false
        isLoadingRecommendations = false
        commentsContinuation = nil
        recommendationsContinuation = nil
        playlistOptions = []
        isLoadingPlaylistOptions = false

        do {
            let playback = try await BackendClient.shared.fetchVideo(id: video.id)
            guard !Task.isCancelled else { return }
            self.playback = playback
            self.comments = []
            self.recommendations = playback.recommendations
            self.commentCountText = playback.commentCountText
            self.isLoadingComments = false
            self.recommendationsContinuation = playback.recommendationsContinuation
            isLoading = false
            playbackLoadID = UUID()
            startCommentsLoad()
        } catch {
            guard !Task.isCancelled else { return }
            playback = nil
            comments = []
            recommendations = []
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
            commentsContinuation = response.continuation
        } catch {
            guard !Task.isCancelled else { return }
        }
    }

    func loadMoreCommentsIfNeeded(currentComment: CommentItem) {
        guard !isLoadingComments, commentsContinuation != nil else { return }
        guard let currentIndex = comments.firstIndex(of: currentComment) else { return }
        let thresholdIndex = max(comments.count - 5, 0)
        guard currentIndex >= thresholdIndex else { return }

        Task {
            await fetchMoreComments()
        }
    }

    private func fetchMoreComments() async {
        guard let commentsContinuation else { return }
        isLoadingComments = true
        defer { isLoadingComments = false }

        do {
            let response = try await BackendClient.shared.fetchComments(
                id: video.id,
                continuation: commentsContinuation
            )
            guard !Task.isCancelled else { return }
            comments.append(contentsOf: response.comments)
            if let count = response.commentCountText {
                commentCountText = count
            }
            self.commentsContinuation = response.continuation
        } catch {
            guard !Task.isCancelled else { return }
        }
    }

    func loadMoreRecommendationsIfNeeded(currentVideo: VideoItem) {
        guard !isLoadingRecommendations, recommendationsContinuation != nil else { return }
        guard let currentIndex = recommendations.firstIndex(of: currentVideo) else { return }
        let thresholdIndex = max(recommendations.count - 5, 0)
        guard currentIndex >= thresholdIndex else { return }

        Task {
            await fetchMoreRecommendations()
        }
    }

    private func fetchMoreRecommendations() async {
        guard let recommendationsContinuation else { return }
        isLoadingRecommendations = true
        defer { isLoadingRecommendations = false }

        do {
            let response = try await BackendClient.shared.fetchRelatedVideos(
                id: video.id,
                continuation: recommendationsContinuation
            )
            guard !Task.isCancelled else { return }
            let seen = Set(recommendations.map(\.id))
            recommendations.append(contentsOf: response.items.filter { !seen.contains($0.id) })
            self.recommendationsContinuation = response.continuation
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
        let previousPlayback = playback
        let optimisticSubscription = SubscriptionState(
            channelId: subscription.channelId,
            buttonText: subscription.subscribed ? "Subscribe" : "Subscribed",
            subscribed: !subscription.subscribed,
            enabled: subscription.enabled,
            subscriberCountText: subscription.subscriberCountText
        )

        updatePlayback { current in
            current.with(
                subscriberCountText: optimisticSubscription.subscriberCountText,
                subscription: optimisticSubscription
            )
        }
        actionMessage = nil

        Task {
            isMutatingSubscription = true
            defer { isMutatingSubscription = false }

            do {
                let response = try await BackendClient.shared.updateSubscription(
                    id: video.id,
                    subscribed: !subscription.subscribed
                )
                updatePlayback { current in
                    current.with(
                        subscriberCountText: response.subscription?.subscriberCountText,
                        subscription: optimisticSubscription
                    )
                }
                actionMessage = nil
            } catch {
                playback = previousPlayback
                actionMessage = error.localizedDescription
            }
        }
    }

    func toggleRating(_ target: String) {
        guard let rating = playback?.rating, !isMutatingRating else { return }
        let previousPlayback = playback
        let backendAction: String = {
            switch target {
            case "like" where rating.status == "LIKE":
                return "none"
            case "dislike" where rating.status == "DISLIKE":
                return "none"
            default:
                return target
            }
        }()
        let optimisticStatus: String = {
            switch target {
            case "like":
                return rating.status == "LIKE" ? "INDIFFERENT" : "LIKE"
            case "dislike":
                return rating.status == "DISLIKE" ? "INDIFFERENT" : "DISLIKE"
            default:
                return "INDIFFERENT"
            }
        }()
        let optimisticRating = RatingState(
            status: optimisticStatus,
            likeCountText: rating.likeCountText
        )

        updatePlayback { current in
            current.with(
                likeCountText: optimisticRating.likeCountText,
                rating: optimisticRating
            )
        }
        actionMessage = nil

        Task {
            isMutatingRating = true
            defer { isMutatingRating = false }

            do {
                let response = try await BackendClient.shared.updateRating(id: video.id, action: backendAction)
                updatePlayback { current in
                    current.with(
                        likeCountText: response.rating?.likeCountText,
                        rating: optimisticRating
                    )
                }
                actionMessage = nil
            } catch {
                playback = previousPlayback
                actionMessage = error.localizedDescription
            }
        }
    }

    func toggleWatchLater() {
        guard let watchLater = playback?.watchLater, !isMutatingWatchLater else { return }
        let previousPlayback = playback
        let optimisticWatchLater = PlaylistOption(
            playlistId: watchLater.playlistId,
            title: watchLater.title,
            privacy: watchLater.privacy,
            containsSelectedVideos: !watchLater.saved ? "ALL" : "NONE",
            saved: !watchLater.saved
        )

        updatePlayback { current in
            current.with(watchLater: optimisticWatchLater)
        }
        actionMessage = nil

        Task {
            isMutatingWatchLater = true
            defer { isMutatingWatchLater = false }

            do {
                let response = try await BackendClient.shared.updateWatchLater(
                    id: video.id,
                    saved: !watchLater.saved
                )
                if let updated = response.watchLater {
                    playlistOptions = playlistOptions.map { item in
                        item.playlistId == updated.playlistId
                            ? PlaylistOption(
                                playlistId: updated.playlistId,
                                title: updated.title,
                                privacy: updated.privacy,
                                containsSelectedVideos: optimisticWatchLater.containsSelectedVideos,
                                saved: optimisticWatchLater.saved
                            )
                            : item
                    }
                }
                updatePlaybackWatchLater(optimisticWatchLater)
                actionMessage = nil
            } catch {
                playback = previousPlayback
                actionMessage = error.localizedDescription
            }
        }
    }

    func togglePlaylist(_ option: PlaylistOption) {
        guard !playlistMutationIDs.contains(option.playlistId) else { return }
        let previousOptions = playlistOptions
        let optimisticOption = PlaylistOption(
            playlistId: option.playlistId,
            title: option.title,
            privacy: option.privacy,
            containsSelectedVideos: option.saved ? "NONE" : "ALL",
            saved: !option.saved
        )

        playlistOptions = playlistOptions.map { item in
            item.playlistId == option.playlistId ? optimisticOption : item
        }
        actionMessage = nil

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
                    playlistOptions = playlistOptions.map { item in
                        item.playlistId == updated.playlistId
                            ? PlaylistOption(
                                playlistId: updated.playlistId,
                                title: updated.title,
                                privacy: updated.privacy,
                                containsSelectedVideos: optimisticOption.containsSelectedVideos,
                                saved: optimisticOption.saved
                            )
                            : item
                    }
                }
                actionMessage = nil
            } catch {
                playlistOptions = previousOptions
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
            current.with(watchLater: watchLater)
        }
    }
}
