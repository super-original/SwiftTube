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
    guard stream.hasVideo, stream.streamKind != "manifest" else {
        return false
    }
    return true
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

private func isManualQualityVideoStream(_ stream: StreamInfo) -> Bool {
    guard stream.hasVideo,
          !stream.hasAudio,
          stream.streamKind != "manifest",
          (stream.height ?? 0) > 0,
          stream.container?.lowercased().hasPrefix("mp4") == true,
          stream.videoCodec?.hasPrefix("av01") == true else {
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

private func automaticStartupMPVSelection(for playback: VideoPlayback) -> ManualPlaybackSelection? {
    let audioStream = preferredStartupMPVAudioStream(for: playback)

    func buildSelection(for stream: StreamInfo?) -> ManualPlaybackSelection? {
        guard let stream, isMPVStartupVideoStream(stream) else {
            return nil
        }
        guard stream.hasAudio || (audioStream != nil && !hasConflictingHeaders(video: stream, audio: audioStream)) else {
            return nil
        }

        return ManualPlaybackSelection(
            stream: stream,
            audioStream: stream.hasAudio ? nil : audioStream
        )
    }

    if let selection = buildSelection(for: playback.preferredVideoStream) {
        return selection
    }

    if let selection = buildSelection(for: playback.preferredMuxedStream) {
        return selection
    }

    if let selection = buildSelection(for: playback.bestStream) {
        return selection
    }

    return playback.streams
        .filter(isMPVStartupVideoStream)
        .filter { stream in
            stream.hasAudio || (audioStream != nil && !hasConflictingHeaders(video: stream, audio: audioStream))
        }
        .max { automaticStartupMPVSortKey(for: $0) < automaticStartupMPVSortKey(for: $1) }
        .map { stream in
            ManualPlaybackSelection(
                stream: stream,
                audioStream: stream.hasAudio ? nil : audioStream
            )
        }
}

@MainActor
final class PlayerLayoutState: ObservableObject {
    @Published var isTheaterMode = false
    @Published var isFullscreen = false
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

    @Published private(set) var mpvEngine: MPVPlaybackEngine? = nil
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
    @Published private(set) var actionFeedback: ActionFeedback? = nil
    @Published var volume: Double = 0.9 {
        didSet {
            applyVolume()
        }
    }

    private let layoutState: PlayerLayoutState
    private var lastNonZeroVolume = 0.9
    private var isScrubbing = false
    private var isMenuInteractionActive = false
    private var isHoveringStage = false
    private var currentPlayback: VideoPlayback? = nil
    private weak var window: NSWindow?
    private var prepareTask: Task<Void, Never>? = nil
    private var hideControlsTask: Task<Void, Never>? = nil
    private var menuInteractionTask: Task<Void, Never>? = nil
    private var mpvStateTask: Task<Void, Never>? = nil
    private var feedbackDismissTask: Task<Void, Never>? = nil
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
        isPreparingInitialPlayback || mpvEngine == nil
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
        currentPlayback = nil
        layoutState.isTheaterMode = false
        lastInteractionAt = Date()
        lastPointerMovementAt = .distantPast
        scheduleMPVStop(mpvEngine, pauseFirst: true)
        mpvEngine = nil
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
        guard let mpvEngine else { return }
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
    }

    func handlePlayerGeometryChange() {}

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

    func seekRelative(_ seconds: Double) {
        guard mpvEngine != nil, duration > 0 else { return }
        noteInteraction()
        let amount = Int(seconds)
        showFeedback(amount >= 0 ? .seekForward(amount) : .seekBackward(-amount))
        let target = max(0, min(currentTime + seconds, duration))
        scrubPosition = target
        currentTime = target
        Task { [weak self] in
            guard let self, let mpvEngine else { return }
            await mpvEngine.seek(to: target)
            syncMPVState(using: mpvEngine)
        }
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

        do {
            currentPlayback = playback
            selectedQualityOptionID = QualityOption.automaticID
            mpvStateTask?.cancel()
            scheduleMPVStop(mpvEngine, pauseFirst: true)
            mpvEngine = nil

            guard let selection = automaticStartupMPVSelection(for: playback) else {
                PlaybackDebugLogger.log(
                    "prepare playback missing startup source id=\(playback.id) streams=\(playback.streams.count)"
                )
                throw URLError(.badURL)
            }

            let request = try mpvRequest(for: selection)
            PlaybackDebugLogger.log(
                "prepare playback start id=\(playback.id) video=\(debugDescription(for: selection.stream)) audio=\(debugDescription(for: selection.audioStream))"
            )

            let engine = MPVPlaybackEngine(request: request)
            mpvEngine = engine

            try await engine.prepare(startTime: 0, autoPlay: false)
            guard !Task.isCancelled else { return }
            engine.setVolume(volume)
            engine.play()

            currentTime = 0
            scrubPosition = 0
            duration = 0
            startPollingMPVState(using: engine)
            refreshQualityOptions(for: playback)
            loadSubtitleTracks(for: playback, engine: engine)
            if let optionID = manualQualityOptionID(for: selection) {
                selectedQualityOptionID = optionID
            }
            startHideMonitorIfNeeded()
        } catch {
            if !Task.isCancelled {
                PlaybackDebugLogger.log(
                    "prepare playback failed id=\(playback.id) error=\(error.localizedDescription)"
                )
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
                mpvEngine = engine

                try await engine.prepare(startTime: 0, autoPlay: false)
                guard !Task.isCancelled else { return }
                engine.setVolume(volume)
                engine.play()

                currentTime = 0
                scrubPosition = 0
                duration = 0
                pendingQualityOptionID = nil
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
    }

    @objc private func handleWindowDidExitFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        withAnimation(.snappy(duration: 0.16, extraBounce: 0)) {
            layoutState.isFullscreen = false
        }
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

    private func currentRestoreState() -> PlaybackRestoreState {
        PlaybackRestoreState(
            currentTime: sanitizeSeconds(currentTime),
            wasPlaying: isPlaying
        )
    }

    private func seekToScrubPosition() {
        Task { [weak self] in
            guard let self, let mpvEngine else { return }
            let target = min(scrubPosition, scrubberUpperBound)
            await mpvEngine.seek(to: target)
            syncMPVState(using: mpvEngine)
            currentTime = target
            scrubPosition = target
            if isHoveringStage {
                startHideMonitorIfNeeded()
            } else {
                hideControlsIfAllowed()
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
        let snapshot = engine.snapshot()
        currentTime = sanitizeSeconds(snapshot.currentTime)
        if !isScrubbing {
            scrubPosition = currentTime
        }
        if snapshot.duration > 0 {
            duration = sanitizeSeconds(snapshot.duration)
        }
        isPlaying = snapshot.isPlaying
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
            return track.language.hasPrefix("en")
        }

        subtitleOptions = filtered.enumerated().map { index, track in
            let suffix = track.isAutoGenerated ? " (auto)" : ""
            return SubtitleOption(
                id: "subtitle-\(index)-\(track.language)",
                title: "\(track.label)\(suffix)",
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
}
