import AppKit
import SwiftUI

struct ManualPlaybackSelection: Hashable, Sendable {
    let stream: StreamInfo
    let audioStream: StreamInfo?
}

struct QualityOption: Identifiable, Hashable, Sendable {
    static let automaticID = "quality-auto"

    enum Selection: Hashable, Sendable {
        case automatic
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
        case .automatic:
            return 0
        }
    }

    var streamFPS: Int {
        switch self {
        case .manual(let selection):
            return selection.stream.fps ?? 0
        case .automatic:
            return 0
        }
    }

    var streamBitrate: Int {
        switch self {
        case .manual(let selection):
            return selection.stream.bitrate ?? 0
        case .automatic:
            return 0
        }
    }
}

struct SubtitleOption: Identifiable, Hashable, Sendable {
    static let offID = "subtitle-off"

    let id: String
    let title: String
    let url: String?
    let mpvTrackIndex: Int?

    var isOff: Bool { url == nil }

    static let off = SubtitleOption(
        id: offID,
        title: "Off",
        url: nil,
        mpvTrackIndex: nil
    )
}

struct PlaybackSpeedOption: Identifiable, Hashable, Sendable {
    let speed: Double

    var id: Double { speed }
    var title: String { AppSettings.playbackSpeedLabel(speed) }
}

enum ActionFeedback: Equatable {
    case play
    case pause
    case seekForward(Int)
    case seekBackward(Int)
    case frameForward
    case frameBackward
}

private struct PlaybackRestoreState: Sendable {
    let currentTime: Double
    let wasPlaying: Bool
}

private struct ManualQualityCandidate: Sendable {
    let selection: ManualPlaybackSelection
    let bitrate: Int
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

private func manualQualityAudioPreference(for stream: StreamInfo) -> (Int, Int, Int, Int) {
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

private func isMPVStartupVideoStream(_ stream: StreamInfo) -> Bool {
    stream.hasVideo
}

private func startupMPVAudioPreference(for stream: StreamInfo) -> (Int, Int, Int, Int, Int) {
    let containerPreference: Int
    switch stream.container?.lowercased() {
    case let container? where container.hasPrefix("m4a"), let container? where container.hasPrefix("mp4"):
        containerPreference = 2
    case let container? where container.hasPrefix("webm"):
        containerPreference = 1
    default:
        containerPreference = 0
    }

    return (
        containerPreference,
        manualQualityAudioPreference(for: stream).0,
        playbackCodecScore(for: stream.audioCodec),
        stream.audioChannels ?? 0,
        stream.bitrate ?? 0
    )
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

private func preferredManualQualityAudioStream(for playback: VideoPlayback) -> StreamInfo? {
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
            let lhsScore = manualQualityAudioPreference(for: lhs)
            let rhsScore = manualQualityAudioPreference(for: rhs)
            return lhsScore > rhsScore
        }
        .first
}

private func isSupportedManualQualityCodec(_ codec: String?) -> Bool {
    guard let codec else { return false }
    return codec.hasPrefix("avc1")
        || codec.hasPrefix("av01")
        || codec.hasPrefix("hvc1")
        || codec.hasPrefix("hev1")
}

private func isManualQualityVideoStream(_ stream: StreamInfo) -> Bool {
    if stream.streamKind == "manifest" {
        return stream.hasVideo && stream.hasAudio && (stream.height ?? 0) > 0
    }

    guard stream.hasVideo,
          !stream.hasAudio,
          stream.streamKind != "manifest",
          (stream.height ?? 0) > 0,
          stream.container?.lowercased().hasPrefix("mp4") == true,
          isSupportedManualQualityCodec(stream.videoCodec) else {
        return false
    }

    return true
}

private func manualQualitySortKey(for candidate: ManualQualityCandidate) -> (Int, Int, Int) {
    (
        candidate.selection.stream.height ?? 0,
        candidate.selection.stream.fps ?? 0,
        candidate.bitrate
    )
}

private func manualQualityCandidate(
    for stream: StreamInfo,
    playback: VideoPlayback
) -> ManualQualityCandidate? {
    if stream.streamKind == "manifest" {
        return ManualQualityCandidate(
            selection: ManualPlaybackSelection(
                stream: stream,
                audioStream: nil
            ),
            bitrate: stream.bitrate ?? 0
        )
    }

    guard isManualQualityVideoStream(stream),
          let audioStream = preferredManualQualityAudioStream(for: playback),
          hasConflictingHeaders(video: stream, audio: audioStream) == false else {
        return nil
    }

    return ManualQualityCandidate(
        selection: ManualPlaybackSelection(
            stream: stream,
            audioStream: audioStream
        ),
        bitrate: stream.bitrate ?? 0
    )
}

private func preferredStartupMPVAudioStream(for playback: VideoPlayback) -> StreamInfo? {
    if let preferredAudioStream = playback.preferredAudioStream {
        return preferredAudioStream
    }

    return playback.streams
        .filter {
            $0.hasAudio
                && !$0.hasVideo
        }
        .sorted { lhs, rhs in
            startupMPVAudioPreference(for: lhs) > startupMPVAudioPreference(for: rhs)
        }
        .first
}

private func automaticStartupMPVSortKey(for stream: StreamInfo) -> (Int, Int, Int, Int, Int) {
    (
        stream.height ?? 0,
        stream.hasAudio ? 1 : 0,
        stream.fps ?? 0,
        stream.bitrate ?? 0,
        playbackCodecScore(for: stream.videoCodec)
    )
}

private func liveManifestStartupSortKey(for stream: StreamInfo) -> [Int] {
    let protocolPreference = stream.container?.lowercased() == "m3u8" ? 1 : 0
    let sourcePreference: Int
    switch stream.httpHeaders?["X-YouTube-Client-Name"] {
    case "88":
        sourcePreference = 2
    case "1":
        sourcePreference = 1
    default:
        sourcePreference = 0
    }

    return [
        protocolPreference,
        sourcePreference,
        stream.height ?? 0,
        stream.hasAudio ? 1 : 0,
        stream.fps ?? 0,
        stream.bitrate ?? 0,
        playbackCodecScore(for: stream.videoCodec)
    ]
}

private func automaticStartupMPVSelection(for playback: VideoPlayback) -> ManualPlaybackSelection? {
    automaticStartupMPVSelections(for: playback).first
}

private func automaticStartupMPVSelections(for playback: VideoPlayback) -> [ManualPlaybackSelection] {
    let audioStream = preferredStartupMPVAudioStream(for: playback)
    let preferredHeight = AppSettings.shared.defaultQuality.preferredHeight

    func buildSelection(for stream: StreamInfo?) -> ManualPlaybackSelection? {
        guard let stream, isMPVStartupVideoStream(stream) else { return nil }
        if stream.streamKind == "manifest" {
            return ManualPlaybackSelection(stream: stream, audioStream: nil)
        }
        guard stream.hasAudio || (audioStream != nil && !hasConflictingHeaders(video: stream, audio: audioStream)) else {
            return nil
        }
        return ManualPlaybackSelection(stream: stream, audioStream: stream.hasAudio ? nil : audioStream)
    }

    let candidates = playback.streams
        .filter(isMPVStartupVideoStream)
        .filter { stream in
            stream.streamKind == "manifest"
                || stream.hasAudio
                || (audioStream != nil && !hasConflictingHeaders(video: stream, audio: audioStream))
        }

    var orderedSelections: [ManualPlaybackSelection] = []
    var seenSelections = Set<ManualPlaybackSelection>()

    func appendSelection(for stream: StreamInfo?) {
        guard let selection = buildSelection(for: stream) else { return }
        if seenSelections.insert(selection).inserted {
            orderedSelections.append(selection)
        }
    }

    if playback.isLive {
        appendSelection(for: playback.preferredManifestStream)

        let manifestCandidates = candidates
            .filter({ $0.streamKind == "manifest" })
            .sorted(by: { liveManifestStartupSortKey(for: $1).lexicographicallyPrecedes(liveManifestStartupSortKey(for: $0)) })
        for manifestCandidate in manifestCandidates {
            appendSelection(for: manifestCandidate)
        }
    }

    // When a quality preference is set, find the best stream at or below that height.
    if let preferredHeight {
        let atOrBelow = candidates.filter { ($0.height ?? 0) <= preferredHeight }
        if let best = atOrBelow.max(by: { automaticStartupMPVSortKey(for: $0) < automaticStartupMPVSortKey(for: $1) }) {
            appendSelection(for: best)
        }
        // Nothing at/below; fall back to the lowest stream above as a safety net.
        if let fallback = candidates.min(by: { ($0.height ?? 0) < ($1.height ?? 0) }) {
            appendSelection(for: fallback)
        }
    }

    appendSelection(for: playback.preferredVideoStream)
    appendSelection(for: playback.preferredMuxedStream)
    appendSelection(for: playback.bestStream)

    for candidate in candidates.sorted(by: { automaticStartupMPVSortKey(for: $0) > automaticStartupMPVSortKey(for: $1) }) {
        appendSelection(for: candidate)
    }

    return orderedSelections
}

@MainActor
final class PlayerLayoutState: ObservableObject {
    @Published var isTheaterMode = false
    @Published var isFullscreen = false
    @Published var isSidePanelVisible = false
}

@MainActor
final class PlayerPlaybackCoordinator: NSObject, ObservableObject {
    private enum Timing {
        static let inactivityHideDelay: TimeInterval = 2.0
        static let hideMonitorInterval: UInt64 = 150_000_000
        static let interactionThrottle: TimeInterval = 0.16
        static let visibilityAnimationDuration = 0.10
        static let spacebarHoldDelay: UInt64 = 800_000_000
    }

    private enum HideMonitorResult {
        case keepWatching
        case hide
        case stop
    }

    @Published private(set) var mpvEngine: MPVPlaybackEngine? = nil
    @Published private(set) var isPreparingInitialPlayback = false
    @Published private(set) var errorMessage: String? = nil
    @Published private(set) var isPlaying = false
    @Published private(set) var controlsVisible = true
    @Published private(set) var didReachPlaybackEnd = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var scrubPosition: Double = 0
    @Published private(set) var qualityOptions: [QualityOption] = [QualityOption.automatic]
    @Published private(set) var selectedQualityOptionID = QualityOption.automaticID
    @Published private(set) var pendingQualityOptionID: String? = nil
    @Published private(set) var subtitleOptions: [SubtitleOption] = []
    @Published private(set) var selectedSubtitleOptionID = SubtitleOption.offID
    @Published private(set) var playbackSpeedOptions = AppSettings.playbackSpeedOptions.map(PlaybackSpeedOption.init)
    @Published private(set) var selectedPlaybackSpeed = AppSettings.shared.defaultPlaybackSpeed
    @Published private(set) var effectivePlaybackSpeed = AppSettings.shared.defaultPlaybackSpeed
    @Published private(set) var actionFeedback: ActionFeedback? = nil
    @Published private(set) var feedbackGeneration = 0
    @Published var keyboardLocked = false
    @Published private(set) var isRefreshingPausedSurface = false
    @Published private(set) var videoAspect: Double = 16.0 / 9.0
    @Published private(set) var storyboard: StoryboardSpec? = nil
    @Published private(set) var sponsorSegments: [SponsorBlockSegment] = []
    @Published private(set) var manualSkipSponsorSegment: SponsorBlockSegment? = nil
    @Published private(set) var liveSeekableRange: ClosedRange<Double>? = nil
    @Published private(set) var bufferedRanges: [ClosedRange<Double>] = []
    /// Non-nil while the cursor hovers over the scrubber track (0…1 fraction of track width).
    @Published var scrubHoverFraction: Double? = nil
    @Published var volume: Double = 0.9 {
        didSet {
            applyVolume()
        }
    }

    private let layoutState: PlayerLayoutState
    private let liveEdgeThresholdSeconds = 3.0
    private let liveEdgeStickyThresholdSeconds = 8.0
    private var lastNonZeroVolume = 0.9
    @Published private(set) var isScrubbing = false
    private var wasPlayingBeforeScrub = false
    private var isMenuInteractionActive = false
    private var isHoveringStage = false
    private var currentPlayback: VideoPlayback? = nil
    private weak var window: NSWindow?
    private var keyboardEventMonitor: Any? = nil
    private var prepareTask: Task<Void, Never>? = nil
    private var hideControlsTask: Task<Void, Never>? = nil
    private var menuInteractionTask: Task<Void, Never>? = nil
    private var mpvStateTask: Task<Void, Never>? = nil
    private var sponsorSkipTask: Task<Void, Never>? = nil
    private var feedbackDismissTask: Task<Void, Never>? = nil
    private var spacebarHoldTask: Task<Void, Never>? = nil
    private var playbackSpeedTransitionTask: Task<Void, Never>? = nil
    private var pausedResizeRefreshTask: Task<Void, Never>? = nil
    private var lastInteractionAt = Date()
    private var lastPointerMovementAt = Date.distantPast
    private var temporaryPlaybackSpeedOverride: Double? = nil
    private var isSpacebarPressed = false
    private var didActivateSpacebarHoldSpeed = false
    private var initialStartTime: Double = 0
    private var suppressedSponsorSegmentID: String? = nil
    var onPlaybackEnded: (() -> Void)?
    var onShortcutAction: ((PlayerKeyAction) -> Void)?

    private var scrollMonitor: Any? = nil

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

    var qualityControlDetail: String? {
        guard qualityControlSelectionID != QualityOption.automaticID else {
            return nil
        }
        return displayedQualityOption?.detail
    }

    var qualityControlSelectionID: String {
        pendingQualityOptionID ?? selectedQualityOptionID
    }

    var fullscreenSymbolName: String {
        layoutState.isFullscreen
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
    }

    var theaterSymbolName: String {
        layoutState.isTheaterMode
            ? "tv.fill"
            : "tv"
    }

    var sidebarPanelSymbolName: String {
        layoutState.isSidePanelVisible
            ? "sidebar.right"
            : "sidebar.right"
    }

    var isTheaterMode: Bool {
        layoutState.isTheaterMode
    }

    var isFullscreen: Bool {
        layoutState.isFullscreen
    }

    var isSidePanelVisible: Bool {
        layoutState.isSidePanelVisible
    }

    var shouldShowPlaybackLoadingOverlay: Bool {
        isPreparingInitialPlayback || isSwitchingQuality || mpvEngine == nil
    }

    var playbackLoadingText: String {
        if isSwitchingQuality {
            return "Switching quality..."
        }
        if isPreparingInitialPlayback {
            return "Loading video..."
        }
        return "Buffering..."
    }

    var shouldShowPlaybackErrorOverlay: Bool {
        errorMessage != nil && mpvEngine == nil
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
        formatTime(isScrubbing ? scrubPosition : currentTime)
    }

    var isLivePlayback: Bool {
        currentPlayback?.isLive == true
    }

    var liveLatencySeconds: Double {
        guard isLivePlayback else { return 0 }
        let t = isScrubbing ? scrubPosition : currentTime
        return max(scrubberUpperBound - t, 0)
    }

    var isAtLiveEdge: Bool {
        guard isLivePlayback else { return false }
        let liveLag = liveLatencySeconds
        if liveLag <= liveEdgeThresholdSeconds {
            return true
        }
        // Keep the thumb pinned to the edge while playback hovers a few seconds
        // behind a moving live window instead of oscillating between states.
        return isPlaying && !isScrubbing && liveLag <= liveEdgeStickyThresholdSeconds
    }

    var liveLatencyText: String {
        guard isLivePlayback else { return "" }
        let liveLag = liveLatencySeconds
        guard liveLag > 2 else { return "" }
        return "-\(formatTime(liveLag))"
    }

    var remainingTimeText: String {
        guard scrubberUpperBound > scrubberLowerBound else { return "--:--" }
        let t = isScrubbing ? scrubPosition : currentTime
        return "-\(formatTime(max(scrubberUpperBound - t, 0)))"
    }

    /// Fraction (0…1) to use for the scrub preview thumbnail.
    /// Uses the cursor pixel position (scrubHoverFraction) when available — it tracks
    /// the actual cursor more accurately than the slider value.
    /// Falls back to the slider value fraction when dragging and no hover is active.
    var scrubPreviewFraction: Double? {
        if let hover = scrubHoverFraction { return hover }
        if isScrubbing { return scrubberFraction(for: scrubPosition) }
        return nil
    }

    var scrubberLowerBound: Double {
        if isLivePlayback {
            if let liveWindowDurationSeconds = currentPlayback?.liveWindowDurationSeconds,
               liveWindowDurationSeconds > 0 {
                return max(scrubberUpperBound - liveWindowDurationSeconds, 0)
            }
            if let liveSeekableRange {
                return liveSeekableRange.lowerBound
            }
        }
        return 0
    }

    var scrubberUpperBound: Double {
        if isLivePlayback {
            if let liveSeekableRange {
                return max(liveSeekableRange.upperBound, currentTime)
            }
            return max(currentTime, duration)
        }
        return max(duration, 0)
    }

    var scrubberRange: ClosedRange<Double> {
        let lower = scrubberLowerBound
        let upper = scrubberUpperBound
        guard upper > lower else { return lower...(lower + 1) }
        return lower...upper
    }

    var scrubberSpan: Double {
        max(scrubberUpperBound - scrubberLowerBound, 0)
    }

    var hasSeekableTimeline: Bool {
        scrubberSpan > 0.001
    }

    func storyboardTime(for absoluteTime: Double, spec: StoryboardSpec) -> Double {
        let relativeTime: Double
        if isLivePlayback {
            relativeTime = absoluteTime - scrubberLowerBound
        } else {
            relativeTime = absoluteTime
        }

        let safeTime = max(relativeTime, 0)
        let maxStoryboardTime = max(spec.coveredDurationSeconds - spec.intervalSeconds, 0)
        return min(safeTime, maxStoryboardTime)
    }

    var displayedScrubPosition: Double {
        guard isLivePlayback, !isScrubbing else { return scrubPosition }
        return isAtLiveEdge ? scrubberUpperBound : scrubPosition
    }

    var visibleSponsorSegments: [SponsorBlockSegment] {
        guard AppSettings.shared.sponsorBlockEnabled, duration > 0 else { return [] }
        return sponsorSegments.filter { segment in
            segment.endTime > 0
                && segment.startTime < duration
                && sponsorBehavior(for: segment).showsInSeekBar
        }
    }

    var visibleBufferedRanges: [ClosedRange<Double>] {
        guard duration > 0, !isLivePlayback else { return [] }
        return bufferedRanges.compactMap { range in
            let lower = min(max(range.lowerBound, 0), duration)
            let upper = min(max(range.upperBound, 0), duration)
            guard upper > lower else { return nil }
            return lower...upper
        }
    }

    func sponsorSegment(at time: Double) -> SponsorBlockSegment? {
        visibleSponsorSegments.first { $0.contains(time) }
    }

    var hasSubtitleOptions: Bool {
        !subtitleOptions.isEmpty
    }

    var subtitleControlText: String {
        if subtitleOptions.isEmpty { return "No Subtitles" }
        if selectedSubtitleOptionID == SubtitleOption.offID { return "Off" }
        return subtitleOptions.first(where: { $0.id == selectedSubtitleOptionID })?.title ?? "Off"
    }

    var subtitleSymbolName: String {
        selectedSubtitleOptionID == SubtitleOption.offID
            ? "captions.bubble"
            : "captions.bubble.fill"
    }

    var playbackSpeedControlText: String {
        AppSettings.playbackSpeedLabel(selectedPlaybackSpeed)
    }

    var effectivePlaybackSpeedText: String {
        AppSettings.playbackSpeedLabel(effectivePlaybackSpeed)
    }

    var isSpacebarHoldSpeedActive: Bool {
        temporaryPlaybackSpeedOverride != nil && didActivateSpacebarHoldSpeed
    }

    var spacebarHoldSpeedIndicatorText: String {
        "Hold speed \(AppSettings.playbackSpeedLabel(temporaryPlaybackSpeedOverride ?? effectivePlaybackSpeed))"
    }

    func configure(with playback: VideoPlayback) {
        prepareTask?.cancel()
        prepareTask = Task { [weak self] in
            await self?.preparePlayback(playback)
        }
    }

    func setInitialStartTime(_ seconds: Double) {
        initialStartTime = max(0, seconds)
    }

    func scrubberFraction(for time: Double) -> Double? {
        let span = scrubberSpan
        guard span > 0 else { return nil }
        return max(0, min(1, (clampToScrubberBounds(time) - scrubberLowerBound) / span))
    }

    func scrubberTime(forFraction fraction: Double) -> Double {
        let clampedFraction = max(0, min(1, fraction))
        let span = scrubberSpan
        guard span > 0 else { return scrubberLowerBound }
        return scrubberLowerBound + (span * clampedFraction)
    }

    func updateSponsorSegments(_ segments: [SponsorBlockSegment]) {
        sponsorSegments = segments.sorted { lhs, rhs in
            lhs.startTime == rhs.startTime
                ? lhs.endTime < rhs.endTime
                : lhs.startTime < rhs.startTime
        }
        if suppressedSponsorSegmentID != nil,
           sponsorSegments.contains(where: { $0.id == suppressedSponsorSegmentID }) == false {
            suppressedSponsorSegmentID = nil
        }
        if let manualSkipSponsorSegment,
           sponsorSegments.contains(where: { $0.id == manualSkipSponsorSegment.id }) == false {
            self.manualSkipSponsorSegment = nil
        }
    }

    func reset() {
        prepareTask?.cancel()
        stopHideMonitor()
        menuInteractionTask?.cancel()
        mpvStateTask?.cancel()
        spacebarHoldTask?.cancel()
        playbackSpeedTransitionTask?.cancel()
        pausedResizeRefreshTask?.cancel()
        errorMessage = nil
        isPreparingInitialPlayback = false
        controlsVisible = true
        isPlaying = false
        didReachPlaybackEnd = false
        currentTime = 0
        duration = 0
        scrubPosition = 0
        qualityOptions = [QualityOption.automatic]
        selectedQualityOptionID = QualityOption.automaticID
        pendingQualityOptionID = nil
        subtitleOptions = []
        selectedSubtitleOptionID = SubtitleOption.offID
        selectedPlaybackSpeed = AppSettings.shared.defaultPlaybackSpeed
        effectivePlaybackSpeed = selectedPlaybackSpeed
        currentPlayback = nil
        layoutState.isTheaterMode = false
        layoutState.isSidePanelVisible = false
        keyboardLocked = false
        isRefreshingPausedSurface = false
        videoAspect = 16.0 / 9.0
        storyboard = nil
        sponsorSegments = []
        manualSkipSponsorSegment = nil
        liveSeekableRange = nil
        bufferedRanges = []
        scrubHoverFraction = nil
        wasPlayingBeforeScrub = false
        lastInteractionAt = Date()
        lastPointerMovementAt = .distantPast
        temporaryPlaybackSpeedOverride = nil
        isSpacebarPressed = false
        didActivateSpacebarHoldSpeed = false
        initialStartTime = 0
        suppressedSponsorSegmentID = nil
        sponsorSkipTask?.cancel()
        sponsorSkipTask = nil
        pausedResizeRefreshTask = nil
        scheduleMPVStop(mpvEngine, pauseFirst: true)
        mpvEngine = nil
    }

    func stop() {
        reset()
        removeKeyboardMonitor()
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
        installScrollMonitor()
        installKeyboardMonitor()

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
        guard let mpvEngine else { return }
        if shouldRestartFromEnd {
            restartPlayback()
            return
        }
        if isPlaying {
            mpvEngine.pause()
            isPlaying = false
            showFeedback(.pause)
        } else {
            mpvEngine.play()
            isPlaying = true
            showFeedback(.play)
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
            scrubPosition = clampToScrubberBounds(currentTime)
            stopHideMonitor()
            // Pause the video so fast seeks show a held frame rather than
            // briefly playing from each keyframe before the next seek arrives.
            wasPlayingBeforeScrub = isPlaying
            if isPlaying {
                mpvEngine?.pause()
                isPlaying = false
            }
            return
        }

        seekToScrubPosition()
    }

    func updateScrubPosition(_ value: Double) {
        scrubPosition = clampToScrubberBounds(value)
        noteInteraction()
    }

    func beginMenuInteraction() {
        isMenuInteractionActive = true
        noteInteraction()
        menuInteractionTask?.cancel()
    }

    func endMenuInteraction() {
        isMenuInteractionActive = false
        menuInteractionTask?.cancel()
        menuInteractionTask = nil
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

        PlaybackDebugLogger.log(
            "quality select request option=\(debugDescription(for: option)) previous=\(selectedQualityOptionID)"
        )
        noteInteraction()
        let previousSelectionID = selectedQualityOptionID
        pendingQualityOptionID = option.id

        prepareTask?.cancel()
        prepareTask = Task { [weak self] in
            await self?.switchQuality(
                to: option,
                playback: playback,
                previousSelectionID: previousSelectionID
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
        withAnimation(.snappy(duration: 0.16, extraBounce: 0)) {
            if layoutState.isFullscreen {
                window?.toggleFullScreen(nil)
            }
            layoutState.isTheaterMode.toggle()
        }
        noteInteraction()
    }

    func toggleFullscreen() {
        noteInteraction()
        if layoutState.isTheaterMode {
            withAnimation(.snappy(duration: 0.16, extraBounce: 0)) {
                layoutState.isTheaterMode = false
            }
        }
        window?.toggleFullScreen(nil)
        // applyImmersiveToolbarState() is called from the fullscreen notifications
    }

    func toggleSidePanel() {
        noteInteraction()
        withAnimation(.snappy(duration: 0.16, extraBounce: 0)) {
            layoutState.isSidePanelVisible.toggle()
        }
    }

    func toggleSubtitles() {
        noteInteraction()
        guard !subtitleOptions.isEmpty else { return }

        if selectedSubtitleOptionID == SubtitleOption.offID {
            applySubtitleSelection(subtitleOptions[0])
        } else {
            applySubtitleSelection(.off)
        }
    }

    func selectSubtitle(_ option: SubtitleOption) {
        noteInteraction()
        applySubtitleSelection(option)
    }

    func selectPlaybackSpeed(_ speed: Double) {
        noteInteraction()
        selectedPlaybackSpeed = speed
        applyPlaybackSpeed()
    }

    func handlePlayerSurfaceLayoutChange() {
        guard let mpvEngine else { return }
        guard !isPlaying, !isScrubbing, !isPreparingInitialPlayback, !isLivePlayback else { return }

        pausedResizeRefreshTask?.cancel()
        isRefreshingPausedSurface = true
        pausedResizeRefreshTask = Task { @MainActor [weak self, weak mpvEngine] in
            defer {
                self?.isRefreshingPausedSurface = false
            }
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, let mpvEngine, !Task.isCancelled else { return }
            guard self.mpvEngine === mpvEngine,
                  !self.isPlaying,
                  !self.isScrubbing,
                  !self.isPreparingInitialPlayback,
                  !self.isLivePlayback else {
                return
            }

            let restoreTime = clampToScrubberBounds(currentTime)
            let selectedSubtitleID = selectedSubtitleOptionID

            do {
                try mpvEngine.refreshPausedFrame(at: restoreTime)
                mpvEngine.pause()
                if selectedSubtitleID == SubtitleOption.offID {
                    mpvEngine.setSubtitleVisibility(false)
                } else if let option = subtitleOptions.first(where: { $0.id == selectedSubtitleID }) {
                    applySubtitleSelection(option)
                }
                currentTime = restoreTime
                scrubPosition = restoreTime
                syncMPVState(using: mpvEngine)
            } catch {
                PlaybackDebugLogger.log("mpv paused resize refresh failed error=\(error.localizedDescription)")
            }
        }
    }

    func handleSpacebarKeyDown() {
        noteInteraction()
        guard !isSpacebarPressed else { return }
        isSpacebarPressed = true
        didActivateSpacebarHoldSpeed = false
        spacebarHoldTask?.cancel()
        spacebarHoldTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Timing.spacebarHoldDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.activateSpacebarHoldSpeedIfNeeded()
            }
        }
    }

    func handleSpacebarKeyUp() {
        noteInteraction()
        isSpacebarPressed = false
        spacebarHoldTask?.cancel()
        spacebarHoldTask = nil

        if didActivateSpacebarHoldSpeed {
            didActivateSpacebarHoldSpeed = false
            temporaryPlaybackSpeedOverride = nil
            applyPlaybackSpeed(animated: true)
            return
        }

        togglePlayback()
    }

    func seekRelative(_ seconds: Double) {
        guard mpvEngine != nil, hasSeekableTimeline else { return }
        noteInteraction()
        let amount = Int(seconds)
        showFeedback(amount >= 0 ? .seekForward(amount) : .seekBackward(-amount))
        let target = clampToScrubberBounds(currentTime + seconds)
        scrubPosition = target
        currentTime = target
        Task { [weak self] in
            guard let self, let mpvEngine else { return }
            await mpvEngine.seek(to: target)
            syncMPVState(using: mpvEngine)
        }
    }

    func seek(to seconds: Double) {
        guard mpvEngine != nil, hasSeekableTimeline else { return }
        noteInteraction()
        let target = clampToScrubberBounds(seconds)
        scrubPosition = target
        currentTime = target
        didReachPlaybackEnd = false
        Task { [weak self] in
            guard let self, let mpvEngine else { return }
            await mpvEngine.seek(to: target)
            syncMPVState(using: mpvEngine)
        }
    }

    func seekToLiveEdge() {
        guard isLivePlayback else { return }
        seek(to: scrubberUpperBound)
    }

    func stepFrame(direction: Int) {
        guard let mpvEngine, !isPlaying else { return }
        noteInteraction()
        showFeedback(direction >= 0 ? .frameForward : .frameBackward)
        mpvEngine.stepFrame(direction: direction)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self, let mpvEngine = self.mpvEngine else { return }
            self.syncMPVState(using: mpvEngine)
        }
    }

    func restartPlayback() {
        noteInteraction()
        didReachPlaybackEnd = false
        suppressedSponsorSegmentID = nil
        Task { [weak self] in
            guard let self, let mpvEngine else { return }
            await mpvEngine.seek(to: 0)
            mpvEngine.play()
            syncMPVState(using: mpvEngine)
        }
    }

    func triggerShortcutAction(_ action: PlayerKeyAction) {
        switch action {
        case .playPause:
            togglePlayback()
        case .seekShortBack:
            seekRelative(-AppSettings.shared.seekSeconds(for: .short))
        case .seekShortForward:
            seekRelative(AppSettings.shared.seekSeconds(for: .short))
        case .seekMediumBack:
            seekRelative(-AppSettings.shared.seekSeconds(for: .medium))
        case .seekMediumForward:
            seekRelative(AppSettings.shared.seekSeconds(for: .medium))
        case .seekLongBack:
            seekRelative(-AppSettings.shared.seekSeconds(for: .long))
        case .seekLongForward:
            seekRelative(AppSettings.shared.seekSeconds(for: .long))
        case .frameBack:
            stepFrame(direction: -1)
        case .frameForward:
            stepFrame(direction: 1)
        case .theaterMode:
            toggleTheaterMode()
        case .fullscreen:
            toggleFullscreen()
        case .subtitles:
            toggleSubtitles()
        case .likeVideo, .dislikeVideo, .watchLater, .saveToPlaylist, .subscribe, .share:
            onShortcutAction?(action)
        }
    }

    private var activeQualityOption: QualityOption? {
        qualityOptions.first(where: { $0.id == selectedQualityOptionID })
    }

    private var displayedQualityOption: QualityOption? {
        qualityOptions.first(where: { $0.id == qualityControlSelectionID })
    }

    private func manualQualityOptionID(for selection: ManualPlaybackSelection) -> String? {
        qualityOptions.first(where: { option in
            switch option.selection {
            case .manual(let candidateSelection):
                return candidateSelection.stream.url == selection.stream.url
                    && candidateSelection.audioStream?.url == selection.audioStream?.url
            case .automatic:
                return false
            }
        })?.id
    }

    private func scheduleMPVStop(_ engine: MPVPlaybackEngine?, pauseFirst: Bool = false) {
        guard let engine else { return }
        if pauseFirst {
            engine.pause()
        }
        Task { @MainActor in
            await engine.stopSafely()
        }
    }

    private func preparePlayback(_ playback: VideoPlayback) async {
        errorMessage = nil
        isPreparingInitialPlayback = true
        pendingQualityOptionID = nil
        controlsVisible = true
        selectedPlaybackSpeed = AppSettings.shared.defaultPlaybackSpeed
        temporaryPlaybackSpeedOverride = nil
        effectivePlaybackSpeed = selectedPlaybackSpeed

        do {
            currentPlayback = playback
            sponsorSegments = playback.sponsorSegments
            selectedQualityOptionID = QualityOption.automaticID
            mpvStateTask?.cancel()
            scheduleMPVStop(mpvEngine, pauseFirst: true)
            mpvEngine = nil

            let startupSelections = automaticStartupMPVSelections(for: playback)
            guard let firstSelection = startupSelections.first else {
                PlaybackDebugLogger.log(
                    "prepare playback missing startup source id=\(playback.id) streams=\(playback.streams.count)"
                )
                if let accessIssue = playback.accessIssue {
                    errorMessage = accessIssue.message
                    isPreparingInitialPlayback = false
                    return
                }
                throw URLError(.badURL)
            }

            let startupLimit = playback.isLive ? min(startupSelections.count, 4) : 1
            let candidateSelections = Array(startupSelections.prefix(startupLimit))
            var preparedEngine: MPVPlaybackEngine?
            var preparedSelection = firstSelection
            var lastPreparationError: Error?

            for (index, selection) in candidateSelections.enumerated() {
                let request = try mpvRequest(for: selection)
                PlaybackDebugLogger.log(
                    "prepare playback attempt \(index + 1)/\(candidateSelections.count) id=\(playback.id) video=\(debugDescription(for: selection.stream)) audio=\(debugDescription(for: selection.audioStream))"
                )

                let engine = MPVPlaybackEngine(request: request)
                engine.onPlaybackEnded = { [weak self] in
                    self?.handlePlaybackEndedEvent()
                }
                mpvEngine = engine

                do {
                    let startTime = initialStartTime
                    try await engine.prepare(startTime: startTime, autoPlay: false)
                    preparedEngine = engine
                    preparedSelection = selection
                    break
                } catch {
                    lastPreparationError = error
                    PlaybackDebugLogger.log(
                        "prepare playback attempt failed id=\(playback.id) index=\(index + 1) error=\(error.localizedDescription)"
                    )
                    mpvEngine = nil
                    scheduleMPVStop(engine)
                }
            }

            guard let engine = preparedEngine else {
                throw lastPreparationError ?? URLError(.cannotOpenFile)
            }
            guard !Task.isCancelled else { return }
            engine.setVolume(volume)
            engine.setRate(effectivePlaybackSpeed)
            engine.play()

            let startTime = initialStartTime
            currentTime = startTime
            scrubPosition = startTime
            duration = 0
            storyboard = playback.storyboard
            initialStartTime = 0
            startPollingMPVState(using: engine)
            refreshQualityOptions(for: playback)
            loadSubtitleTracks(for: playback, engine: engine)
            if let optionID = manualQualityOptionID(for: preparedSelection) {
                selectedQualityOptionID = optionID
            }
            startHideMonitorIfNeeded()
        } catch {
            if !Task.isCancelled {
                PlaybackDebugLogger.log(
                    "prepare playback failed id=\(playback.id) error=\(error.localizedDescription)"
                )
                scheduleMPVStop(mpvEngine)
                mpvEngine = nil
                errorMessage = "Failed to prepare video."
            }
        }

        if !Task.isCancelled {
            isPreparingInitialPlayback = false
        }
    }

    private func switchQuality(
        to option: QualityOption,
        playback: VideoPlayback,
        previousSelectionID: String
    ) async {
        errorMessage = nil
        sponsorSegments = playback.sponsorSegments
        PlaybackDebugLogger.log(
            "quality switch start option=\(debugDescription(for: option)) previous=\(previousSelectionID)"
        )

        do {
            let selection: ManualPlaybackSelection
            switch option.selection {
            case .manual(let manualSelection):
                selection = manualSelection
            case .automatic:
                guard let autoSelection = automaticStartupMPVSelection(for: playback) else {
                    throw URLError(.badURL)
                }
                selection = autoSelection
            }

            let request = try mpvRequest(for: selection)

            if let existingEngine = mpvEngine {
                let restoreState = currentRestoreState()
                let clampedTime = max(restoreState.currentTime, 0)

                PlaybackDebugLogger.log(
                    "mpv in-place switch start option=\(debugDescription(for: option)) seekTo=\(clampedTime)"
                )

                mpvStateTask?.cancel()
                try await existingEngine.replaceFile(with: request, seekTo: clampedTime)
                existingEngine.setVolume(volume)
                existingEngine.setRate(effectivePlaybackSpeed)

                if restoreState.wasPlaying {
                    existingEngine.play()
                } else {
                    existingEngine.pause()
                }

                currentTime = clampedTime
                scrubPosition = clampedTime
                pendingQualityOptionID = nil
                startPollingMPVState(using: existingEngine)
            } else {
                let engine = MPVPlaybackEngine(request: request)
                engine.onPlaybackEnded = { [weak self] in
                    self?.handlePlaybackEndedEvent()
                }
                mpvEngine = engine

                let startTime = initialStartTime
                try await engine.prepare(startTime: startTime, autoPlay: false)
                guard !Task.isCancelled else { return }
                engine.setVolume(volume)
                engine.setRate(effectivePlaybackSpeed)
                engine.play()

                currentTime = startTime
                scrubPosition = startTime
                duration = 0
                pendingQualityOptionID = nil
                initialStartTime = 0
                startPollingMPVState(using: engine)
            }

            refreshQualityOptions(for: playback)
            if let engine = mpvEngine {
                reapplySubtitlesAfterSwitch(for: playback, engine: engine)
            }
            if case .automatic = option.selection,
               let optionID = manualQualityOptionID(for: selection) {
                selectedQualityOptionID = optionID
            } else {
                selectedQualityOptionID = option.id
            }
            PlaybackDebugLogger.log(
                "quality switch success option=\(debugDescription(for: option)) duration=\(duration) currentTime=\(currentTime)"
            )
        } catch {
            if !Task.isCancelled {
                PlaybackDebugLogger.log(
                    "quality switch failed option=\(debugDescription(for: option)) previous=\(previousSelectionID) error=\(error.localizedDescription)"
                )
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

    private func refreshQualityOptions(for playback: VideoPlayback) {
        qualityOptions = [QualityOption.automatic] + buildQualityOptions(for: playback)
        PlaybackDebugLogger.log(
            "quality options refreshed options=\(qualityOptions.map(debugDescription(for:)).joined(separator: " | ")) selected=\(selectedQualityOptionID)"
        )
        if qualityOptions.contains(where: { $0.id == selectedQualityOptionID }) == false {
            selectedQualityOptionID = QualityOption.automaticID
        }
        if let pendingQualityOptionID,
           qualityOptions.contains(where: { $0.id == pendingQualityOptionID }) == false {
            self.pendingQualityOptionID = nil
        }
    }

    @objc private func handleWindowDidEnterFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        withAnimation(.snappy(duration: 0.16, extraBounce: 0)) {
            layoutState.isFullscreen = true
        }
        // Do not touch toolbar in fullscreen — macOS handles auto-hide natively.
    }

    @objc private func handleWindowDidExitFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        withAnimation(.snappy(duration: 0.16, extraBounce: 0)) {
            layoutState.isFullscreen = false
        }
        // Toolbar restored automatically by macOS on fullscreen exit.
    }

    private func startHideMonitorIfNeeded() {
        guard mpvEngine != nil else { return }
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
                    guard self.mpvEngine != nil else { return .stop }

                    if self.isPreparingInitialPlayback {
                        return .keepWatching
                    }

                    if self.isScrubbing || self.isMenuInteractionActive {
                        return .keepWatching
                    }

                    let idleTime = Date().timeIntervalSince(self.lastInteractionAt)
                    let timeout = self.isHoveringStage ? Timing.inactivityHideDelay : 0.8
                    return idleTime >= timeout ? .hide : .keepWatching
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
        guard mpvEngine != nil else { return }
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
        mpvEngine?.setVolume(clampedVolume)
    }

    private func activateSpacebarHoldSpeedIfNeeded() {
        guard isSpacebarPressed, isPlaying else { return }
        let holdSpeed = max(selectedPlaybackSpeed, AppSettings.shared.spacebarHoldPlaybackSpeed)
        temporaryPlaybackSpeedOverride = holdSpeed
        didActivateSpacebarHoldSpeed = true
        applyPlaybackSpeed()
    }

    private func applyPlaybackSpeed(animated: Bool = false) {
        let resolvedSpeed = temporaryPlaybackSpeedOverride ?? selectedPlaybackSpeed
        playbackSpeedTransitionTask?.cancel()

        guard animated, let mpvEngine else {
            effectivePlaybackSpeed = resolvedSpeed
            self.mpvEngine?.setRate(resolvedSpeed)
            return
        }

        let startingSpeed = effectivePlaybackSpeed
        guard abs(startingSpeed - resolvedSpeed) > 0.01 else {
            effectivePlaybackSpeed = resolvedSpeed
            mpvEngine.setRate(resolvedSpeed)
            return
        }

        playbackSpeedTransitionTask = Task { @MainActor [weak self, weak mpvEngine] in
            let steps = 6
            let frameDelay: UInt64 = 20_000_000

            for step in 1...steps {
                guard let self, let mpvEngine, !Task.isCancelled else { return }
                let progress = Double(step) / Double(steps)
                let interpolatedSpeed = startingSpeed + ((resolvedSpeed - startingSpeed) * progress)
                effectivePlaybackSpeed = interpolatedSpeed
                mpvEngine.setRate(interpolatedSpeed)
                if step < steps {
                    try? await Task.sleep(nanoseconds: frameDelay)
                }
            }

            guard let self, let mpvEngine, !Task.isCancelled else { return }
            effectivePlaybackSpeed = resolvedSpeed
            mpvEngine.setRate(resolvedSpeed)
            playbackSpeedTransitionTask = nil
        }
    }

    private func currentRestoreState() -> PlaybackRestoreState {
        PlaybackRestoreState(
            currentTime: sanitizeSeconds(currentTime),
            wasPlaying: isPlaying
        )
    }

    private var shouldRestartFromEnd: Bool {
        guard !isLivePlayback else { return didReachPlaybackEnd }
        return didReachPlaybackEnd || (duration > 0 && currentTime >= max(duration - 0.35, 0))
    }

    private func clampToScrubberBounds(_ value: Double) -> Double {
        let lower = scrubberLowerBound
        let upper = scrubberUpperBound
        guard upper > lower else { return max(value, lower) }
        return min(max(value, lower), upper)
    }

    private func seekToScrubPosition() {
        let shouldResume = wasPlayingBeforeScrub
        didReachPlaybackEnd = false
        Task { [weak self] in
            guard let self, let mpvEngine else { return }
            let target = clampToScrubberBounds(scrubPosition)
            suppressSponsorSegmentIfUserSeekedIntoOne(at: target)
            currentTime = target
            scrubPosition = target
            await mpvEngine.seek(to: target)
            // Restore play state that was saved when scrubbing began.
            if shouldResume {
                mpvEngine.play()
                isPlaying = true
            }
            syncMPVState(using: mpvEngine)
            if isHoveringStage {
                startHideMonitorIfNeeded()
            } else {
                hideControlsIfAllowed()
            }
        }
    }

    private func handlePlaybackEndedEvent() {
        isPlaying = false
        didReachPlaybackEnd = true
        controlsVisible = true
        stopHideMonitor()
        if duration > 0 {
            currentTime = duration
            if !isScrubbing {
                scrubPosition = duration
            }
        }
        onPlaybackEnded?()
    }

    private func maybeClearSuppressedSponsorSegment() {
        guard let suppressedSponsorSegmentID,
              let segment = sponsorSegments.first(where: { $0.id == suppressedSponsorSegmentID }) else {
            suppressedSponsorSegmentID = nil
            return
        }

        let outsideSegment = currentTime < max(segment.startTime - 0.4, 0) || currentTime > segment.endTime + 0.4
        if outsideSegment {
            self.suppressedSponsorSegmentID = nil
        }
    }

    func skipManualSponsorSegment() {
        guard let segment = manualSkipSponsorSegment else { return }
        skipSponsorSegment(segment)
    }

    private func sponsorBehavior(for segment: SponsorBlockSegment) -> SponsorBlockBehavior {
        guard let category = segment.resolvedCategory else {
            return .disabled
        }
        return AppSettings.shared.sponsorBlockBehavior(for: category)
    }

    private func suppressSponsorSegmentIfUserSeekedIntoOne(at time: Double) {
        guard AppSettings.shared.sponsorBlockEnabled else { return }
        guard let segment = sponsorSegments.first(where: { segment in
            sponsorBehavior(for: segment) != .disabled && segment.contains(time, trailOut: 0.2)
        }) else {
            return
        }
        suppressedSponsorSegmentID = segment.id
        manualSkipSponsorSegment = nil
    }

    private func currentlyRelevantSponsorSegment() -> SponsorBlockSegment? {
        sponsorSegments.first(where: { segment in
            segment.id != suppressedSponsorSegmentID
                && sponsorBehavior(for: segment) != .disabled
                && segment.contains(currentTime, trailOut: 0.05)
        })
    }

    private func updateSponsorBlockState(using engine: MPVPlaybackEngine, previousTime: Double) {
        guard AppSettings.shared.sponsorBlockEnabled, !isScrubbing, !didReachPlaybackEnd, duration > 0 else {
            manualSkipSponsorSegment = nil
            return
        }

        guard let segment = currentlyRelevantSponsorSegment() else {
            manualSkipSponsorSegment = nil
            return
        }

        let behavior = sponsorBehavior(for: segment)
        if behavior.showsManualPrompt {
            manualSkipSponsorSegment = segment
        } else if manualSkipSponsorSegment?.id == segment.id {
            manualSkipSponsorSegment = nil
        }

        guard behavior.autoSkips else { return }
        maybeAutoSkipSponsorSegment(segment, using: engine, previousTime: previousTime)
    }

    private func maybeAutoSkipSponsorSegment(
        _ segment: SponsorBlockSegment,
        using engine: MPVPlaybackEngine,
        previousTime: Double
    ) {
        guard sponsorSkipTask == nil else { return }

        let enteredFromBefore = previousTime < segment.startTime + 0.1 || abs(previousTime - currentTime) > 1.0
        guard enteredFromBefore else { return }

        let skipTarget = segment.skipTarget(within: duration)
        guard skipTarget > currentTime else { return }

        suppressedSponsorSegmentID = segment.id
        manualSkipSponsorSegment = nil
        sponsorSkipTask = Task { @MainActor [weak self, weak engine] in
            defer { self?.sponsorSkipTask = nil }
            guard let self, let engine else { return }
            await engine.seek(to: skipTarget)
            self.currentTime = skipTarget
            if !self.isScrubbing {
                self.scrubPosition = skipTarget
            }
        }
    }

    private func skipSponsorSegment(_ segment: SponsorBlockSegment) {
        guard let mpvEngine, duration > 0 else { return }
        let skipTarget = segment.skipTarget(within: duration)
        guard skipTarget > currentTime else { return }

        suppressedSponsorSegmentID = segment.id
        manualSkipSponsorSegment = nil
        sponsorSkipTask?.cancel()
        sponsorSkipTask = Task { @MainActor [weak self, weak mpvEngine] in
            defer { self?.sponsorSkipTask = nil }
            guard let self, let mpvEngine else { return }
            await mpvEngine.seek(to: skipTarget)
            self.currentTime = skipTarget
            if !self.isScrubbing {
                self.scrubPosition = skipTarget
            }
        }
    }

    private func startPollingMPVState(using engine: MPVPlaybackEngine) {
        mpvStateTask?.cancel()
        syncMPVState(using: engine)
        mpvStateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.mpvEngine === engine else { return }
                self.syncMPVState(using: engine)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func syncMPVState(using engine: MPVPlaybackEngine) {
        let previousTime = currentTime
        let snapshot = engine.snapshot()
        currentTime = sanitizeSeconds(snapshot.currentTime)
        if !isScrubbing {
            scrubPosition = currentTime
        }
        liveSeekableRange = isLivePlayback ? snapshot.liveSeekableRange : nil
        bufferedRanges = snapshot.bufferedRanges
        if snapshot.duration > 0 {
            duration = sanitizeSeconds(snapshot.duration)
        }
        isPlaying = snapshot.isPlaying
        if engine.videoAspect > 0 { videoAspect = engine.videoAspect }
        if didReachPlaybackEnd, currentTime + 0.25 < scrubberUpperBound {
            didReachPlaybackEnd = false
        }
        maybeClearSuppressedSponsorSegment()
        updateSponsorBlockState(using: engine, previousTime: previousTime)
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

    private func buildQualityOptions(for playback: VideoPlayback) -> [QualityOption] {
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
                if manualQualitySortKey(for: candidate) > manualQualitySortKey(for: existing) {
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

    private func debugDescription(for option: QualityOption) -> String {
        switch option.selection {
        case .automatic:
            return "option[id=\(option.id),title=\(option.title),automatic]"
        case .manual(let selection):
            return "option[id=\(option.id),title=\(option.title),video=\(debugDescription(for: selection.stream)),audio=\(debugDescription(for: selection.audioStream))]"
        }
    }

    private func debugDescription(for stream: StreamInfo?) -> String {
        guard let stream else { return "stream=nil" }
        return "stream[format=\(stream.formatId ?? "nil"),kind=\(stream.streamKind),quality=\(stream.qualityLabel ?? "nil"),container=\(stream.container ?? "nil"),vcodec=\(stream.videoCodec ?? "nil"),acodec=\(stream.audioCodec ?? "nil"),channels=\(stream.audioChannels.map(String.init) ?? "nil"),fps=\(stream.fps.map(String.init) ?? "nil"),bitrate=\(stream.bitrate.map(String.init) ?? "nil"),url=\(stream.url)]"
    }

    private func showFeedback(_ feedback: ActionFeedback) {
        feedbackDismissTask?.cancel()

        // Accumulate seek amounts when pressing the same direction rapidly
        let resolved: ActionFeedback
        switch (actionFeedback, feedback) {
        case (.seekForward(let prev), .seekForward(let next)):
            resolved = .seekForward(prev + next)
        case (.seekBackward(let prev), .seekBackward(let next)):
            resolved = .seekBackward(prev + next)
        default:
            resolved = feedback
        }

        actionFeedback = resolved
        feedbackGeneration += 1
        feedbackDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                self?.actionFeedback = nil
            }
        }
    }

    private func loadSubtitleTracks(for playback: VideoPlayback, engine: MPVPlaybackEngine) {
        guard let tracks = playback.subtitles, !tracks.isEmpty else {
            subtitleOptions = []
            selectedSubtitleOptionID = SubtitleOption.offID
            return
        }

        let filtered = tracks.filter { track in
            if !track.isAutoGenerated { return true }
            return track.language.lowercased().hasPrefix("en")
        }

        var seenKeys = Set<String>()
        let deduplicated = filtered.filter { track in
            seenKeys.insert(normalizedSubtitleOptionKey(for: track)).inserted
        }

        subtitleOptions = deduplicated.enumerated().map { index, track in
            let baseLabel = normalizedSubtitleDisplayTitle(for: track)
            let suffix = track.isAutoGenerated && baseLabel.lowercased().contains("(auto)") == false ? " (auto)" : ""
            return SubtitleOption(
                id: "subtitle-\(index)-\(track.language.lowercased())-\(baseLabel)",
                title: "\(baseLabel)\(suffix)",
                url: track.url,
                mpvTrackIndex: nil
            )
        }
        selectedSubtitleOptionID = SubtitleOption.offID
    }

    private func applySubtitleSelection(_ option: SubtitleOption) {
        guard let mpvEngine else { return }

        if option.isOff {
            mpvEngine.setSubtitleVisibility(false)
            mpvEngine.setSubtitleTrack(0)
            selectedSubtitleOptionID = SubtitleOption.offID
        } else if let url = option.url {
            mpvEngine.addSubtitle(url: url)
            mpvEngine.setSubtitleVisibility(true)
            selectedSubtitleOptionID = option.id
        }
    }

    private func reapplySubtitlesAfterSwitch(for playback: VideoPlayback, engine: MPVPlaybackEngine) {
        let previousID = selectedSubtitleOptionID
        loadSubtitleTracks(for: playback, engine: engine)

        if previousID != SubtitleOption.offID,
           let option = subtitleOptions.first(where: { $0.id == previousID }) {
            applySubtitleSelection(option)
        }
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

    private func normalizedSubtitleOptionKey(for track: SubtitleTrack) -> String {
        let language = track.language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let title = normalizedSubtitleDisplayTitle(for: track).lowercased()
        return "\(language)|\(title)"
    }

    private func normalizedSubtitleDisplayTitle(for track: SubtitleTrack) -> String {
        track.label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "(auto-generated)", with: "")
            .replacingOccurrences(of: "(auto)", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func installKeyboardMonitor() {
        guard keyboardEventMonitor == nil else { return }
        keyboardEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyboardEvent(event)
        }
    }

    private func removeKeyboardMonitor() {
        if let keyboardEventMonitor {
            NSEvent.removeMonitor(keyboardEventMonitor)
            self.keyboardEventMonitor = nil
        }
    }

    private func handleKeyboardEvent(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        guard mpvEngine != nil else { return event }
        guard !Self.windowHasActiveTextInput(window) else { return event }

        if matchesKeyboardLock(event) {
            if event.type == .keyDown, !event.isARepeat {
                keyboardLocked.toggle()
            }
            return nil
        }

        if keyboardLocked {
            return shouldPassUnhandledKeyboardEventThrough(event) ? event : nil
        }

        if event.keyCode == 49 {
            if event.type == .keyDown {
                if !event.isARepeat {
                    handleSpacebarKeyDown()
                }
            } else {
                handleSpacebarKeyUp()
            }
            return nil
        }

        if event.type == .keyDown,
           !event.isARepeat,
           (event.keyCode == 36 || event.keyCode == 76),
           manualSkipSponsorSegment != nil {
            skipManualSponsorSegment()
            return nil
        }

        guard event.type == .keyDown, !event.isARepeat else { return nil }

        let settings = AppSettings.shared
        for action in PlayerKeyAction.allCases {
            if settings.binding(for: action).matches(event) {
                triggerShortcutAction(action)
                return nil
            }
        }

        return shouldPassUnhandledKeyboardEventThrough(event) ? event : nil
    }

    private func matchesKeyboardLock(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp else { return false }
        guard let keyCode = AppSettings.shared.keyboardLockKey.keyCode else { return false }
        return event.keyCode == keyCode && KeyBindingModifiers(event.modifierFlags).isEmpty
    }

    private func shouldPassUnhandledKeyboardEventThrough(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            return true
        }
        return event.type == .keyUp
    }

    // MARK: - Scroll forwarding (NSEvent)

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleScrollEvent(event)
        }
    }

    private func handleScrollEvent(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        // Only intercept when the standard page layout is active.
        guard !layoutState.isFullscreen, !layoutState.isTheaterMode, mpvEngine != nil else { return event }
        // Check cursor is within the player NSView frame
        guard let playerView = mpvEngine?.renderController.view,
              let superview = playerView.superview else { return event }
        let playerFrame = superview.convert(playerView.frame, to: nil)
        guard playerFrame.contains(event.locationInWindow) else { return event }
        // Forward to the page NSScrollView and consume the original event
        guard let scrollView = Self.findPageScrollView(in: window) else { return event }
        scrollView.scrollWheel(with: event)
        return nil
    }

    private static func windowHasActiveTextInput(_ window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if responder is NSTextView { return true }
        if let view = responder as? NSView {
            return view is NSTextView || view.enclosingMenuItem != nil
        }
        return false
    }

    private static func findPageScrollView(in window: NSWindow) -> NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            for sub in view.subviews {
                if let sv = sub as? NSScrollView { return sv }
                if let found = find(sub) { return found }
            }
            return nil
        }
        return window.contentView.flatMap(find)
    }
}
