import AppKit
import AVFoundation
import AVKit
import SwiftUI

struct QualityOption: Identifiable, Hashable {
    static let automaticID = "quality-auto"

    enum Selection: Hashable {
        case automatic
        case manifestVariant(
            url: String,
            peakBitRate: Double,
            width: Double,
            height: Double
        )
        case stream(url: String)
    }

    let id: String
    let title: String
    let detail: String?
    let selection: Selection

    static let automatic = QualityOption(
        id: automaticID,
        title: "Auto",
        detail: nil,
        selection: .automatic
    )
}

struct SubtitleOption: Identifiable, Hashable {
    static let offID = "subtitle-off"

    let id: String
    let title: String
    let localeIdentifier: String?
    let optionIndex: Int?

    var isOff: Bool {
        optionIndex == nil
    }

    static let off = SubtitleOption(
        id: offID,
        title: "Off",
        localeIdentifier: nil,
        optionIndex: nil
    )
}

private struct PlaybackRestoreState {
    let currentTime: Double
    let wasPlaying: Bool
}

private struct SubtitleSelectionSnapshot {
    let title: String
    let localeIdentifier: String?
}

private struct SourceCandidate {
    let source: PlayerSourceDescriptor
    let height: Int
}

private struct ManifestSourceCandidate {
    let source: PlayerSourceDescriptor
    let maxHeight: Int
    let variantCount: Int
}

private enum PlayerSourceDescriptor {
    case manifestAutomatic(StreamInfo)
    case manifestVariant(parent: StreamInfo, url: URL)
    case direct(StreamInfo)
    case adaptivePair(video: StreamInfo, audio: StreamInfo)
}

@MainActor
final class PlayerPlaybackCoordinator: NSObject, ObservableObject {
    private enum Timing {
        static let inactivityHideDelay: UInt64 = 3_000_000_000
        static let unhoverHideDelay: UInt64 = 400_000_000
    }

    @Published private(set) var player: AVPlayer? = nil
    @Published private(set) var isPreparing = false
    @Published private(set) var errorMessage: String? = nil
    @Published private(set) var isPlaying = false
    @Published private(set) var controlsVisible = true
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var scrubPosition: Double = 0
    @Published private(set) var qualityOptions: [QualityOption] = [QualityOption.automatic]
    @Published private(set) var selectedQualityOptionID = QualityOption.automaticID
    @Published private(set) var subtitleOptions: [SubtitleOption] = []
    @Published private(set) var selectedSubtitleOptionID = SubtitleOption.offID
    @Published var volume: Double = 0.9 {
        didSet {
            applyVolume()
        }
    }
    @Published var isTheaterMode = false
    @Published private(set) var isFullscreen = false

    private var lastNonZeroVolume = 0.9
    private var isScrubbing = false
    private var isMenuInteractionActive = false
    private var isHoveringStage = false
    private var currentPlayback: VideoPlayback? = nil
    private var currentSource: PlayerSourceDescriptor? = nil
    private weak var window: NSWindow?
    private var legibleGroup: AVMediaSelectionGroup?
    private var legibleMediaOptions: [AVMediaSelectionOption] = []
    private var prepareTask: Task<Void, Never>? = nil
    private var hideControlsTask: Task<Void, Never>? = nil
    private var menuInteractionTask: Task<Void, Never>? = nil
    private var timeObserverToken: Any?
    private var timeControlObservation: NSKeyValueObservation?

    var playbackBadgeText: String {
        if selectedQualityOptionID == QualityOption.automaticID {
            return "Auto"
        }
        return currentQualityOption?.title ?? "Quality"
    }

    var qualityControlText: String {
        if selectedQualityOptionID == QualityOption.automaticID {
            return "Auto"
        }
        return currentQualityOption?.title ?? "Quality"
    }

    var qualityControlDetail: String? {
        guard selectedQualityOptionID != QualityOption.automaticID else {
            return nil
        }
        return currentQualityOption?.detail
    }

    var subtitleControlText: String {
        if subtitleOptions.isEmpty {
            return "No Subtitles"
        }
        return currentSubtitleOption?.title ?? SubtitleOption.off.title
    }

    var subtitleAccessibilityValue: String {
        currentSubtitleOption?.title ?? SubtitleOption.off.title
    }

    var subtitleSymbolName: String {
        return selectedSubtitleOptionID == SubtitleOption.offID
            ? "captions.bubble"
            : "captions.bubble.fill"
    }

    var fullscreenSymbolName: String {
        isFullscreen
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
    }

    var theaterSymbolName: String {
        isTheaterMode
            ? "rectangle.compress.vertical"
            : "rectangle.expand.vertical"
    }

    var volumeIconName: String {
        switch volume {
        case ..<0.01:
            return "speaker.slash.fill"
        case ..<0.34:
            return "speaker.wave.1.fill"
        case ..<0.67:
            return "speaker.wave.2.fill"
        default:
            return "speaker.wave.3.fill"
        }
    }

    var currentTimeText: String {
        formatTime(currentTime)
    }

    var remainingTimeText: String {
        guard duration > 0 else { return "--:--" }
        return "-\(formatTime(max(duration - currentTime, 0)))"
    }

    var scrubberUpperBound: Double {
        max(duration, 1)
    }

    var hasSubtitleOptions: Bool {
        !subtitleOptions.isEmpty
    }

    func configure(with playback: VideoPlayback) {
        prepareTask?.cancel()
        prepareTask = Task { [weak self] in
            await self?.preparePlayback(playback)
        }
    }

    func reset() {
        prepareTask?.cancel()
        hideControlsTask?.cancel()
        menuInteractionTask?.cancel()
        errorMessage = nil
        isPreparing = false
        controlsVisible = true
        isPlaying = false
        currentTime = 0
        duration = 0
        scrubPosition = 0
        qualityOptions = [QualityOption.automatic]
        selectedQualityOptionID = QualityOption.automaticID
        subtitleOptions = []
        selectedSubtitleOptionID = SubtitleOption.offID
        legibleGroup = nil
        legibleMediaOptions = []
        currentSource = nil
        currentPlayback = nil
        teardownPlayerObservers()
        player?.pause()
        player = nil
    }

    func stop() {
        reset()
    }

    func setWindow(_ window: NSWindow?) {
        if self.window === window {
            isFullscreen = window?.styleMask.contains(.fullScreen) == true
            return
        }

        if let currentWindow = self.window {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didEnterFullScreenNotification,
                object: currentWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didExitFullScreenNotification,
                object: currentWindow
            )
        }

        self.window = window
        isFullscreen = window?.styleMask.contains(.fullScreen) == true

        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleWindowDidEnterFullScreen(_:)),
                name: NSWindow.didEnterFullScreenNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleWindowDidExitFullScreen(_:)),
                name: NSWindow.didExitFullScreenNotification,
                object: window
            )
        }
    }

    func togglePlayback() {
        noteInteraction()
        guard let player else { return }

        if isPlaying {
            player.pause()
        } else {
            if let item = player.currentItem,
               duration > 0,
               item.currentTime().seconds >= duration - 0.25 {
                player.seek(to: .zero)
            }
            player.play()
        }
    }

    func toggleMute() {
        noteInteraction()
        if volume <= 0.01 {
            volume = max(lastNonZeroVolume, 0.5)
        } else {
            lastNonZeroVolume = volume
            volume = 0
        }
    }

    func setScrubbing(_ isEditing: Bool) {
        isScrubbing = isEditing
        noteInteraction()

        if isEditing {
            scrubPosition = currentTime
            hideControlsTask?.cancel()
            return
        }

        seekToScrubPosition()
    }

    func updateScrubPosition(_ value: Double) {
        scrubPosition = value
        noteInteraction()
    }

    func cycleSubtitles() {
        noteInteraction()
        guard let item = player?.currentItem else { return }
        guard !subtitleOptions.isEmpty else { return }

        let nextOption: SubtitleOption
        if selectedSubtitleOptionID == SubtitleOption.offID {
            nextOption = subtitleOptions[0]
        } else if let index = subtitleOptions.firstIndex(where: { $0.id == selectedSubtitleOptionID }),
                  index + 1 < subtitleOptions.count {
            nextOption = subtitleOptions[index + 1]
        } else {
            nextOption = .off
        }

        applySubtitleSelection(nextOption, on: item)
    }

    func beginMenuInteraction() {
        isMenuInteractionActive = true
        noteInteraction()
        menuInteractionTask?.cancel()
        menuInteractionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.endMenuInteraction()
        }
    }

    func endMenuInteraction() {
        isMenuInteractionActive = false
        scheduleAutoHideIfNeeded()
    }

    func selectQuality(_ option: QualityOption) {
        guard let playback = currentPlayback else { return }
        guard option.id != selectedQualityOptionID || option.id == QualityOption.automaticID else {
            endMenuInteraction()
            return
        }

        let restoreState = currentRestoreState()
        let subtitleSnapshot = currentSubtitleSnapshot()
        prepareTask?.cancel()
        prepareTask = Task { [weak self] in
            await self?.switchQuality(
                to: option,
                playback: playback,
                restoreState: restoreState,
                subtitleSnapshot: subtitleSnapshot
            )
        }
    }

    func setHovering(_ isHovering: Bool) {
        isHoveringStage = isHovering

        if isHovering {
            noteInteraction()
        } else {
            scheduleAutoHideIfNeeded(delay: Timing.unhoverHideDelay)
        }
    }

    func handlePointerMovement() {
        noteInteraction()
    }

    func toggleTheaterMode() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isTheaterMode.toggle()
        }
        noteInteraction()
    }

    func toggleFullscreen() {
        noteInteraction()
        window?.toggleFullScreen(nil)
    }

    private var currentQualityOption: QualityOption? {
        qualityOptions.first(where: { $0.id == selectedQualityOptionID })
    }

    private var currentSubtitleOption: SubtitleOption? {
        if selectedSubtitleOptionID == SubtitleOption.offID {
            return .off
        }
        return subtitleOptions.first(where: { $0.id == selectedSubtitleOptionID })
    }

    private func preparePlayback(_ playback: VideoPlayback) async {
        errorMessage = nil
        isPreparing = true
        controlsVisible = true

        do {
            let source = try await preferredSource(for: playback)
            let item = try await buildPlayerItem(for: source)
            guard !Task.isCancelled else { return }

            currentPlayback = playback
            currentSource = source
            selectedQualityOptionID = QualityOption.automaticID

            let player = ensurePlayer()
            player.replaceCurrentItem(with: item)
            player.currentItem?.preferredForwardBufferDuration = 12

            try await refreshPlaybackMetadata(
                for: item,
                playback: playback,
                preferredSubtitle: nil
            )

            guard !Task.isCancelled else { return }
            currentTime = 0
            scrubPosition = 0
            player.play()
            scheduleAutoHideIfNeeded()
        } catch {
            if !Task.isCancelled {
                errorMessage = "Failed to prepare video."
                player?.pause()
            }
        }

        if !Task.isCancelled {
            isPreparing = false
        }
    }

    private func switchQuality(
        to option: QualityOption,
        playback: VideoPlayback,
        restoreState: PlaybackRestoreState,
        subtitleSnapshot: SubtitleSelectionSnapshot?
    ) async {
        errorMessage = nil
        isPreparing = true

        do {
            let source = try await source(for: option, playback: playback)
            let item = try await buildPlayerItem(for: source)
            guard !Task.isCancelled else { return }

            let player = ensurePlayer()
            player.replaceCurrentItem(with: item)
            player.currentItem?.preferredForwardBufferDuration = 12
            currentSource = source
            selectedQualityOptionID = option.id

            try await refreshPlaybackMetadata(
                for: item,
                playback: playback,
                preferredSubtitle: subtitleSnapshot
            )

            let clampedTime = min(restoreState.currentTime, max(duration - 0.25, 0))
            await seek(player: player, to: clampedTime)

            if restoreState.wasPlaying {
                player.play()
            } else {
                player.pause()
                controlsVisible = true
            }
            currentTime = clampedTime
            scrubPosition = clampedTime
        } catch {
            if !Task.isCancelled {
                errorMessage = "Failed to switch quality."
            }
        }

        if !Task.isCancelled {
            isPreparing = false
            endMenuInteraction()
        }
    }

    private func refreshPlaybackMetadata(
        for item: AVPlayerItem,
        playback: VideoPlayback,
        preferredSubtitle: SubtitleSelectionSnapshot?
    ) async throws {
        try await refreshDuration(using: item)
        try await refreshQualityOptions(for: playback)
        try await refreshSubtitleOptions(for: item, preferredSelection: preferredSubtitle)
    }

    private func refreshDuration(using item: AVPlayerItem) async throws {
        let assetDuration = try await item.asset.load(.duration)
        duration = sanitizeSeconds(assetDuration.seconds)
        scrubPosition = currentTime
    }

    private func refreshQualityOptions(for playback: VideoPlayback) async throws {
        switch currentSource {
        case .manifestAutomatic(let manifestStream), .manifestVariant(parent: let manifestStream, url: _):
            if let manifestAsset = buildAsset(for: manifestStream) {
                let variants = try? await manifestAsset.load(.variants)
                let manifestOptions = buildManifestQualityOptions(from: variants ?? [])
                if !manifestOptions.isEmpty {
                    qualityOptions = [QualityOption.automatic] + manifestOptions
                    if qualityOptions.contains(where: { $0.id == selectedQualityOptionID }) == false {
                        selectedQualityOptionID = QualityOption.automaticID
                    }
                    return
                }
            }
        case .direct, .adaptivePair, .none:
            break
        }

        let directOptions = buildFallbackQualityOptions(for: playback)
        qualityOptions = [QualityOption.automatic] + directOptions
        if qualityOptions.contains(where: { $0.id == selectedQualityOptionID }) == false {
            selectedQualityOptionID = QualityOption.automaticID
        }
    }

    private func refreshSubtitleOptions(
        for item: AVPlayerItem,
        preferredSelection: SubtitleSelectionSnapshot?
    ) async throws {
        legibleGroup = nil
        legibleMediaOptions = []
        subtitleOptions = []
        selectedSubtitleOptionID = SubtitleOption.offID

        guard let group = try await item.asset.loadMediaSelectionGroup(for: .legible) else {
            return
        }

        legibleGroup = group
        legibleMediaOptions = group.options
        subtitleOptions = group.options.enumerated().map { index, option in
            SubtitleOption(
                id: subtitleIdentifier(for: option, index: index),
                title: subtitleTitle(for: option),
                localeIdentifier: option.locale?.identifier,
                optionIndex: index
            )
        }

        if let preferredSelection,
           let matchingOption = matchSubtitleOption(to: preferredSelection) {
            applySubtitleSelection(matchingOption, on: item, shouldNoteInteraction: false)
            return
        }

        updateSelectedSubtitleState(from: item)
    }

    private func ensurePlayer() -> AVPlayer {
        if let player {
            player.volume = Float(volume)
            return player
        }

        let player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = Float(volume)
        self.player = player
        setupPlayerObservers(for: player)
        return player
    }

    private func setupPlayerObservers(for player: AVPlayer) {
        teardownPlayerObservers()

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.handlePeriodicTimeUpdate(time)
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) {
            [weak self] observedPlayer, _ in
            Task { @MainActor in
                self?.handlePlaybackStateChange(observedPlayer.timeControlStatus)
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePlayerItemDidEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
    }

    private func teardownPlayerObservers() {
        if let player, let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
        timeObserverToken = nil
        timeControlObservation = nil

        NotificationCenter.default.removeObserver(
            self,
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
    }

    @objc private func handlePlayerItemDidEnd(_ notification: Notification) {
        guard let currentItem = player?.currentItem else { return }
        guard notification.object as? AVPlayerItem === currentItem else { return }
        isPlaying = false
        controlsVisible = true
        currentTime = duration
        scrubPosition = duration
    }

    @objc private func handleWindowDidEnterFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            isFullscreen = true
        }
    }

    @objc private func handleWindowDidExitFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            isFullscreen = false
        }
    }

    private func handlePeriodicTimeUpdate(_ time: CMTime) {
        let seconds = sanitizeSeconds(time.seconds)
        guard !isScrubbing else { return }
        currentTime = seconds
        scrubPosition = seconds

        if let itemDuration = player?.currentItem?.duration.seconds {
            let resolvedDuration = sanitizeSeconds(itemDuration)
            if resolvedDuration > 0 {
                duration = resolvedDuration
            }
        }
    }

    private func handlePlaybackStateChange(_ status: AVPlayer.TimeControlStatus) {
        withAnimation(.easeInOut(duration: 0.18)) {
            isPlaying = status == .playing
        }
        if isPlaying {
            scheduleAutoHideIfNeeded()
        } else {
            hideControlsTask?.cancel()
            controlsVisible = true
        }
    }

    private func scheduleAutoHideIfNeeded(delay: UInt64? = nil) {
        hideControlsTask?.cancel()
        guard isPlaying, !isScrubbing, !isMenuInteractionActive else { return }
        let resolvedDelay = delay ?? (isHoveringStage ? Timing.inactivityHideDelay : Timing.unhoverHideDelay)

        hideControlsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: resolvedDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard self.isPlaying, !self.isScrubbing, !self.isMenuInteractionActive else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    self.controlsVisible = false
                }
            }
        }
    }

    private func noteInteraction() {
        withAnimation(.easeInOut(duration: 0.16)) {
            controlsVisible = true
        }
        scheduleAutoHideIfNeeded()
    }

    private func applyVolume() {
        let clampedVolume = min(max(volume, 0), 1)
        if clampedVolume > 0.01 {
            lastNonZeroVolume = clampedVolume
        }
        if clampedVolume != volume {
            volume = clampedVolume
            return
        }
        player?.volume = Float(clampedVolume)
    }

    private func currentRestoreState() -> PlaybackRestoreState {
        PlaybackRestoreState(
            currentTime: sanitizeSeconds(player?.currentTime().seconds ?? currentTime),
            wasPlaying: isPlaying
        )
    }

    private func currentSubtitleSnapshot() -> SubtitleSelectionSnapshot? {
        guard let currentSubtitleOption,
              currentSubtitleOption.isOff == false else {
            return nil
        }

        return SubtitleSelectionSnapshot(
            title: currentSubtitleOption.title,
            localeIdentifier: currentSubtitleOption.localeIdentifier
        )
    }

    private func seekToScrubPosition() {
        guard let player else { return }

        Task { [weak self] in
            guard let self else { return }
            let target = min(scrubPosition, scrubberUpperBound)
            await seek(player: player, to: target)
            currentTime = target
            scrubPosition = target
            scheduleAutoHideIfNeeded()
        }
    }

    private func seek(player: AVPlayer, to seconds: Double) async {
        let target = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        await withCheckedContinuation { continuation in
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
    }

    private func source(for option: QualityOption, playback: VideoPlayback) async throws -> PlayerSourceDescriptor {
        switch option.selection {
        case .automatic:
            return try await preferredSource(for: playback)
        case .manifestVariant(let url, _, _, _):
            guard let manifestStream = playback.preferredManifestStream,
                  let variantURL = URL(string: url) else {
                throw URLError(.badURL)
            }
            return .manifestVariant(parent: manifestStream, url: variantURL)
        case .stream(let url):
            guard let stream = playback.streams.first(where: { $0.url == url }) else {
                throw URLError(.fileDoesNotExist)
            }
            if stream.hasAudio {
                return .direct(stream)
            }
            guard let audioStream = bestAdaptiveAudioStream(for: playback) else {
                throw URLError(.cannotDecodeContentData)
            }
            return .adaptivePair(video: stream, audio: audioStream)
        }
    }

    private func preferredSource(for playback: VideoPlayback) async throws -> PlayerSourceDescriptor {
        let manifestCandidate = try await preferredManifestSource(for: playback)
        let nonManifestCandidate = try await preferredNonManifestSource(for: playback)

        if let nonManifestCandidate {
            if let manifestCandidate,
               manifestCandidate.variantCount > 1,
               manifestCandidate.maxHeight >= nonManifestCandidate.height {
                return manifestCandidate.source
            }
            return nonManifestCandidate.source
        }

        if let manifestCandidate {
            return manifestCandidate.source
        }

        throw URLError(.badURL)
    }

    private func preferredManifestSource(
        for playback: VideoPlayback
    ) async throws -> ManifestSourceCandidate? {
        guard let manifestStream = playback.preferredManifestStream,
              try await isPlayable(stream: manifestStream) else {
            return nil
        }

        let maxHeight: Int
        let variantCount: Int
        if let manifestAsset = buildAsset(for: manifestStream),
           let variants = try? await manifestAsset.load(.variants),
           !variants.isEmpty {
            maxHeight = variants
                .compactMap { variant in
                    let height = variant.videoAttributes?.presentationSize.height ?? 0
                    return height > 0 ? Int(height.rounded()) : nil
                }
                .max() ?? (manifestStream.height ?? 0)
            variantCount = variants.count
        } else {
            maxHeight = manifestStream.height ?? 0
            variantCount = 0
        }

        return ManifestSourceCandidate(
            source: .manifestAutomatic(manifestStream),
            maxHeight: maxHeight,
            variantCount: variantCount
        )
    }

    private func preferredNonManifestSource(
        for playback: VideoPlayback
    ) async throws -> SourceCandidate? {
        var candidates: [SourceCandidate] = []

        if let directStream = preferredDirectStream(for: playback),
           try await isPlayable(stream: directStream) {
            candidates.append(
                SourceCandidate(
                    source: .direct(directStream),
                    height: directStream.height ?? 0
                )
            )
        }

        if let adaptiveSource = try await preferredAdaptiveSource(for: playback) {
            candidates.append(
                SourceCandidate(
                    source: adaptiveSource,
                    height: sourceHeight(for: adaptiveSource)
                )
            )
        }

        if let bestCandidate = candidates.max(by: { $0.height < $1.height }) {
            return bestCandidate
        }

        if let adaptiveSource = try await preferredAdaptiveSource(for: playback) {
            return SourceCandidate(
                source: adaptiveSource,
                height: sourceHeight(for: adaptiveSource)
            )
        }

        if let directStream = preferredDirectStream(for: playback) {
            return SourceCandidate(
                source: .direct(directStream),
                height: directStream.height ?? 0
            )
        }

        return nil
    }

    private func preferredDirectStream(for playback: VideoPlayback) -> StreamInfo? {
        if let preferredMuxedStream = playback.preferredMuxedStream {
            return preferredMuxedStream
        }

        guard let bestStream = playback.bestStream, bestStream.streamKind != "manifest" else {
            return nil
        }
        return bestStream
    }

    private func preferredAdaptiveSource(for playback: VideoPlayback) async throws -> PlayerSourceDescriptor? {
        guard let videoStream = try await bestAdaptiveVideoStream(for: playback),
              let audioStream = bestAdaptiveAudioStream(for: playback) else {
            return nil
        }
        return .adaptivePair(video: videoStream, audio: audioStream)
    }

    private func buildPlayerItem(for source: PlayerSourceDescriptor) async throws -> AVPlayerItem {
        switch source {
        case .manifestAutomatic(let stream), .direct(let stream):
            guard let asset = buildAsset(for: stream) else {
                throw URLError(.badURL)
            }
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 12
            return item
        case .manifestVariant(let parent, let url):
            let asset = buildAsset(url: url, headers: parent.httpHeaders)
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 12
            item.preferredPeakBitRate = 0
            item.preferredMaximumResolution = .zero
            return item
        case .adaptivePair(let video, let audio):
            return try await buildAdaptivePlayerItem(videoStream: video, audioStream: audio)
        }
    }

    private func sourceHeight(for source: PlayerSourceDescriptor) -> Int {
        switch source {
        case .manifestAutomatic(let stream):
            return stream.height ?? 0
        case .manifestVariant(_, let url):
            let path = url.absoluteString.lowercased()
            if let resolutionFragment = path.split(separator: "/").first(where: { $0.hasSuffix("p") }),
               let height = Int(resolutionFragment.dropLast()) {
                return height
            }
            return 0
        case .direct(let stream):
            return stream.height ?? 0
        case .adaptivePair(let video, _):
            return video.height ?? 0
        }
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

    private func buildManifestQualityOptions(from variants: [AVAssetVariant]) -> [QualityOption] {
        variants
            .filter { variant in
                let size = variant.videoAttributes?.presentationSize ?? .zero
                return size.height > 0 || (variant.peakBitRate ?? 0) > 0
            }
            .sorted(by: manifestVariantSort(lhs:rhs:))
            .map { variant in
                let size = variant.videoAttributes?.presentationSize ?? .zero
                let height = Double(size.height)
                let width = Double(size.width)
                let title = qualityTitle(
                    height: height,
                    width: width,
                    bitrate: variant.peakBitRate ?? 0
                )
                let detail = bitrateText(variant.peakBitRate ?? 0)
                return QualityOption(
                    id: "variant-\(variant.url.absoluteString)",
                    title: title,
                    detail: detail,
                    selection: .manifestVariant(
                        url: variant.url.absoluteString,
                        peakBitRate: variant.peakBitRate ?? 0,
                        width: width,
                        height: height
                    )
                )
            }
    }

    private func buildFallbackQualityOptions(for playback: VideoPlayback) -> [QualityOption] {
        var seenKeys = Set<String>()
        let audioStream = bestAdaptiveAudioStream(for: playback)

        return playback.streams
            .filter { stream in
                guard stream.streamKind != "manifest" else { return false }
                guard stream.hasVideo else { return false }
                if stream.hasAudio {
                    return true
                }
                return audioStream != nil
            }
            .sorted(by: fallbackQualitySort(lhs:rhs:))
            .compactMap { stream in
                let title = qualityTitle(
                    height: Double(stream.height ?? 0),
                    width: Double(stream.width ?? 0),
                    bitrate: Double(stream.bitrate ?? 0)
                )
                let key = "\(title)-\(stream.hasAudio)"
                guard seenKeys.insert(key).inserted else { return nil }
                let detail = bitrateText(Double(stream.bitrate ?? 0))
                return QualityOption(
                    id: "stream-\(stream.url)",
                    title: title,
                    detail: detail,
                    selection: .stream(url: stream.url)
                )
            }
    }

    private func matchSubtitleOption(to snapshot: SubtitleSelectionSnapshot) -> SubtitleOption? {
        if let localeMatch = subtitleOptions.first(where: {
            $0.localeIdentifier == snapshot.localeIdentifier && $0.title == snapshot.title
        }) {
            return localeMatch
        }

        return subtitleOptions.first(where: { $0.title == snapshot.title })
    }

    private func applySubtitleSelection(
        _ option: SubtitleOption,
        on item: AVPlayerItem,
        shouldNoteInteraction: Bool = true
    ) {
        if shouldNoteInteraction {
            noteInteraction()
        }

        guard let legibleGroup else {
            selectedSubtitleOptionID = SubtitleOption.offID
            return
        }

        if option.isOff {
            item.select(nil, in: legibleGroup)
            selectedSubtitleOptionID = SubtitleOption.offID
            return
        }

        guard let optionIndex = option.optionIndex,
              legibleMediaOptions.indices.contains(optionIndex) else {
            selectedSubtitleOptionID = SubtitleOption.offID
            return
        }

        item.select(legibleMediaOptions[optionIndex], in: legibleGroup)
        selectedSubtitleOptionID = option.id
    }

    private func updateSelectedSubtitleState(from item: AVPlayerItem) {
        guard let legibleGroup else {
            selectedSubtitleOptionID = SubtitleOption.offID
            return
        }

        guard let selectedOption = item.currentMediaSelection.selectedMediaOption(in: legibleGroup) else {
            selectedSubtitleOptionID = SubtitleOption.offID
            return
        }

        guard let selectedIndex = legibleMediaOptions.firstIndex(of: selectedOption),
              subtitleOptions.indices.contains(selectedIndex) else {
            selectedSubtitleOptionID = SubtitleOption.offID
            return
        }

        selectedSubtitleOptionID = subtitleOptions[selectedIndex].id
    }

    private func subtitleIdentifier(for option: AVMediaSelectionOption, index: Int) -> String {
        let locale = option.locale?.identifier ?? "und"
        return "subtitle-\(index)-\(locale)-\(subtitleTitle(for: option))"
    }

    private func subtitleTitle(for option: AVMediaSelectionOption) -> String {
        if option.displayName.isEmpty == false {
            return option.displayName
        }
        if let localeTitle = option.locale?.localizedString(forIdentifier: option.locale?.identifier ?? "") {
            return localeTitle
        }
        return "Subtitle \(option.extendedLanguageTag ?? "\(UUID().uuidString.prefix(4))")"
    }

    private func isPlayable(stream: StreamInfo) async throws -> Bool {
        guard let asset = buildAsset(for: stream) else { return false }
        return try await asset.load(.isPlayable)
    }

    private func bestAdaptiveVideoStream(for playback: VideoPlayback) async throws -> StreamInfo? {
        let candidates = playback.streams
            .filter {
                $0.hasVideo
                    && !$0.hasAudio
                    && ($0.container?.hasPrefix("mp4") == true)
            }
            .sorted(by: adaptiveVideoCandidateSort(lhs:rhs:))

        for candidate in candidates {
            if try await isPlayable(stream: candidate) {
                return candidate
            }
        }

        return nil
    }

    private func bestAdaptiveAudioStream(for playback: VideoPlayback) -> StreamInfo? {
        if let preferredAudioStream = playback.preferredAudioStream {
            return preferredAudioStream
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

    private func fallbackQualitySort(lhs: StreamInfo, rhs: StreamInfo) -> Bool {
        let lhsScore = (
            lhs.height ?? 0,
            lhs.hasAudio ? 1 : 0,
            lhs.fps ?? 0,
            lhs.bitrate ?? 0,
            codecScore(for: lhs.videoCodec)
        )
        let rhsScore = (
            rhs.height ?? 0,
            rhs.hasAudio ? 1 : 0,
            rhs.fps ?? 0,
            rhs.bitrate ?? 0,
            codecScore(for: rhs.videoCodec)
        )
        return lhsScore > rhsScore
    }

    private func manifestVariantSort(lhs: AVAssetVariant, rhs: AVAssetVariant) -> Bool {
        let lhsSize = lhs.videoAttributes?.presentationSize ?? .zero
        let rhsSize = rhs.videoAttributes?.presentationSize ?? .zero
        let lhsScore = (lhsSize.height, lhsSize.width, lhs.peakBitRate ?? 0)
        let rhsScore = (rhsSize.height, rhsSize.width, rhs.peakBitRate ?? 0)
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

    private func buildAsset(for stream: StreamInfo) -> AVURLAsset? {
        guard let url = URL(string: stream.url) else { return nil }
        return buildAsset(url: url, headers: stream.httpHeaders)
    }

    private func buildAsset(url: URL, headers: [String: String]?) -> AVURLAsset {
        if let headers, !headers.isEmpty {
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

    private func qualityTitle(height: Double, width: Double, bitrate: Double) -> String {
        if height > 0 {
            return "\(Int(height.rounded()))p"
        }
        if width > 0 {
            return "\(Int(width.rounded()))w"
        }
        if bitrate > 0 {
            return bitrateText(bitrate) ?? "Quality"
        }
        return "Quality"
    }

    private func bitrateText(_ bitrate: Double) -> String? {
        guard bitrate > 0 else { return nil }
        return String(format: "%.1f Mbps", bitrate / 1_000_000)
    }

    private func sanitizeSeconds(_ seconds: Double) -> Double {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }

        let total = Int(seconds.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60

        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", remainder))"
        }
        return "\(minutes):\(String(format: "%02d", remainder))"
    }
}
