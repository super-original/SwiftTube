import AppKit
import AVFoundation
import AVKit
import SwiftUI
import VideoToolbox

struct ManualPlaybackSelection: Hashable, Sendable {
    let backend: PlaybackBackendKind
    let stream: StreamInfo
    let audioStream: StreamInfo?
}

enum PlayerRenderState {
    case avFoundation(AVPlayer)
    case mpv(MPVPlaybackEngine)
}

struct QualityOption: Identifiable, Hashable, Sendable {
    static let automaticID = "quality-auto"

    enum Selection: Hashable, Sendable {
        case automatic
        case manifestVariant(
            url: String,
            peakBitRate: Double,
            width: Double,
            height: Double
        )
        case manual(ManualPlaybackSelection)
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

private extension QualityOption.Selection {
    var streamHeight: Int {
        switch self {
        case .manual(let selection):
            return selection.stream.height ?? 0
        case .manifestVariant(_, _, _, let height):
            return Int(height.rounded())
        case .automatic:
            return 0
        }
    }

    var streamFPS: Int {
        switch self {
        case .manual(let selection):
            return selection.stream.fps ?? 0
        case .manifestVariant:
            return 0
        case .automatic:
            return 0
        }
    }

    var streamBitrate: Int {
        switch self {
        case .manual(let selection):
            return selection.stream.bitrate ?? 0
        case .manifestVariant(_, let peakBitRate, _, _):
            return Int(peakBitRate.rounded())
        case .automatic:
            return 0
        }
    }
}

struct SubtitleOption: Identifiable, Hashable, Sendable {
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

private struct PlaybackRestoreState: Sendable {
    let currentTime: Double
    let wasPlaying: Bool
}

private struct SubtitleSelectionSnapshot: Sendable {
    let title: String
    let localeIdentifier: String?
}

private struct SourceCandidate: Sendable {
    let source: PlayerSourceDescriptor
    let height: Int
}

private struct ManifestSourceCandidate: Sendable {
    let source: PlayerSourceDescriptor
    let maxHeight: Int
    let variantCount: Int
}

private struct ManualQualityCandidate: Sendable {
    let selection: ManualPlaybackSelection
    let capability: PlaybackCapability
    let bitrate: Int
}

private enum PlayerSourceDescriptor: Sendable {
    case manifestAutomatic(StreamInfo)
    case manifestVariant(parent: StreamInfo, url: URL)
    case direct(StreamInfo)
    case adaptivePair(video: StreamInfo, audio: StreamInfo)
}

private func playbackCodecScore(for codec: String?) -> Int {
    guard let codec else { return 0 }
    if codec.hasPrefix("avc1") { return 5 }
    if codec.hasPrefix("hvc1") || codec.hasPrefix("hev1") { return 4 }
    if codec.hasPrefix("av01") { return 3 }
    if codec.hasPrefix("vp9") { return 2 }
    if codec.hasPrefix("mp4a") { return 4 }
    if codec.hasPrefix("opus") { return 3 }
    return 1
}

private func adaptiveAudioPreference(for stream: StreamInfo) -> (Int, Int, Int, Int) {
    let channels = stream.audioChannels ?? 0
    let channelPreference: Int
    let channelTiebreaker: Int

    switch channels {
    case 2:
        channelPreference = 3
        channelTiebreaker = 0
    case 1:
        channelPreference = 2
        channelTiebreaker = 0
    case let value where value > 2:
        channelPreference = 1
        channelTiebreaker = -value
    default:
        channelPreference = 0
        channelTiebreaker = 0
    }

    return (
        channelPreference,
        playbackCodecScore(for: stream.audioCodec),
        channelTiebreaker,
        stream.bitrate ?? 0
    )
}

private func compatibilityCodecPreference(for codec: String?) -> Int {
    guard let codec else { return 0 }
    if codec.hasPrefix("vp9") { return 3 }
    if codec.hasPrefix("av01") { return 2 }
    if codec.hasPrefix("avc1") { return 1 }
    if codec.hasPrefix("hvc1") || codec.hasPrefix("hev1") { return 1 }
    return 0
}

private enum AVFoundationPlaybackSupport {
    static let supportsAV1: Bool = {
        if #available(macOS 14.0, *) {
            return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        }
        return false
    }()
}

private func isAVFoundationVideoCodecSupported(_ codec: String?) -> Bool {
    guard let codec else { return false }
    if codec.hasPrefix("avc1") { return true }
    if codec.hasPrefix("hvc1") || codec.hasPrefix("hev1") { return true }
    if codec.hasPrefix("av01") { return AVFoundationPlaybackSupport.supportsAV1 }
    return false
}

private func isAVFoundationVideoContainerSupported(_ container: String?) -> Bool {
    guard let container = container?.lowercased() else { return false }
    return container.hasPrefix("mp4") || container.hasPrefix("mov") || container.hasPrefix("m4v")
}

private func isMPVCompatibleVideoContainer(_ container: String?) -> Bool {
    guard let container = container?.lowercased() else { return false }
    return container.hasPrefix("mp4")
        || container.hasPrefix("mov")
        || container.hasPrefix("m4v")
        || container.hasPrefix("webm")
        || container.hasPrefix("mkv")
}

private func isMPVCompatibleVideoCodec(_ codec: String?) -> Bool {
    guard let codec else { return false }
    return codec.hasPrefix("avc1")
        || codec.hasPrefix("hvc1")
        || codec.hasPrefix("hev1")
        || codec.hasPrefix("av01")
        || codec.hasPrefix("vp9")
}

private func hasConflictingHeaders(video: StreamInfo, audio: StreamInfo?) -> Bool {
    guard let audio else { return false }
    let videoHeaders = video.httpHeaders ?? [:]
    let audioHeaders = audio.httpHeaders ?? [:]

    for (key, value) in videoHeaders {
        if let audioValue = audioHeaders[key], audioValue != value {
            return true
        }
    }

    return false
}

private func isSupportedDirectStream(_ stream: StreamInfo) -> Bool {
    guard stream.hasVideo, stream.hasAudio, stream.streamKind != "manifest" else {
        return false
    }

    return isAVFoundationVideoContainerSupported(stream.container)
        && isAVFoundationVideoCodecSupported(stream.videoCodec)
}

private func isSupportedVideoOnlyStream(_ stream: StreamInfo) -> Bool {
    guard stream.hasVideo, !stream.hasAudio, stream.streamKind != "manifest" else {
        return false
    }

    return isAVFoundationVideoContainerSupported(stream.container)
        && isAVFoundationVideoCodecSupported(stream.videoCodec)
}

private func preferredAdaptiveAudioStream(for playback: VideoPlayback) -> StreamInfo? {
    if let preferredAudioStream = playback.preferredAudioStream {
        return preferredAudioStream
    }

    return playback.streams
        .filter {
            $0.hasAudio
                && !$0.hasVideo
                && ($0.container?.hasPrefix("m4a") == true || $0.container?.hasPrefix("mp4") == true)
        }
        .sorted { lhs, rhs in
            let lhsScore = adaptiveAudioPreference(for: lhs)
            let rhsScore = adaptiveAudioPreference(for: rhs)
            return lhsScore > rhsScore
        }
        .first
}

private func manualQualityCandidate(
    for stream: StreamInfo,
    playback: VideoPlayback
) -> ManualQualityCandidate? {
    guard stream.hasVideo, stream.streamKind != "manifest" else {
        return nil
    }

    if isSupportedDirectStream(stream) {
        return ManualQualityCandidate(
            selection: ManualPlaybackSelection(
                backend: .avFoundation,
                stream: stream,
                audioStream: nil
            ),
            capability: .native,
            bitrate: stream.bitrate ?? 0
        )
    }

    if isSupportedVideoOnlyStream(stream),
       let audioStream = preferredAdaptiveAudioStream(for: playback) {
        return ManualQualityCandidate(
            selection: ManualPlaybackSelection(
                backend: .avFoundation,
                stream: stream,
                audioStream: audioStream
            ),
            capability: .native,
            bitrate: stream.bitrate ?? 0
        )
    }

    guard isMPVCompatibleVideoContainer(stream.container),
          isMPVCompatibleVideoCodec(stream.videoCodec) else {
        return nil
    }

    let audioStream = stream.hasAudio ? nil : preferredAdaptiveAudioStream(for: playback)
    if stream.hasAudio == false, audioStream == nil {
        return nil
    }

    if hasConflictingHeaders(video: stream, audio: audioStream) {
        return nil
    }

    return ManualQualityCandidate(
        selection: ManualPlaybackSelection(
            backend: .mpv,
            stream: stream,
            audioStream: audioStream
        ),
        capability: .compatibility,
        bitrate: stream.bitrate ?? 0
    )
}

private func automaticStartupSource(for playback: VideoPlayback) -> PlayerSourceDescriptor? {
    if let manifestStream = playback.preferredManifestStream {
        return .manifestAutomatic(manifestStream)
    }

    if let muxedStream = playback.preferredMuxedStream, isSupportedDirectStream(muxedStream) {
        return .direct(muxedStream)
    }

    if let bestStream = playback.bestStream, isSupportedDirectStream(bestStream) {
        return .direct(bestStream)
    }

    if let videoStream = playback.preferredVideoStream,
       isSupportedVideoOnlyStream(videoStream),
       let audioStream = preferredAdaptiveAudioStream(for: playback) {
        return .adaptivePair(video: videoStream, audio: audioStream)
    }

    if let fallbackMuxedStream = playback.streams.first(where: isSupportedDirectStream) {
        return .direct(fallbackMuxedStream)
    }

    if let fallbackVideoStream = playback.streams.first(where: isSupportedVideoOnlyStream),
       let audioStream = preferredAdaptiveAudioStream(for: playback) {
        return .adaptivePair(video: fallbackVideoStream, audio: audioStream)
    }

    return nil
}

@MainActor
final class PlayerLayoutState: ObservableObject {
    @Published var isTheaterMode = false
    @Published var isFullscreen = false
}

private actor QualityCoordinator {
    private var playbackID: String? = nil
    private var cachedSources: [String: PlayerSourceDescriptor] = [:]

    func reset() {
        playbackID = nil
        cachedSources = [:]
    }

    func prime(
        playback: VideoPlayback,
        automaticSource: PlayerSourceDescriptor,
        options: [QualityOption]
    ) {
        playbackID = playback.id
        cachedSources = [QualityOption.automaticID: automaticSource]
        cache(options: options, for: playback, automaticSource: automaticSource)
    }

    func cache(
        options: [QualityOption],
        for playback: VideoPlayback,
        automaticSource: PlayerSourceDescriptor? = nil
    ) {
        if let playbackID, playbackID != playback.id {
            return
        }

        if playbackID == nil {
            playbackID = playback.id
        }

        let baseSource = automaticSource
            ?? cachedSources[QualityOption.automaticID]
            ?? Self.resolveInitialSource(for: playback)

        guard let baseSource else { return }
        cachedSources[QualityOption.automaticID] = baseSource

        for option in options {
            if let resolvedSource = Self.resolveSource(
                for: option,
                playback: playback,
                automaticSource: baseSource
            ) {
                cachedSources[option.id] = resolvedSource
            }
        }
    }

    func source(
        for option: QualityOption,
        playback: VideoPlayback,
        automaticSource: PlayerSourceDescriptor
    ) -> PlayerSourceDescriptor {
        if playbackID != playback.id || cachedSources[QualityOption.automaticID] == nil {
            prime(playback: playback, automaticSource: automaticSource, options: [])
        }

        if let cachedSource = cachedSources[option.id] {
            return cachedSource
        }

        let resolvedSource = Self.resolveSource(
            for: option,
            playback: playback,
            automaticSource: cachedSources[QualityOption.automaticID] ?? automaticSource
        ) ?? automaticSource
        cachedSources[option.id] = resolvedSource
        return resolvedSource
    }

    private static func resolveInitialSource(for playback: VideoPlayback) -> PlayerSourceDescriptor? {
        automaticStartupSource(for: playback)
    }

    private static func resolveSource(
        for option: QualityOption,
        playback: VideoPlayback,
        automaticSource: PlayerSourceDescriptor
    ) -> PlayerSourceDescriptor? {
        switch option.selection {
        case .automatic:
            return automaticSource
        case .manifestVariant:
            return playback.preferredManifestStream.map(PlayerSourceDescriptor.manifestAutomatic)
        case .manual(let selection):
            guard selection.backend == .avFoundation else {
                return nil
            }

            if let audioStream = selection.audioStream {
                return .adaptivePair(video: selection.stream, audio: audioStream)
            }

            return .direct(selection.stream)
        }
    }

    private static func bestAdaptiveAudioStream(for playback: VideoPlayback) -> StreamInfo? {
        if let preferredAudioStream = playback.preferredAudioStream {
            return preferredAudioStream
        }

        return playback.streams
            .filter {
                $0.hasAudio
                    && !$0.hasVideo
                    && ($0.container?.hasPrefix("m4a") == true || $0.container?.hasPrefix("mp4") == true)
            }
            .sorted { lhs, rhs in
                let lhsScore = adaptiveAudioPreference(for: lhs)
                let rhsScore = adaptiveAudioPreference(for: rhs)
                return lhsScore > rhsScore
            }
            .first
    }
}

@MainActor
final class PlayerPlaybackCoordinator: NSObject, ObservableObject {
    private enum Timing {
        static let inactivityHideDelay: TimeInterval = 2.0
        static let hideMonitorInterval: UInt64 = 150_000_000
        static let interactionThrottle: TimeInterval = 0.16
        static let visibilityAnimationDuration = 0.10
    }

    private enum HideMonitorResult {
        case keepWatching
        case hide
        case stop
    }

    @Published private(set) var player: AVPlayer? = nil
    @Published private(set) var activeRenderState: PlayerRenderState? = nil
    @Published private(set) var pendingRenderState: PlayerRenderState? = nil
    @Published private(set) var activeBackendKind: PlaybackBackendKind = .avFoundation
    @Published private(set) var isPreparingInitialPlayback = false
    @Published private(set) var errorMessage: String? = nil
    @Published private(set) var isPlaying = false
    @Published private(set) var controlsVisible = true
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var scrubPosition: Double = 0
    @Published private(set) var qualityOptions: [QualityOption] = [QualityOption.automatic]
    @Published private(set) var selectedQualityOptionID = QualityOption.automaticID
    @Published private(set) var pendingQualityOptionID: String? = nil
    @Published private(set) var subtitleOptions: [SubtitleOption] = []
    @Published private(set) var selectedSubtitleOptionID = SubtitleOption.offID
    @Published var volume: Double = 0.9 {
        didSet {
            applyVolume()
        }
    }

    private let layoutState: PlayerLayoutState
    private let qualityCoordinator = QualityCoordinator()
    private var lastNonZeroVolume = 0.9
    private var isScrubbing = false
    private var isMenuInteractionActive = false
    private var isHoveringStage = false
    private var currentPlayback: VideoPlayback? = nil
    private var currentSource: PlayerSourceDescriptor? = nil
    private var activeMPVEngine: MPVPlaybackEngine? = nil
    private var pendingMPVEngine: MPVPlaybackEngine? = nil
    private var pendingNativeEngine: AVFoundationPlaybackEngine? = nil
    private weak var window: NSWindow?
    private var legibleGroup: AVMediaSelectionGroup?
    private var legibleMediaOptions: [AVMediaSelectionOption] = []
    private var prepareTask: Task<Void, Never>? = nil
    private var hideControlsTask: Task<Void, Never>? = nil
    private var menuInteractionTask: Task<Void, Never>? = nil
    private var timeObserverToken: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var currentItemStatusObservation: NSKeyValueObservation?
    private var currentItemLikelyToKeepUpObservation: NSKeyValueObservation?
    private var currentItemBufferEmptyObservation: NSKeyValueObservation?
    private var currentItemLoadedTimeRangesObservation: NSKeyValueObservation?
    private var currentItemStatus: AVPlayerItem.Status = .unknown
    private var isCurrentItemLikelyToKeepUp = false
    private var isCurrentItemBufferEmpty = true
    private var currentLoadedBufferDuration: Double = 0
    private var mpvStateTask: Task<Void, Never>? = nil
    private var geometryAssertionTask: Task<Void, Never>? = nil
    private var lastInteractionAt = Date()
    private var lastPointerMovementAt = Date.distantPast

    init(layoutState: PlayerLayoutState = PlayerLayoutState()) {
        self.layoutState = layoutState
        super.init()
    }

    var playbackBadgeText: String {
        if selectedQualityOptionID == QualityOption.automaticID {
            return "Auto"
        }
        return activeQualityOption?.title ?? "Quality"
    }

    var qualityControlText: String {
        if qualityControlSelectionID == QualityOption.automaticID {
            return "Auto"
        }
        return displayedQualityOption?.title ?? "Quality"
    }

    var isSwitchingQuality: Bool {
        pendingQualityOptionID != nil
    }

    var usesCompatibilityPlayback: Bool {
        activeBackendKind == .mpv
    }

    var qualityControlDetail: String? {
        guard qualityControlSelectionID != QualityOption.automaticID else {
            return nil
        }
        return displayedQualityOption?.detail
    }

    var qualityControlSelectionID: String {
        pendingQualityOptionID ?? selectedQualityOptionID
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
        layoutState.isFullscreen
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
    }

    var theaterSymbolName: String {
        layoutState.isTheaterMode
            ? "rectangle.compress.vertical"
            : "rectangle.expand.vertical"
    }

    var isTheaterMode: Bool {
        layoutState.isTheaterMode
    }

    var isFullscreen: Bool {
        layoutState.isFullscreen
    }

    var shouldShowPlaybackLoadingOverlay: Bool {
        if activeBackendKind == .mpv {
            return isPreparingInitialPlayback || (activeMPVEngine == nil && pendingQualityOptionID == nil)
        }

        guard let player, player.currentItem != nil else {
            return true
        }

        if currentItemStatus != .readyToPlay {
            return true
        }

        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            return isCurrentItemBufferEmpty || !isCurrentItemLikelyToKeepUp || currentLoadedBufferDuration < 0.15
        }

        return false
    }

    var playbackLoadingText: String {
        if currentItemStatus != .readyToPlay {
            return isSwitchingQuality ? "Switching quality..." : "Loading video..."
        }

        if isSwitchingQuality {
            return "Switching quality..."
        }

        if isPreparingInitialPlayback {
            return "Loading video..."
        }

        return "Buffering..."
    }

    var shouldShowPlaybackErrorOverlay: Bool {
        errorMessage != nil && (player == nil || currentItemStatus == .failed)
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
        activeBackendKind == .avFoundation && !subtitleOptions.isEmpty
    }

    func configure(with playback: VideoPlayback) {
        prepareTask?.cancel()
        prepareTask = Task { [weak self] in
            await self?.preparePlayback(playback)
        }
    }

    func reset() {
        prepareTask?.cancel()
        stopHideMonitor()
        menuInteractionTask?.cancel()
        geometryAssertionTask?.cancel()
        mpvStateTask?.cancel()
        errorMessage = nil
        isPreparingInitialPlayback = false
        controlsVisible = true
        isPlaying = false
        currentTime = 0
        duration = 0
        scrubPosition = 0
        qualityOptions = [QualityOption.automatic]
        selectedQualityOptionID = QualityOption.automaticID
        pendingQualityOptionID = nil
        subtitleOptions = []
        selectedSubtitleOptionID = SubtitleOption.offID
        legibleGroup = nil
        legibleMediaOptions = []
        currentSource = nil
        currentPlayback = nil
        currentItemStatus = .unknown
        isCurrentItemLikelyToKeepUp = false
        isCurrentItemBufferEmpty = true
        currentLoadedBufferDuration = 0
        activeBackendKind = .avFoundation
        activeRenderState = nil
        pendingRenderState = nil
        layoutState.isTheaterMode = false
        lastInteractionAt = Date()
        lastPointerMovementAt = .distantPast
        teardownPlayerObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        activeMPVEngine?.stop()
        activeMPVEngine = nil
        pendingMPVEngine?.stop()
        pendingMPVEngine = nil
        pendingNativeEngine?.stop()
        pendingNativeEngine = nil
        Task {
            await qualityCoordinator.reset()
        }
    }

    func stop() {
        reset()
    }

    func setWindow(_ window: NSWindow?) {
        if self.window === window {
            layoutState.isFullscreen = window?.styleMask.contains(.fullScreen) == true
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
        layoutState.isFullscreen = window?.styleMask.contains(.fullScreen) == true

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
        if let activeMPVEngine {
            if isPlaying {
                activeMPVEngine.pause()
                isPlaying = false
            } else {
                activeMPVEngine.play()
                isPlaying = true
            }
            return
        }

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
            stopHideMonitor()
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
        guard activeBackendKind == .avFoundation else { return }
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
        if isHoveringStage {
            startHideMonitorIfNeeded()
        } else {
            hideControlsIfAllowed()
        }
    }

    func selectQuality(_ option: QualityOption) {
        guard let playback = currentPlayback else { return }
        guard option.id != qualityControlSelectionID else {
            endMenuInteraction()
            return
        }

        noteInteraction()
        let previousSelectionID = selectedQualityOptionID
        pendingQualityOptionID = option.id

        if applyManifestQualitySelectionIfPossible(option) {
            pendingQualityOptionID = nil
            endMenuInteraction()
            return
        }

        let subtitleSnapshot = currentSubtitleSnapshot()
        prepareTask?.cancel()
        prepareTask = Task { [weak self] in
            await self?.switchQuality(
                to: option,
                playback: playback,
                previousSelectionID: previousSelectionID,
                subtitleSnapshot: subtitleSnapshot
            )
        }
    }

    func setHovering(_ isHovering: Bool) {
        isHoveringStage = isHovering

        if isHovering {
            noteInteraction()
        } else {
            lastPointerMovementAt = .distantPast
            hideControlsIfAllowed()
        }
    }

    func handlePointerMovement() {
        guard isHoveringStage else { return }

        let now = Date()
        if controlsVisible == false {
            lastPointerMovementAt = now
            noteInteraction(at: now)
            return
        }

        guard now.timeIntervalSince(lastPointerMovementAt) >= Timing.interactionThrottle else {
            return
        }

        lastPointerMovementAt = now
        noteInteraction(at: now, animateVisibility: false)
    }

    func toggleTheaterMode() {
        let wasPlaying = isPlaying
        withAnimation(.snappy(duration: 0.16, extraBounce: 0)) {
            layoutState.isTheaterMode.toggle()
        }
        noteInteraction()
        scheduleGeometryRateAssertion(wasPlaying: wasPlaying)
    }

    func toggleFullscreen() {
        noteInteraction()
        window?.toggleFullScreen(nil)
    }

    private var activeQualityOption: QualityOption? {
        qualityOptions.first(where: { $0.id == selectedQualityOptionID })
    }

    private var displayedQualityOption: QualityOption? {
        qualityOptions.first(where: { $0.id == qualityControlSelectionID })
    }

    private var currentSubtitleOption: SubtitleOption? {
        if selectedSubtitleOptionID == SubtitleOption.offID {
            return .off
        }
        return subtitleOptions.first(where: { $0.id == selectedSubtitleOptionID })
    }

    private func preparePlayback(_ playback: VideoPlayback) async {
        errorMessage = nil
        isPreparingInitialPlayback = true
        pendingQualityOptionID = nil
        controlsVisible = true
        currentItemStatus = .unknown
        isCurrentItemLikelyToKeepUp = false
        isCurrentItemBufferEmpty = true
        currentLoadedBufferDuration = 0

        do {
            let source = try await preferredSource(for: playback)
            let item = try await buildPlayerItem(for: source)
            guard !Task.isCancelled else { return }

            currentPlayback = playback
            currentSource = source
            selectedQualityOptionID = QualityOption.automaticID
            activeBackendKind = .avFoundation
            activeMPVEngine?.stop()
            activeMPVEngine = nil
            pendingMPVEngine?.stop()
            pendingMPVEngine = nil
            pendingNativeEngine = nil
            pendingRenderState = nil
            mpvStateTask?.cancel()

            let player = ensurePlayer()
            observeCurrentItem(item)
            player.replaceCurrentItem(with: item)
            clearManifestQualityPreferences(on: item)
            activeRenderState = .avFoundation(player)

            async let metadataRefresh: Void = refreshPlaybackMetadata(
                for: item,
                playback: playback,
                preferredSubtitle: nil
            )

            guard !Task.isCancelled else { return }
            currentTime = 0
            scrubPosition = 0
            try await waitUntilReadyToPlay(item)
            guard !Task.isCancelled else { return }
            player.play()
            startHideMonitorIfNeeded()
            await metadataRefresh
            await qualityCoordinator.prime(
                playback: playback,
                automaticSource: source,
                options: qualityOptions
            )
        } catch {
            if !Task.isCancelled {
                errorMessage = "Failed to prepare video."
                player?.pause()
            }
        }

        if !Task.isCancelled {
            isPreparingInitialPlayback = false
        }
    }

    private func switchQuality(
        to option: QualityOption,
        playback: VideoPlayback,
        previousSelectionID: String,
        subtitleSnapshot: SubtitleSelectionSnapshot?
    ) async {
        errorMessage = nil

        do {
            switch option.selection {
            case .manual(let manualSelection) where manualSelection.backend == .mpv:
                try await switchToMPVQuality(
                    option: option,
                    selection: manualSelection,
                    playback: playback
                )
            default:
                try await switchToNativeQuality(
                    option: option,
                    playback: playback,
                    subtitleSnapshot: subtitleSnapshot
                )
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = "Failed to switch quality."
                selectedQualityOptionID = previousSelectionID
                pendingQualityOptionID = nil
            }
        }

        if !Task.isCancelled {
            pendingQualityOptionID = nil
            endMenuInteraction()
        }
    }

    private func switchToNativeQuality(
        option: QualityOption,
        playback: VideoPlayback,
        subtitleSnapshot: SubtitleSelectionSnapshot?
    ) async throws {
        let automaticSource = try await preferredSource(for: playback)
        let source = await qualityCoordinator.source(
            for: option,
            playback: playback,
            automaticSource: automaticSource
        )
        let item = try await buildPlayerItem(for: source)
        let engine = AVFoundationPlaybackEngine(item: item, volume: volume)
        pendingNativeEngine = engine
        pendingRenderState = .avFoundation(engine.player)

        try await engine.prepare(startTime: 0, autoPlay: false)
        let restoreState = currentRestoreState()
        let clampedTime = max(restoreState.currentTime, 0)
        await engine.seek(to: clampedTime)

        async let metadataRefresh: Void = refreshPlaybackMetadata(
            for: item,
            playback: playback,
            preferredSubtitle: subtitleSnapshot
        )

        if restoreState.wasPlaying {
            engine.play()
        } else {
            engine.pause()
        }

        let previousPlayer = player
        mpvStateTask?.cancel()
        activeMPVEngine?.stop()
        activeMPVEngine = nil
        pendingMPVEngine?.stop()
        pendingMPVEngine = nil

        teardownPlayerObservers()
        previousPlayer?.pause()

        player = engine.player
        setupPlayerObservers(for: engine.player)
        observeCurrentItem(item)
        clearManifestQualityPreferences(on: item)
        currentSource = source
        activeBackendKind = .avFoundation
        activeRenderState = .avFoundation(engine.player)
        pendingRenderState = nil
        pendingNativeEngine = nil

        selectedQualityOptionID = option.id
        currentTime = clampedTime
        scrubPosition = clampedTime
        pendingQualityOptionID = nil
        await metadataRefresh

        if isHoveringStage {
            startHideMonitorIfNeeded()
        } else {
            hideControlsIfAllowed()
        }
        endMenuInteraction()
    }

    private func switchToMPVQuality(
        option: QualityOption,
        selection: ManualPlaybackSelection,
        playback: VideoPlayback
    ) async throws {
        let request = try mpvRequest(for: selection)
        let engine = MPVPlaybackEngine(request: request)
        pendingMPVEngine = engine
        pendingRenderState = .mpv(engine)

        try await engine.prepare(startTime: 0, autoPlay: false)
        let restoreState = currentRestoreState()
        let clampedTime = max(restoreState.currentTime, 0)
        await engine.seek(to: clampedTime)
        engine.setVolume(volume)

        if restoreState.wasPlaying {
            engine.play()
        } else {
            engine.pause()
        }

        let previousPlayer = player
        teardownPlayerObservers()
        previousPlayer?.pause()
        player = nil
        currentItemStatus = .readyToPlay
        isCurrentItemLikelyToKeepUp = true
        isCurrentItemBufferEmpty = false
        currentLoadedBufferDuration = 1
        subtitleOptions = []
        selectedSubtitleOptionID = SubtitleOption.offID

        activeMPVEngine?.stop()
        activeMPVEngine = engine
        pendingNativeEngine?.stop()
        pendingNativeEngine = nil
        pendingMPVEngine = nil
        activeBackendKind = .mpv
        activeRenderState = .mpv(engine)
        pendingRenderState = nil
        currentSource = nil

        selectedQualityOptionID = option.id
        currentTime = clampedTime
        scrubPosition = clampedTime
        pendingQualityOptionID = nil
        startPollingMPVState(using: engine)
        await refreshQualityOptions(for: playback)

        if isHoveringStage {
            startHideMonitorIfNeeded()
        } else {
            hideControlsIfAllowed()
        }
        endMenuInteraction()
    }

    private func refreshPlaybackMetadata(
        for item: AVPlayerItem,
        playback: VideoPlayback,
        preferredSubtitle: SubtitleSelectionSnapshot?
    ) async {
        async let durationRefresh: Void = refreshDuration(using: item)
        async let qualityRefresh: Void = refreshQualityOptions(for: playback)
        async let subtitleRefresh: Void = refreshSubtitleOptionsSafely(
            for: item,
            preferredSelection: preferredSubtitle
        )
        _ = await (durationRefresh, qualityRefresh, subtitleRefresh)
    }

    private func refreshDuration(using item: AVPlayerItem) async {
        guard let assetDuration = try? await item.asset.load(.duration) else {
            return
        }

        duration = sanitizeSeconds(assetDuration.seconds)
        scrubPosition = currentTime
    }

    private func refreshQualityOptions(for playback: VideoPlayback) async {
        var manifestOptions: [QualityOption] = []

        switch currentSource {
        case .manifestAutomatic(let manifestStream), .manifestVariant(parent: let manifestStream, url: _):
            if let manifestAsset = buildAsset(for: manifestStream) {
                let variants = try? await manifestAsset.load(.variants)
                manifestOptions = buildManifestQualityOptions(from: variants ?? [])
            }
        case .direct, .adaptivePair, .none:
            break
        }

        let directOptions = buildFallbackQualityOptions(for: playback)
        let resolvedManualOptions = directOptions.isEmpty ? manifestOptions : directOptions

        qualityOptions = [QualityOption.automatic] + resolvedManualOptions
        if qualityOptions.contains(where: { $0.id == selectedQualityOptionID }) == false {
            selectedQualityOptionID = QualityOption.automaticID
        }
        if let pendingQualityOptionID,
           qualityOptions.contains(where: { $0.id == pendingQualityOptionID }) == false {
            self.pendingQualityOptionID = nil
        }
        await qualityCoordinator.cache(
            options: qualityOptions,
            for: playback,
            automaticSource: currentSource
        )
    }

    private func refreshSubtitleOptionsSafely(
        for item: AVPlayerItem,
        preferredSelection: SubtitleSelectionSnapshot?
    ) async {
        do {
            try await refreshSubtitleOptions(for: item, preferredSelection: preferredSelection)
        } catch {
            legibleGroup = nil
            legibleMediaOptions = []
            subtitleOptions = []
            selectedSubtitleOptionID = SubtitleOption.offID
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
        player.automaticallyWaitsToMinimizeStalling = false
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
            DispatchQueue.main.async {
                self?.handlePeriodicTimeUpdate(time)
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) {
            [weak self] observedPlayer, _ in
            DispatchQueue.main.async {
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
        teardownCurrentItemObservers()

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
        startHideMonitorIfNeeded()
    }

    @objc private func handleWindowDidEnterFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        let wasPlaying = isPlaying
        withAnimation(.snappy(duration: 0.16, extraBounce: 0)) {
            layoutState.isFullscreen = true
        }
        scheduleGeometryRateAssertion(wasPlaying: wasPlaying)
    }

    @objc private func handleWindowDidExitFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        let wasPlaying = isPlaying
        withAnimation(.snappy(duration: 0.16, extraBounce: 0)) {
            layoutState.isFullscreen = false
        }
        scheduleGeometryRateAssertion(wasPlaying: wasPlaying)
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
        guard activeBackendKind == .avFoundation else { return }
        isPlaying = status == .playing
        guard player != nil else {
            stopHideMonitor()
            controlsVisible = true
            return
        }

        startHideMonitorIfNeeded()

        if isHoveringStage == false {
            hideControlsIfAllowed()
        }
    }

    func handlePlayerGeometryChange() {
        scheduleGeometryRateAssertion(wasPlaying: isPlaying)
    }

    private func observeCurrentItem(_ item: AVPlayerItem) {
        teardownCurrentItemObservers()
        updateCurrentItemState(from: item)

        currentItemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                self?.updateCurrentItemState(from: observedItem)
            }
        }

        currentItemLikelyToKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) {
            [weak self] observedItem, _ in
            DispatchQueue.main.async {
                self?.updateCurrentItemState(from: observedItem)
            }
        }

        currentItemBufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.initial, .new]) {
            [weak self] observedItem, _ in
            DispatchQueue.main.async {
                self?.updateCurrentItemState(from: observedItem)
            }
        }

        currentItemLoadedTimeRangesObservation = item.observe(\.loadedTimeRanges, options: [.initial, .new]) {
            [weak self] observedItem, _ in
            DispatchQueue.main.async {
                self?.updateCurrentItemState(from: observedItem)
            }
        }
    }

    private func teardownCurrentItemObservers() {
        currentItemStatusObservation = nil
        currentItemLikelyToKeepUpObservation = nil
        currentItemBufferEmptyObservation = nil
        currentItemLoadedTimeRangesObservation = nil
        currentItemStatus = .unknown
        isCurrentItemLikelyToKeepUp = false
        isCurrentItemBufferEmpty = true
        currentLoadedBufferDuration = 0
    }

    private func updateCurrentItemState(from item: AVPlayerItem) {
        currentItemStatus = item.status
        isCurrentItemLikelyToKeepUp = item.isPlaybackLikelyToKeepUp
        isCurrentItemBufferEmpty = item.isPlaybackBufferEmpty
        currentLoadedBufferDuration = loadedBufferDuration(for: item)

        if item.status == .failed {
            errorMessage = item.error?.localizedDescription ?? "Failed to prepare video."
        }
    }

    private func loadedBufferDuration(for item: AVPlayerItem) -> Double {
        let currentSeconds = sanitizeSeconds(item.currentTime().seconds)

        return item.loadedTimeRanges
            .compactMap { value in
                let range = value.timeRangeValue
                let start = range.start.seconds
                let end = start + range.duration.seconds
                guard end > currentSeconds else { return nil }
                return sanitizeSeconds(end - currentSeconds)
            }
            .max() ?? 0
    }

    private func waitUntilReadyToPlay(_ item: AVPlayerItem) async throws {
        switch item.status {
        case .readyToPlay:
            return
        case .failed:
            throw item.error ?? URLError(.cannotDecodeContentData)
        case .unknown:
            break
        @unknown default:
            break
        }

        final class ReadyObservationBox: @unchecked Sendable {
            var observation: NSKeyValueObservation?
            var didResume = false
        }

        let box = ReadyObservationBox()

        try await withCheckedThrowingContinuation { continuation in
            box.observation = item.observe(\.status, options: [.initial, .new]) { observedItem, _ in
                guard !box.didResume else { return }

                switch observedItem.status {
                case .readyToPlay:
                    box.didResume = true
                    box.observation?.invalidate()
                    box.observation = nil
                    continuation.resume(returning: ())
                case .failed:
                    box.didResume = true
                    box.observation?.invalidate()
                    box.observation = nil
                    continuation.resume(throwing: observedItem.error ?? URLError(.cannotDecodeContentData))
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func clearManifestQualityPreferences(on item: AVPlayerItem) {
        item.preferredPeakBitRate = 0
        item.preferredMaximumResolution = .zero
    }

    private func applyManifestQualitySelectionIfPossible(_ option: QualityOption) -> Bool {
        guard isManifestSource(currentSource),
              let currentItem = player?.currentItem else {
            return false
        }

        switch option.selection {
        case .automatic:
            clearManifestQualityPreferences(on: currentItem)
        case .manifestVariant(_, let peakBitRate, let width, let height):
            currentItem.preferredPeakBitRate = peakBitRate
            if width > 0 || height > 0 {
                currentItem.preferredMaximumResolution = CGSize(width: width, height: height)
            } else {
                currentItem.preferredMaximumResolution = .zero
            }
        case .manual:
            return false
        }

        selectedQualityOptionID = option.id
        pendingQualityOptionID = nil
        return true
    }

    private func isManifestSource(_ source: PlayerSourceDescriptor?) -> Bool {
        switch source {
        case .manifestAutomatic, .manifestVariant:
            return true
        case .direct, .adaptivePair, .none:
            return false
        }
    }

    private func scheduleGeometryRateAssertion(wasPlaying: Bool) {
        guard wasPlaying else { return }

        geometryAssertionTask?.cancel()
        geometryAssertionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.activeBackendKind == .avFoundation, let player = self.player else { return }

            let isAtEnd = self.duration > 0 && self.currentTime >= self.duration - 0.25

            #if DEBUG
            assert(
                player.rate > 0
                    || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    || self.isPreparingInitialPlayback
                    || self.isSwitchingQuality
                    || isAtEnd,
                "AVPlayer unexpectedly stopped during a geometry change."
            )
            #endif
        }
    }

    private func startHideMonitorIfNeeded() {
        guard player != nil || activeMPVEngine != nil else { return }
        guard hideControlsTask == nil else { return }

        hideControlsTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.hideControlsTask = nil
                }
            }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Timing.hideMonitorInterval)
                guard !Task.isCancelled else { return }

                let result = await MainActor.run { [weak self] () -> HideMonitorResult in
                    guard let self else { return .stop }
                    guard self.player != nil || self.activeMPVEngine != nil else { return .stop }

                    if self.isPreparingInitialPlayback {
                        return .keepWatching
                    }

                    if self.isScrubbing || self.isMenuInteractionActive {
                        return .keepWatching
                    }

                    guard self.isHoveringStage else {
                        return .hide
                    }

                    let idleTime = Date().timeIntervalSince(self.lastInteractionAt)
                    return idleTime >= Timing.inactivityHideDelay ? .hide : .keepWatching
                }

                switch result {
                case .keepWatching:
                    continue
                case .hide:
                    await MainActor.run { [weak self] in
                        self?.hideControlsIfAllowed()
                    }
                    return
                case .stop:
                    return
                }
            }
        }
    }

    private func noteInteraction(
        at timestamp: Date = Date(),
        animateVisibility: Bool = true
    ) {
        lastInteractionAt = timestamp

        if controlsVisible == false {
            if animateVisibility {
                withAnimation(.easeOut(duration: Timing.visibilityAnimationDuration)) {
                    controlsVisible = true
                }
            } else {
                controlsVisible = true
            }
        } else {
            controlsVisible = true
        }

        startHideMonitorIfNeeded()
    }

    private func hideControlsIfAllowed() {
        stopHideMonitor()
        guard player != nil || activeMPVEngine != nil else { return }
        guard !isPreparingInitialPlayback, !isScrubbing, !isMenuInteractionActive else { return }
        guard controlsVisible else { return }

        withAnimation(.easeOut(duration: Timing.visibilityAnimationDuration)) {
            controlsVisible = false
        }
    }

    private func stopHideMonitor() {
        let activeTask = hideControlsTask
        hideControlsTask = nil
        activeTask?.cancel()
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
        if let activeMPVEngine {
            activeMPVEngine.setVolume(clampedVolume)
        } else {
            player?.volume = Float(clampedVolume)
        }
    }

    private func currentRestoreState() -> PlaybackRestoreState {
        if activeBackendKind == .mpv {
            return PlaybackRestoreState(
                currentTime: sanitizeSeconds(currentTime),
                wasPlaying: isPlaying
            )
        }

        return PlaybackRestoreState(
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
        Task { [weak self] in
            guard let self else { return }
            let target = min(scrubPosition, scrubberUpperBound)
            if let activeMPVEngine {
                await activeMPVEngine.seek(to: target)
                syncMPVState(using: activeMPVEngine)
            } else if let player {
                await seek(player: player, to: target)
            } else {
                return
            }
            currentTime = target
            scrubPosition = target
            if isHoveringStage {
                startHideMonitorIfNeeded()
            } else {
                hideControlsIfAllowed()
            }
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

    private func startPollingMPVState(using engine: MPVPlaybackEngine) {
        mpvStateTask?.cancel()
        syncMPVState(using: engine)
        mpvStateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.activeMPVEngine === engine else { return }
                self.syncMPVState(using: engine)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func syncMPVState(using engine: MPVPlaybackEngine) {
        let snapshot = engine.snapshot()
        currentTime = sanitizeSeconds(snapshot.currentTime)
        if !isScrubbing {
            scrubPosition = currentTime
        }
        if snapshot.duration > 0 {
            duration = sanitizeSeconds(snapshot.duration)
        }
        isPlaying = snapshot.isPlaying
        isCurrentItemBufferEmpty = snapshot.isBuffering
        isCurrentItemLikelyToKeepUp = !snapshot.isBuffering
        currentLoadedBufferDuration = snapshot.isBuffering ? 0 : 1
    }

    private func mpvRequest(for selection: ManualPlaybackSelection) throws -> MPVPlaybackRequest {
        guard let videoURL = URL(string: selection.stream.url) else {
            throw URLError(.badURL)
        }

        let audioRequest: MediaStreamRequest?
        if let audioStream = selection.audioStream {
            guard let audioURL = URL(string: audioStream.url) else {
                throw URLError(.badURL)
            }
            audioRequest = MediaStreamRequest(url: audioURL, headers: audioStream.httpHeaders)
        } else {
            audioRequest = nil
        }

        return MPVPlaybackRequest(
            video: MediaStreamRequest(url: videoURL, headers: selection.stream.httpHeaders),
            audio: audioRequest
        )
    }

    private func source(for option: QualityOption, playback: VideoPlayback) async throws -> PlayerSourceDescriptor {
        switch option.selection {
        case .automatic:
            return try await preferredSource(for: playback)
        case .manifestVariant:
            guard let manifestStream = playback.preferredManifestStream else {
                throw URLError(.badURL)
            }
            return .manifestAutomatic(manifestStream)
        case .manual(let selection):
            guard selection.backend == .avFoundation else {
                throw URLError(.unsupportedURL)
            }
            if let audioStream = selection.audioStream {
                return .adaptivePair(video: selection.stream, audio: audioStream)
            }
            return .direct(selection.stream)
        }
    }

    private func preferredSource(for playback: VideoPlayback) async throws -> PlayerSourceDescriptor {
        if let resolvedSource = resolvedInitialSource(for: playback) {
            return resolvedSource
        }

        throw URLError(.badURL)
    }

    private func resolvedInitialSource(for playback: VideoPlayback) -> PlayerSourceDescriptor? {
        automaticStartupSource(for: playback)
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
            item.preferredForwardBufferDuration = 2
            return item
        case .manifestVariant(let parent, let url):
            let asset = buildAsset(url: url, headers: parent.httpHeaders)
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 2
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

        let videoTimeRange = try await videoTrack.load(.timeRange)
        let audioTimeRange = try await audioTrack.load(.timeRange)
        let videoDuration = videoTimeRange.duration
        let audioDuration = audioTimeRange.duration
        let duration = minimumDuration(videoDuration, audioDuration)
        let composition = AVMutableComposition()

        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw URLError(.cannotCreateFile)
        }

        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: videoTimeRange.start, duration: duration),
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
            CMTimeRange(start: audioTimeRange.start, duration: duration),
            of: audioTrack,
            at: .zero
        )

        let item = AVPlayerItem(asset: composition)
        item.preferredForwardBufferDuration = 2
        item.forwardPlaybackEndTime = duration
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
        var groupedCandidates: [String: ManualQualityCandidate] = [:]

        for stream in playback.streams {
            guard let candidate = manualQualityCandidate(for: stream, playback: playback) else {
                continue
            }

            let title = qualityTitle(
                height: Double(stream.height ?? 0),
                width: Double(stream.width ?? 0),
                bitrate: Double(stream.bitrate ?? 0),
                fps: stream.fps
            )

            if let existing = groupedCandidates[title] {
                if manualQualityCandidateSort(lhs: candidate, rhs: existing) {
                    groupedCandidates[title] = candidate
                }
            } else {
                groupedCandidates[title] = candidate
            }
        }

        return groupedCandidates
            .map { title, candidate in
                QualityOption(
                    id: "stream-\(candidate.selection.stream.url)",
                    title: title,
                    detail: bitrateText(Double(candidate.bitrate)),
                    selection: .manual(candidate.selection)
                )
            }
            .sorted { lhs, rhs in
                let lhsHeight = lhs.selection.streamHeight
                let rhsHeight = rhs.selection.streamHeight
                let lhsFPS = lhs.selection.streamFPS
                let rhsFPS = rhs.selection.streamFPS
                let lhsBitrate = lhs.selection.streamBitrate
                let rhsBitrate = rhs.selection.streamBitrate
                return (lhsHeight, lhsFPS, lhsBitrate) > (rhsHeight, rhsFPS, rhsBitrate)
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
        preferredAdaptiveAudioStream(for: playback)
    }

    private func adaptiveVideoCandidateSort(lhs: StreamInfo, rhs: StreamInfo) -> Bool {
        let lhsScore = (
            videoPlayabilityScore(for: lhs.videoCodec),
            lhs.height ?? 0,
            lhs.fps ?? 0,
            lhs.bitrate ?? 0,
            codecScore(for: lhs.videoCodec)
        )
        let rhsScore = (
            videoPlayabilityScore(for: rhs.videoCodec),
            rhs.height ?? 0,
            rhs.fps ?? 0,
            rhs.bitrate ?? 0,
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

    private func manualQualityCandidateSort(lhs: ManualQualityCandidate, rhs: ManualQualityCandidate) -> Bool {
        let lhsCapability = lhs.capability == .native ? 2 : 1
        let rhsCapability = rhs.capability == .native ? 2 : 1
        let lhsCodecPreference = compatibilityCodecPreference(for: lhs.selection.stream.videoCodec)
        let rhsCodecPreference = compatibilityCodecPreference(for: rhs.selection.stream.videoCodec)

        let lhsScore = (
            lhsCapability,
            lhs.selection.stream.height ?? 0,
            lhs.selection.stream.fps ?? 0,
            lhsCodecPreference,
            lhs.bitrate
        )
        let rhsScore = (
            rhsCapability,
            rhs.selection.stream.height ?? 0,
            rhs.selection.stream.fps ?? 0,
            rhsCodecPreference,
            rhs.bitrate
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
        if codec.hasPrefix("av01") { return AVFoundationPlaybackSupport.supportsAV1 ? 2 : 0 }
        if codec.hasPrefix("vp9") { return 0 }
        return 0
    }

    private func codecScore(for codec: String?) -> Int {
        playbackCodecScore(for: codec)
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

    private func qualityTitle(
        height: Double,
        width: Double,
        bitrate: Double,
        fps: Int? = nil
    ) -> String {
        if height > 0 {
            let label = "\(Int(height.rounded()))p"
            if let fps, fps >= 50 {
                return "\(label)60"
            }
            return label
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
