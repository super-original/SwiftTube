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
final class PlayerViewModel: ObservableObject {
    @Published var playback: VideoPlayback? = nil
    @Published var isLoading = true
    @Published var errorMessage: String? = nil
    @Published private(set) var comments: [CommentItem] = []
    @Published private(set) var commentCountText: String? = nil
    @Published private(set) var isLoadingComments = false
    @Published private(set) var playbackLoadID = UUID()

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
        comments = []
        commentCountText = nil
        isLoadingComments = false

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
}
