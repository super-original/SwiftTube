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
    @Published private(set) var comments: [CommentItem] = []
    @Published private(set) var commentCountText: String? = nil
    @Published private(set) var isLoadingComments = false
    @Published private(set) var activeStream: StreamInfo? = nil
    @Published private(set) var isUsingAdaptivePlayback = false
    @Published private(set) var pendingAdaptiveStream: StreamInfo? = nil

    let video: VideoItem
    private var upgradeTask: Task<Void, Never>? = nil
    private var commentsTask: Task<Void, Never>? = nil

    init(video: VideoItem) {
        self.video = video
    }

    func load() {
        upgradeTask?.cancel()
        commentsTask?.cancel()
        Task {
            await fetchPlayback()
        }
    }

    func stop() {
        upgradeTask?.cancel()
        commentsTask?.cancel()
        player?.pause()
    }

    private func fetchPlayback() async {
        isLoading = true
        defer {
            if player != nil || errorMessage != nil {
                isLoading = false
            }
        }

        do {
            let playback = try await BackendClient.shared.fetchVideo(id: video.id)
            self.playback = playback
            self.player?.pause()
            self.player = nil
            self.activeStream = nil
            self.isUsingAdaptivePlayback = false
            self.comments = []
            self.commentCountText = playback.commentCountText
            self.isLoadingComments = false
            self.pendingAdaptiveStream = nil

            if let player = buildDirectPlayer(for: playback) {
                self.player = player
                self.activeStream = playback.preferredMuxedStream ?? playback.bestStream
                self.errorMessage = nil
                self.isLoading = false
                player.play()
                startCommentsLoad()

                if playback.playbackStrategy == "adaptivePair" {
                    self.pendingAdaptiveStream = playback.preferredVideoStream
                    upgradeTask = Task { [weak self] in
                        await self?.upgradeToAdaptivePlayback(playback: playback)
                    }
                }
                return
            }

            self.player = try await buildAdaptivePlayer(for: playback)
            self.activeStream = playback.preferredVideoStream ?? playback.bestStream
            self.isUsingAdaptivePlayback = true
            self.pendingAdaptiveStream = nil
            self.player?.play()
            errorMessage = nil
            isLoading = false
            startCommentsLoad()
        } catch {
            player = nil
            comments = []
            commentCountText = nil
            isLoadingComments = false
            activeStream = nil
            isUsingAdaptivePlayback = false
            pendingAdaptiveStream = nil
            errorMessage = "Failed to load video."
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

    private func buildDirectPlayer(for playback: VideoPlayback) -> AVPlayer? {
        if let stream = playback.preferredMuxedStream ?? playback.bestStream,
           let asset = buildAsset(for: stream) {
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player.automaticallyWaitsToMinimizeStalling = true
            player.currentItem?.preferredForwardBufferDuration = 8
            return player
        }
        if let url = resolvedDirectPlaybackURL(for: playback) {
            let player = AVPlayer(url: url)
            player.automaticallyWaitsToMinimizeStalling = true
            player.currentItem?.preferredForwardBufferDuration = 8
            return player
        }
        return nil
    }

    private func buildAdaptivePlayer(for playback: VideoPlayback) async throws -> AVPlayer {
        guard let videoStream = try await bestAdaptiveVideoStream(for: playback),
              let audioStream = bestAdaptiveAudioStream(for: playback) else {
            throw URLError(.badURL)
        }

        pendingAdaptiveStream = videoStream

        let item = try await buildAdaptivePlayerItem(
            videoStream: videoStream,
            audioStream: audioStream
        )

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        return player
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

    private func upgradeToAdaptivePlayback(playback: VideoPlayback) async {
        do {
            guard let videoStream = try await bestAdaptiveVideoStream(for: playback),
                  let audioStream = bestAdaptiveAudioStream(for: playback) else {
                pendingAdaptiveStream = nil
                return
            }

            pendingAdaptiveStream = videoStream
            let item = try await buildAdaptivePlayerItem(
                videoStream: videoStream,
                audioStream: audioStream
            )

            guard !Task.isCancelled else { return }

            let previousTime = player?.currentTime() ?? .zero
            let wasPlaying = player?.rate != 0

            if let player {
                player.replaceCurrentItem(with: item)
                _ = await player.seek(
                    to: previousTime,
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
                if wasPlaying || previousTime == .zero {
                    player.play()
                }
            }

            activeStream = videoStream
            isUsingAdaptivePlayback = true
            pendingAdaptiveStream = nil
        } catch {
            // Keep the direct stream if the higher-quality path fails.
            pendingAdaptiveStream = nil
        }
    }

    private func bestAdaptiveVideoStream(for playback: VideoPlayback) async throws -> StreamInfo? {
        let candidates = adaptiveVideoCandidates(for: playback)
        for candidate in candidates {
            pendingAdaptiveStream = candidate
            guard let asset = buildAsset(for: candidate) else { continue }
            let isPlayable = try await asset.load(.isPlayable)
            if isPlayable {
                return candidate
            }
        }
        return nil
    }

    private func bestAdaptiveAudioStream(for playback: VideoPlayback) -> StreamInfo? {
        if let preferred = playback.preferredAudioStream {
            return preferred
        }

        return playback.streams
            .filter {
                $0.hasAudio
                    && !$0.hasVideo
                    && ($0.container?.hasPrefix("m4a") == true || $0.container?.hasPrefix("mp4") == true)
            }
            .sorted(by: audioCandidateSort(lhs:rhs:))
            .first
    }

    private func adaptiveVideoCandidates(for playback: VideoPlayback) -> [StreamInfo] {
        let candidates = playback.streams.filter {
            $0.hasVideo
                && !$0.hasAudio
                && ($0.container?.hasPrefix("mp4") == true)
        }

        let sorted = candidates.sorted(by: adaptiveVideoCandidateSort(lhs:rhs:))
        if let preferred = playback.preferredVideoStream,
           let preferredIndex = sorted.firstIndex(of: preferred) {
            var reordered = sorted
            reordered.remove(at: preferredIndex)
            reordered.insert(preferred, at: 0)
            return reordered
        }
        return sorted
    }

    private func adaptiveVideoCandidateSort(lhs: StreamInfo, rhs: StreamInfo) -> Bool {
        let lhsScore = (
            lhs.height ?? 0,
            lhs.fps ?? 0,
            lhs.bitrate ?? 0,
            videoPlayabilityScore(for: lhs.videoCodec),
            codecScore(for: lhs.videoCodec)
        )
        let rhsScore = (
            rhs.height ?? 0,
            rhs.fps ?? 0,
            rhs.bitrate ?? 0,
            videoPlayabilityScore(for: rhs.videoCodec),
            codecScore(for: rhs.videoCodec)
        )
        return lhsScore > rhsScore
    }

    private func audioCandidateSort(lhs: StreamInfo, rhs: StreamInfo) -> Bool {
        let lhsScore = (lhs.bitrate ?? 0, codecScore(for: lhs.audioCodec))
        let rhsScore = (rhs.bitrate ?? 0, codecScore(for: rhs.audioCodec))
        return lhsScore > rhsScore
    }

    private func videoPlayabilityScore(for codec: String?) -> Int {
        guard let codec else { return 0 }
        if codec.hasPrefix("avc1") { return 4 }
        if codec.hasPrefix("hvc1") || codec.hasPrefix("hev1") { return 3 }
        if codec.hasPrefix("av01") { return 2 }
        if codec.hasPrefix("vp9") { return 1 }
        return 0
    }

    private func codecScore(for codec: String?) -> Int {
        guard let codec else { return 0 }
        if codec.hasPrefix("avc1") { return 5 }
        if codec.hasPrefix("hvc1") || codec.hasPrefix("hev1") { return 4 }
        if codec.hasPrefix("av01") { return 3 }
        if codec.hasPrefix("vp9") { return 2 }
        if codec.hasPrefix("mp4a") { return 4 }
        if codec.hasPrefix("opus") { return 3 }
        return 1
    }

    private func buildAdaptivePlayerItem(
        videoStream: StreamInfo,
        audioStream: StreamInfo
    ) async throws -> AVPlayerItem {
        guard let videoAsset = buildAsset(for: videoStream),
              let audioAsset = buildAsset(for: audioStream) else {
            throw URLError(.badURL)
        }

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

    private func buildAsset(for stream: StreamInfo) -> AVURLAsset? {
        guard let url = URL(string: stream.url) else { return nil }
        if let headers = stream.httpHeaders, !headers.isEmpty {
            return AVURLAsset(
                url: url,
                options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
            )
        }
        return AVURLAsset(url: url)
    }

    private func minimumDuration(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        if lhs.isValid, rhs.isValid {
            return CMTimeMinimum(lhs, rhs)
        }
        return lhs.isValid ? lhs : rhs
    }
}
