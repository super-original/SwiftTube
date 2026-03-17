import Foundation
import AVKit

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
    @Published var player: AVPlayer? = nil
    @Published var isLoading = true
    @Published var errorMessage: String? = nil

    let video: VideoItem

    init(video: VideoItem) {
        self.video = video
    }

    func load() {
        Task {
            await fetchPlayback()
        }
    }

    private func fetchPlayback() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let playback = try await BackendClient.shared.fetchVideo(id: video.id)
            guard let urlString = playback.bestStreamUrl, let url = URL(string: urlString) else {
                errorMessage = "No playable stream found."
                return
            }
            player = AVPlayer(url: url)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load video."
        }
    }
}
