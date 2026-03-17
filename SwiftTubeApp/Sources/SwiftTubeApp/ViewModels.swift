import Foundation
import AVKit
import AVFoundation

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
    @Published var playback: VideoPlayback? = nil
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
            self.playback = playback
            self.player?.pause()
            self.player = try await buildPlayer(for: playback)
            errorMessage = nil
        } catch {
            player = nil
            errorMessage = "Failed to load video."
        }
    }

    private func buildPlayer(for playback: VideoPlayback) async throws -> AVPlayer {
        if playback.playbackStrategy == "adaptivePair",
           let videoStream = playback.preferredVideoStream,
           let audioStream = playback.preferredAudioStream,
           let adaptiveItem = try? await buildAdaptivePlayerItem(
                videoStream: videoStream,
                audioStream: audioStream
           ) {
            let player = AVPlayer(playerItem: adaptiveItem)
            player.automaticallyWaitsToMinimizeStalling = true
            return player
        }

        if let url = resolvedDirectPlaybackURL(for: playback) {
            let player = AVPlayer(url: url)
            player.automaticallyWaitsToMinimizeStalling = true
            return player
        }

        throw URLError(.badURL)
    }

    private func resolvedDirectPlaybackURL(for playback: VideoPlayback) -> URL? {
        if let urlString = playback.preferredMuxedStream?.url,
           let url = URL(string: urlString) {
            return url
        }
        if let urlString = playback.bestStreamUrl,
           let url = URL(string: urlString) {
            return url
        }
        return nil
    }

    private func buildAdaptivePlayerItem(
        videoStream: StreamInfo,
        audioStream: StreamInfo
    ) async throws -> AVPlayerItem {
        guard let videoURL = URL(string: videoStream.url),
              let audioURL = URL(string: audioStream.url) else {
            throw URLError(.badURL)
        }

        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)

        guard let videoTrack = videoTracks.first,
              let audioTrack = audioTracks.first else {
            throw URLError(.cannotDecodeContentData)
        }

        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let duration = minimumDuration(videoDuration, audioDuration)

        let composition = AVMutableComposition()

        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw URLError(.cannotCreateFile)
        }

        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: videoTrack,
            at: .zero
        )
        compositionVideoTrack.preferredTransform = try await videoTrack.load(.preferredTransform)

        guard let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw URLError(.cannotCreateFile)
        }

        try compositionAudioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: audioTrack,
            at: .zero
        )

        let item = AVPlayerItem(asset: composition)
        item.preferredForwardBufferDuration = 12
        return item
    }

    private func minimumDuration(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        if lhs.isValid, rhs.isValid {
            return CMTimeMinimum(lhs, rhs)
        }
        return lhs.isValid ? lhs : rhs
    }
}
