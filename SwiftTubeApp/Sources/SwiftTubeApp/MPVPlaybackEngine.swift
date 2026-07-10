import AppKit
import Foundation
import Libmpv

struct MPVPlaybackSnapshot {
    let currentTime: Double
    let duration: Double
    let isPlaying: Bool
    let isBuffering: Bool
    let liveSeekableRange: ClosedRange<Double>?
    let bufferedRanges: [ClosedRange<Double>]
    let adaptiveTelemetry: AdaptivePlaybackTelemetry?
}

private struct MPVDemuxerCacheDetails {
    let seekableRanges: [ClosedRange<Double>]
    let rawInputRateBytesPerSecond: Int64?
    let cacheDuration: Double?
    let cacheEnd: Double?
    let isUnderrun: Bool
}

@MainActor
final class MPVPlaybackEngine: NSObject {
    private static let initialLoadTimeoutSeconds: TimeInterval = 12
    let id = UUID()

    let renderController = MPVRenderViewController()
    private let request: MPVPlaybackRequest
    private let mpvLibrary: MPVLibrary
    private var mpv: OpaquePointer?
    private var didLoadFile = false
    private var isStopping = false
    private var loadWaitTask: Task<Void, Error>?
    private var eventPumpTask: Task<Void, Never>?
    var onPlaybackEnded: (() -> Void)?

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var videoAspect: Double = 16.0 / 9.0
    private(set) var liveSeekableRange: ClosedRange<Double>? = nil
    private(set) var bufferedRanges: [ClosedRange<Double>] = []
    private(set) var adaptiveTelemetry: AdaptivePlaybackTelemetry? = nil

    init(request: MPVPlaybackRequest) {
        self.request = request
        self.mpvLibrary = MPVLibrary.load()
        super.init()
    }

    func prepare(startTime: Double, autoPlay: Bool) async throws {
        PlaybackDebugLogger.log(
            "mpv prepare start video=\(request.video.url.absoluteString) audio=\(request.audio?.url.absoluteString ?? "nil") startTime=\(startTime) autoPlay=\(autoPlay)"
        )
        let layer = try await renderController.waitForDisplayReady()
        PlaybackDebugLogger.log(
            "mpv render surface ready \(renderController.renderSurfaceDescription())"
        )
        let handle = try initializeIfNeeded(layer: layer)
        didLoadFile = false
        setPaused(true)
        try clearAuxiliaryAudioOption()
        try command(["loadfile", request.video.url.absoluteString, "replace", "-1"])
        let loadWaitTask = makeFileLoadedTask(for: handle)
        self.loadWaitTask = loadWaitTask
        try await waitForLoadTask(
            loadWaitTask,
            timeout: Self.initialLoadTimeoutSeconds,
            context: "initial"
        )
        self.loadWaitTask = nil
        didLoadFile = true
        try await attachAuxiliaryAudioIfNeeded(request.audio, handle: handle)
        startEventPump(using: handle)

        if startTime > 0 {
            await seek(to: startTime)
        }

        if autoPlay {
            play()
        } else {
            pause()
        }

        updateCachedState()
        PlaybackDebugLogger.log(
            "mpv prepare ready duration=\(duration) currentTime=\(currentTime) isPlaying=\(isPlaying) " +
            "isBuffering=\(isBuffering) liveRange=\(debugDescription(for: liveSeekableRange))"
        )
    }

    func play() {
        PlaybackDebugLogger.log("mpv play")
        setPaused(false)
        isPlaying = true
    }

    func pause() {
        PlaybackDebugLogger.log("mpv pause")
        setPaused(true)
        isPlaying = false
    }

    func stop() {
        Task { [weak self] in
            await self?.stopSafely()
        }
    }

    func seek(to seconds: Double) async {
        let targetTime = max(seconds, 0)
        currentTime = targetTime
        do {
            try command(["seek", String(targetTime), "absolute", "exact"])
            await waitForSeekPosition(targetTime, timeout: 1.5)
            updateCachedState()
            PlaybackDebugLogger.log(
                "mpv seek applied currentTime=\(currentTime) duration=\(duration) liveRange=\(debugDescription(for: liveSeekableRange))"
            )
        } catch {
            return
        }
    }


    func setVolume(_ volume: Double) {
        guard let mpv else { return }
        var clampedVolume = max(0, min(volume, 1)) * 100
        _ = mpvLibrary.setProperty(mpv, MPVProperty.volume, MPV_FORMAT_DOUBLE, &clampedVolume)
    }

    func setRate(_ rate: Double) {
        guard let mpv else { return }
        var playbackRate = max(rate, 0.25)
        _ = mpvLibrary.setProperty(mpv, MPVProperty.speed, MPV_FORMAT_DOUBLE, &playbackRate)
    }

    func snapshot() -> MPVPlaybackSnapshot {
        updateCachedState()
        return MPVPlaybackSnapshot(
            currentTime: currentTime,
            duration: duration,
            isPlaying: isPlaying,
            isBuffering: isBuffering,
            liveSeekableRange: liveSeekableRange,
            bufferedRanges: bufferedRanges,
            adaptiveTelemetry: adaptiveTelemetry
        )
    }

    func setAdaptiveRendition(id: Int64) throws {
        guard let mpv else {
            throw NSError(domain: "SwiftTube.MPV", code: -2, userInfo: [NSLocalizedDescriptionKey: "mpv is not initialized."])
        }
        var value = id
        PlaybackDebugLogger.log("mpv set adaptive vid=\(id)")
        try check(mpvLibrary.setProperty(mpv, MPVProperty.videoTrackID, MPV_FORMAT_INT64, &value))
        updateCachedState()
    }

    func replaceFile(with newRequest: MPVPlaybackRequest, seekTo time: Double) async throws {
        guard let mpv else {
            throw NSError(domain: "SwiftTube.MPV", code: -2, userInfo: [NSLocalizedDescriptionKey: "mpv is not initialized."])
        }

        let shouldResumePlayback = isPlaying
        PlaybackDebugLogger.log(
            "mpv replaceFile start video=\(newRequest.video.url.absoluteString) audio=\(newRequest.audio?.url.absoluteString ?? "nil") seekTo=\(time)"
        )

        let previousEventPump = eventPumpTask
        eventPumpTask = nil
        previousEventPump?.cancel()
        mpvLibrary.wakeup(mpv)
        _ = await previousEventPump?.result

        didLoadFile = false
        setPaused(true)
        isPlaying = false
        try applyNetworkOptions(for: newRequest.video)
        try clearAuxiliaryAudioOption()
        try command(["loadfile", newRequest.video.url.absoluteString, "replace"])

        let loadWaitTask = makeFileLoadedTask(for: mpv, isReplace: true)
        self.loadWaitTask = loadWaitTask
        try await waitForLoadTask(
            loadWaitTask,
            timeout: Self.initialLoadTimeoutSeconds,
            context: "replace"
        )
        self.loadWaitTask = nil
        didLoadFile = true
        try await attachAuxiliaryAudioIfNeeded(newRequest.audio, handle: mpv)

        startEventPump(using: mpv)

        if time > 0 {
            await seek(to: time)
        }

        setPaused(!shouldResumePlayback)
        isPlaying = shouldResumePlayback

        updateCachedState()
        PlaybackDebugLogger.log(
            "mpv replaceFile ready duration=\(duration) currentTime=\(currentTime) isPlaying=\(isPlaying) " +
            "liveRange=\(debugDescription(for: liveSeekableRange))"
        )
    }

    func addSubtitle(url: String) {
        do {
            try command(["sub-add", url, "select"])
            PlaybackDebugLogger.log("mpv sub-add url=\(url)")
        } catch {
            PlaybackDebugLogger.log("mpv sub-add failed url=\(url) error=\(error.localizedDescription)")
        }
    }

    func setSubtitleTrack(_ trackID: Int) {
        guard let mpv else { return }
        var value = Int64(trackID)
        _ = mpvLibrary.setProperty(mpv, "sid", MPV_FORMAT_INT64, &value)
        PlaybackDebugLogger.log("mpv set sid=\(trackID)")
    }

    func setSubtitleVisibility(_ visible: Bool) {
        guard let mpv else { return }
        var value: Int32 = visible ? 1 : 0
        _ = mpvLibrary.setProperty(mpv, "sub-visibility", MPV_FORMAT_FLAG, &value)
    }

    func stepFrame(direction: Int) {
        guard mpv != nil, didLoadFile else { return }
        do {
            if direction >= 0 {
                try command(["frame-step"])
            } else {
                try command(["frame-back-step"])
            }
            updateCachedState()
        } catch {}
    }

    /// Reloads the current video file at the given seek position.
    /// This is the same path used by quality switching and is the only reliable
    /// way to force moltenvk_reconfig to run with the correct drawableSize, since
    /// file load always calls vo_reconfig2 → moltenvk_reconfig fresh.
    func reloadCurrentFile(seekTo time: Double) async throws {
        try await replaceFile(with: request, seekTo: time)
    }

    func refreshPausedFrame(at time: Double) throws {
        guard didLoadFile else {
            throw NSError(
                domain: "SwiftTube.MPV",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "mpv file is not loaded yet."]
            )
        }

        let resolvedTime = max(time, 0)
        PlaybackDebugLogger.log("mpv refresh paused frame time=\(resolvedTime)")
        try command(["seek", String(resolvedTime), "absolute", "exact"])
        updateCachedState()
    }

    func stopSafely() async {
        guard isStopping == false else { return }
        isStopping = true
        isPlaying = false
        await destroyPlayer()
        isStopping = false
    }
}

private extension MPVPlaybackEngine {
    func initializeIfNeeded(layer: MPVMetalLayer) throws -> OpaquePointer {
        if let mpv {
            return mpv
        }
        guard let handle = mpvLibrary.create() else {
            throw NSError(domain: "SwiftTube.MPV", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create mpv context."])
        }

        mpv = handle
        try check(mpvLibrary.requestLogMessages(handle, "no"))
        PlaybackDebugLogger.log(
            "mpv initialize source=\(mpvLibrary.sourceDescription) videoHeaders=\(request.video.headers.keys.sorted()) audioHeaders=\(request.audio?.headers.keys.sorted() ?? []) logPath=\(PlaybackDebugLogger.path)"
        )

        try setOption("vo", value: "gpu-next")
        try setOption("gpu-api", value: "vulkan")
        try setOption("gpu-context", value: "moltenvk")
        try setOption("hwdec", value: "auto-safe")
        try setOption("hwdec-software-fallback", value: "1")
        // Keep the tempo filter permanently attached so temporary speed changes
        // do not trigger audible/video-sync hiccups when returning to 1x while
        // still preserving the original pitch.
        try setOption("audio-pitch-correction", value: "yes")
        try setOption("af", value: "scaletempo2")
        try setOption("osc", value: "no")
        try setOption("input-default-bindings", value: "no")
        try setOption("ytdl", value: "no")
        try setOption("sub-auto", value: "no")
        try setOption("audio-file-auto", value: "no")
        if request.mode == .adaptiveManifest {
            try setOption("hls-bitrate", value: "max")
            try setOption("cache", value: "yes")
            try setOption("cache-pause", value: "yes")
        }
        var layerReference = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque())))
        try check(mpvLibrary.setOption(handle, "wid", MPV_FORMAT_INT64, &layerReference))
        PlaybackDebugLogger.log(
            "mpv set option wid=\(layerReference) \(renderController.renderSurfaceDescription())"
        )

        try applyNetworkOptions(for: request.video)

        try check(mpvLibrary.initialize(handle))
        didLoadFile = false
        return handle
    }

    func applyNetworkOptions(for request: MediaStreamRequest) throws {
        let userAgentKeys = ["user-agent"]
        let referrerKeys = ["referer", "referrer"]
        let headers = request.headers

        if let userAgent = value(forAnyOf: userAgentKeys, in: headers) {
            try setOption("user-agent", value: userAgent)
        }

        try setOption("referrer", value: value(forAnyOf: referrerKeys, in: headers) ?? "")

        let reservedKeys = Set(userAgentKeys + referrerKeys)
        try setOption("http-header-fields", value: mpvCustomHeaderFields(from: headers, reservedKeys: reservedKeys))
    }

    func clearAuxiliaryAudioOption() throws {
        try setOption("audio-files", value: "")
    }

    func attachAuxiliaryAudioIfNeeded(_ audio: MediaStreamRequest?, handle: OpaquePointer) async throws {
        guard let audio else { return }

        try applyNetworkOptions(for: audio)
        PlaybackDebugLogger.log("mpv audio-add start url=\(audio.url.absoluteString)")
        try command(["audio-add", audio.url.absoluteString, "select"])
        try await waitForAuxiliaryAudioReady(handle: handle, timeout: 5)
    }

    func waitForAuxiliaryAudioReady(handle: OpaquePointer, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            try Task.checkCancellation()

            let audioTrackID = Self.intProperty(MPVProperty.audioTrackID, from: handle, library: mpvLibrary) ?? 0
            let codec = Self.stringProperty(MPVProperty.audioCodecName, from: handle, library: mpvLibrary)
            let channelCount = Self.intProperty(MPVProperty.audioChannelCount, from: handle, library: mpvLibrary) ?? 0
            if audioTrackID > 0, let codec, !codec.isEmpty, channelCount > 0 {
                let channels = String(channelCount)
                PlaybackDebugLogger.log("mpv audio-add ready aid=\(audioTrackID) codec=\(codec) channels=\(channels)")
                return
            }

            try await Task.sleep(nanoseconds: 100_000_000)
        }

        PlaybackDebugLogger.log("mpv audio-add timed out waiting for aid")
        throw NSError(
            domain: "SwiftTube.MPV",
            code: -13,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for mpv to attach external audio."]
        )
    }

    func waitForSeekPosition(_ targetTime: Double, timeout: TimeInterval) async {
        guard let mpv else { return }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return }

            let observedTime = max(doubleProperty(MPVProperty.timePosition, from: mpv), 0)
            if abs(observedTime - targetTime) <= 0.75 {
                currentTime = observedTime
                return
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        currentTime = max(doubleProperty(MPVProperty.timePosition, from: mpv), 0)
        PlaybackDebugLogger.log("mpv seek wait timed out target=\(targetTime) current=\(currentTime)")
    }

    func destroyPlayer() async {
        guard let mpv else { return }

        let loadWaitTask = self.loadWaitTask
        let eventPumpTask = self.eventPumpTask
        self.loadWaitTask = nil
        self.eventPumpTask = nil

        loadWaitTask?.cancel()
        eventPumpTask?.cancel()
        mpvLibrary.wakeup(mpv)

        if loadWaitTask != nil || eventPumpTask != nil {
            PlaybackDebugLogger.log(
                "mpv stop draining waiters load=\(loadWaitTask != nil) eventPump=\(eventPumpTask != nil)"
            )
        }

        _ = try? await loadWaitTask?.value
        _ = await eventPumpTask?.result

        PlaybackDebugLogger.log("mpv terminate")
        mpvLibrary.terminateDestroy(mpv)
        self.mpv = nil
        didLoadFile = false
    }

    func setOption(_ name: String, value: String) throws {
        guard let mpv else { return }
        PlaybackDebugLogger.log("mpv set option \(name)=\(value)")
        try check(mpvLibrary.setOptionString(mpv, name, value))
    }

    func setPaused(_ paused: Bool) {
        guard let mpv else { return }
        var value: Int32 = paused ? 1 : 0
        _ = mpvLibrary.setProperty(mpv, MPVProperty.pause, MPV_FORMAT_FLAG, &value)
    }

    func waitForLoadTask(
        _ task: Task<Void, Error>,
        timeout: TimeInterval,
        context: String
    ) async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await task.value
                }
                group.addTask {
                    let clampedTimeout = max(timeout, 0)
                    try await Task.sleep(nanoseconds: UInt64(clampedTimeout * 1_000_000_000))
                    throw NSError(
                        domain: "SwiftTube.MPV",
                        code: -12,
                        userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for mpv to \(context)-load media."]
                    )
                }

                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            task.cancel()
            if let mpv {
                mpvLibrary.wakeup(mpv)
            }
            PlaybackDebugLogger.log("mpv load wait failed context=\(context) error=\(error.localizedDescription)")
            throw error
        }
    }

    func check(_ status: Int32) throws {
        guard status >= 0 else {
            let message = mpvLibrary.errorMessage(status)
            PlaybackDebugLogger.log("mpv error status=\(status) message=\(message)")
            throw NSError(domain: "SwiftTube.MPV", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func makeFileLoadedTask(for handle: OpaquePointer, isReplace: Bool = false) -> Task<Void, Error> {
        let handleBits = UInt(bitPattern: handle)
        let mpvLibrary = mpvLibrary

        return Task.detached(priority: .userInitiated) {
            let handle = OpaquePointer(bitPattern: handleBits)!

            while true {
                try Task.checkCancellation()
                guard let event = mpvLibrary.waitEvent(handle, 0.1) else { continue }
                let eventName = mpvLibrary.eventNameString(event.pointee.event_id)

                switch event.pointee.event_id {
                case MPV_EVENT_FILE_LOADED:
                    PlaybackDebugLogger.log("mpv event \(eventName)")
                    return
                case MPV_EVENT_SHUTDOWN:
                    PlaybackDebugLogger.log("mpv event \(eventName)")
                    throw NSError(domain: "SwiftTube.MPV", code: -10, userInfo: [NSLocalizedDescriptionKey: "mpv shut down during load."])
                case MPV_EVENT_END_FILE:
                    if let endFile = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self) {
                        let endReason = endFile.pointee.reason
                        let endError = endFile.pointee.error
                        let endErrorMessage = mpvLibrary.errorMessage(endError)
                        PlaybackDebugLogger.log(
                            "mpv event \(eventName) reason=\(endReason) error=\(endError) message=\(endErrorMessage) isReplace=\(isReplace)"
                        )
                        if isReplace && endError == 0 {
                            continue
                        }
                        throw NSError(
                            domain: "SwiftTube.MPV",
                            code: Int(endError != 0 ? endError : -11),
                            userInfo: [NSLocalizedDescriptionKey: "mpv ended the file before it became ready. reason=\(endReason) error=\(endErrorMessage)"]
                        )
                    }
                    PlaybackDebugLogger.log("mpv event \(eventName) isReplace=\(isReplace)")
                    if isReplace { continue }
                    throw NSError(domain: "SwiftTube.MPV", code: -11, userInfo: [NSLocalizedDescriptionKey: "mpv ended the file before it became ready."])
                case MPV_EVENT_LOG_MESSAGE:
                    if let logMessage = event.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self) {
                        let prefix = String(cString: logMessage.pointee.prefix)
                        let level = String(cString: logMessage.pointee.level)
                        let text = String(cString: logMessage.pointee.text).trimmingCharacters(in: .whitespacesAndNewlines)
                        if Self.shouldLogMPVMessage(prefix: prefix, level: level) {
                            PlaybackDebugLogger.log("mpv log [\(prefix)] [\(level)] \(text)")
                        }
                    }
                default:
                    continue
                }
            }
        }
    }

    func updateCachedState() {
        guard let mpv, didLoadFile else { return }

        currentTime = max(doubleProperty(MPVProperty.timePosition, from: mpv), 0)
        duration = max(doubleProperty(MPVProperty.duration, from: mpv), 0)
        isBuffering = flagProperty(MPVProperty.pausedForCache, from: mpv)
        isPlaying = flagProperty(MPVProperty.pause, from: mpv) == false
        let cacheDetails = demuxerCacheDetailsProperty(MPVProperty.demuxerCacheState, from: mpv)
        bufferedRanges = cacheDetails.seekableRanges
        liveSeekableRange = Self.resolveSeekableRange(from: cacheDetails.seekableRanges, currentTime: currentTime)
        let aspect = doubleProperty("video-params/aspect", from: mpv)
        if aspect > 0 { videoAspect = aspect }
        adaptiveTelemetry = adaptiveTelemetry(from: mpv, cacheDetails: cacheDetails)
    }

    func doubleProperty(_ name: String, from handle: OpaquePointer) -> Double {
        var value = 0.0
        let result = mpvLibrary.getProperty(handle, name, MPV_FORMAT_DOUBLE, &value)
        guard result >= 0, value.isFinite else { return 0 }
        return value
    }

    func flagProperty(_ name: String, from handle: OpaquePointer) -> Bool {
        var value: Int32 = 0
        let result = mpvLibrary.getProperty(handle, name, MPV_FORMAT_FLAG, &value)
        guard result >= 0 else { return false }
        return value != 0
    }

    func seekableRangesProperty(_ name: String, from handle: OpaquePointer) -> [ClosedRange<Double>] {
        demuxerCacheDetailsProperty(name, from: handle).seekableRanges
    }

    func demuxerCacheDetailsProperty(_ name: String, from handle: OpaquePointer) -> MPVDemuxerCacheDetails {
        var value = mpv_node()
        let result = mpvLibrary.getProperty(handle, name, MPV_FORMAT_NODE, &value)
        guard result >= 0 else {
            return MPVDemuxerCacheDetails(
                seekableRanges: [],
                rawInputRateBytesPerSecond: nil,
                cacheDuration: nil,
                cacheEnd: nil,
                isUnderrun: false
            )
        }
        defer { mpvLibrary.freeNodeContents(&value) }

        let seekableRanges = Self.seekableRanges(from: value)
        let rawInputRate = Self.intValue(forKey: "raw-input-rate", in: value)
        let cacheDuration = Self.doubleValue(forKey: "cache-duration", in: value)
        let cacheEnd = Self.doubleValue(forKey: "cache-end", in: value)
        let isUnderrun = Self.flagValue(forKey: "underrun", in: value) ?? false

        return MPVDemuxerCacheDetails(
            seekableRanges: seekableRanges,
            rawInputRateBytesPerSecond: rawInputRate,
            cacheDuration: cacheDuration,
            cacheEnd: cacheEnd,
            isUnderrun: isUnderrun
        )
    }

    func adaptiveTelemetry(
        from handle: OpaquePointer,
        cacheDetails: MPVDemuxerCacheDetails
    ) -> AdaptivePlaybackTelemetry? {
        guard request.mode == .adaptiveManifest else { return nil }

        let renditions = adaptiveRenditionsProperty(MPVProperty.trackList, from: handle)
        guard renditions.isEmpty == false else { return nil }

        let selectedID = renditions.first(where: { $0.selected })?.id
            ?? Self.intProperty(MPVProperty.videoTrackID, from: handle, library: mpvLibrary)
        let bufferAheadFromEnd = cacheDetails.cacheEnd.map { max($0 - currentTime, 0) } ?? 0
        let bufferAhead = max(cacheDetails.cacheDuration ?? 0, bufferAheadFromEnd)

        return AdaptivePlaybackTelemetry(
            renditions: renditions,
            selectedRenditionID: selectedID,
            rawInputRateBytesPerSecond: cacheDetails.rawInputRateBytesPerSecond,
            cacheDuration: cacheDetails.cacheDuration,
            cacheEnd: cacheDetails.cacheEnd,
            bufferAheadSeconds: bufferAhead,
            isPausedForCache: isBuffering,
            cacheBufferingState: doubleProperty(MPVProperty.cacheBufferingState, from: handle),
            isUnderrun: cacheDetails.isUnderrun
        )
    }

    func adaptiveRenditionsProperty(_ name: String, from handle: OpaquePointer) -> [AdaptiveRendition] {
        var value = mpv_node()
        let result = mpvLibrary.getProperty(handle, name, MPV_FORMAT_NODE, &value)
        guard result >= 0 else { return [] }
        defer { mpvLibrary.freeNodeContents(&value) }
        guard value.format == MPV_FORMAT_NODE_ARRAY,
              let list = value.u.list,
              let values = list.pointee.values else {
            return []
        }

        let count = Int(list.pointee.num)
        guard count > 0 else { return [] }

        var renditions: [AdaptiveRendition] = []
        renditions.reserveCapacity(count)

        for index in 0..<count {
            let node = values[index]
            guard Self.stringValue(forKey: "type", in: node) == "video",
                  Self.flagValue(forKey: "image", in: node) != true,
                  Self.flagValue(forKey: "albumart", in: node) != true,
                  let id = Self.intValue(forKey: "id", in: node) else {
                continue
            }

            let bitrate = Self.intValue(forKey: "hls-bitrate", in: node)
                .map(Int.init)
                ?? Self.intValue(forKey: "demux-bitrate", in: node).map(Int.init)
            let height = Self.intValue(forKey: "demux-h", in: node).map(Int.init)
            let width = Self.intValue(forKey: "demux-w", in: node).map(Int.init)
            let fps = Self.doubleValue(forKey: "demux-fps", in: node)
            guard (bitrate ?? 0) > 0 || (height ?? 0) > 0 else { continue }

            renditions.append(
                AdaptiveRendition(
                    id: id,
                    width: width,
                    height: height,
                    fps: fps,
                    bitrate: bitrate,
                    codec: Self.stringValue(forKey: "codec", in: node),
                    selected: Self.flagValue(forKey: "selected", in: node) ?? false
                )
            )
        }

        return renditions.sorted {
            ($0.effectiveHeight, $0.effectiveBitrate, $0.id) < ($1.effectiveHeight, $1.effectiveBitrate, $1.id)
        }
    }

    nonisolated static func intProperty(_ name: String, from handle: OpaquePointer, library: MPVLibrary) -> Int64? {
        var value: Int64 = 0
        let result = library.getProperty(handle, name, MPV_FORMAT_INT64, &value)
        guard result >= 0 else { return nil }
        return value
    }

    nonisolated static func stringProperty(_ name: String, from handle: OpaquePointer, library: MPVLibrary) -> String? {
        guard let cString = library.getPropertyString(handle, name) else {
            return nil
        }
        defer { library.free(cString) }
        return String(cString: cString)
    }

    nonisolated static func mapValue(forKey key: String, in node: mpv_node) -> mpv_node? {
        guard node.format == MPV_FORMAT_NODE_MAP,
              let list = node.u.list,
              let keys = list.pointee.keys,
              let values = list.pointee.values else {
            return nil
        }

        let count = Int(list.pointee.num)
        guard count > 0 else { return nil }

        for index in 0..<count {
            guard let rawKey = keys[index], String(cString: rawKey) == key else { continue }
            return values[index]
        }

        return nil
    }

    nonisolated static func numericValue(from node: mpv_node) -> Double? {
        switch node.format {
        case MPV_FORMAT_DOUBLE:
            return node.u.double_.isFinite ? node.u.double_ : nil
        case MPV_FORMAT_INT64:
            return Double(node.u.int64)
        case MPV_FORMAT_FLAG:
            return node.u.flag != 0 ? 1 : 0
        default:
            return nil
        }
    }

    nonisolated static func intValue(from node: mpv_node) -> Int64? {
        switch node.format {
        case MPV_FORMAT_INT64:
            return node.u.int64
        case MPV_FORMAT_DOUBLE:
            guard node.u.double_.isFinite else { return nil }
            return Int64(node.u.double_)
        default:
            return nil
        }
    }

    nonisolated static func stringValue(from node: mpv_node) -> String? {
        guard node.format == MPV_FORMAT_STRING,
              let string = node.u.string else {
            return nil
        }
        return String(cString: string)
    }

    nonisolated static func flagValue(from node: mpv_node) -> Bool? {
        guard node.format == MPV_FORMAT_FLAG else { return nil }
        return node.u.flag != 0
    }

    nonisolated static func intValue(forKey key: String, in node: mpv_node) -> Int64? {
        guard let value = mapValue(forKey: key, in: node) else { return nil }
        return intValue(from: value)
    }

    nonisolated static func doubleValue(forKey key: String, in node: mpv_node) -> Double? {
        guard let value = mapValue(forKey: key, in: node) else { return nil }
        return numericValue(from: value)
    }

    nonisolated static func stringValue(forKey key: String, in node: mpv_node) -> String? {
        guard let value = mapValue(forKey: key, in: node) else { return nil }
        return stringValue(from: value)
    }

    nonisolated static func flagValue(forKey key: String, in node: mpv_node) -> Bool? {
        guard let value = mapValue(forKey: key, in: node) else { return nil }
        return flagValue(from: value)
    }

    nonisolated static func seekableRanges(from node: mpv_node) -> [ClosedRange<Double>] {
        guard let rangesNode = mapValue(forKey: "seekable-ranges", in: node),
              rangesNode.format == MPV_FORMAT_NODE_ARRAY,
              let list = rangesNode.u.list,
              let values = list.pointee.values else {
            return []
        }

        let count = Int(list.pointee.num)
        guard count > 0 else { return [] }

        var ranges: [ClosedRange<Double>] = []
        ranges.reserveCapacity(count)

        for index in 0..<count {
            guard let range = seekableRange(from: values[index]) else { continue }
            ranges.append(range)
        }

        return ranges
    }

    nonisolated static func seekableRange(from node: mpv_node) -> ClosedRange<Double>? {
        guard let startNode = mapValue(forKey: "start", in: node),
              let endNode = mapValue(forKey: "end", in: node),
              let start = numericValue(from: startNode),
              let end = numericValue(from: endNode),
              start.isFinite,
              end.isFinite,
              end > start else {
            return nil
        }

        return start...end
    }

    nonisolated static func resolveSeekableRange(
        from ranges: [ClosedRange<Double>],
        currentTime: Double
    ) -> ClosedRange<Double>? {
        guard ranges.isEmpty == false else { return nil }

        let matchingRanges = ranges.filter { range in
            range.contains(currentTime)
                || abs(range.lowerBound - currentTime) <= 0.5
                || abs(range.upperBound - currentTime) <= 0.5
        }

        if let range = matchingRanges.max(by: { $0.upperBound < $1.upperBound }) {
            return range
        }

        return ranges.max(by: { $0.upperBound < $1.upperBound })
    }

    func debugDescription(for range: ClosedRange<Double>?) -> String {
        guard let range else { return "nil" }
        return "\(range.lowerBound)...\(range.upperBound)"
    }

    func startEventPump(using handle: OpaquePointer) {
        guard eventPumpTask == nil else { return }
        let handleBits = UInt(bitPattern: handle)
        let mpvLibrary = mpvLibrary
        eventPumpTask = Task.detached(priority: .userInitiated) { [weak self, mpvLibrary] in
            let handle = OpaquePointer(bitPattern: handleBits)!

            while Task.isCancelled == false {
                guard let event = mpvLibrary.waitEvent(handle, 0.1) else { continue }
                switch event.pointee.event_id {
                case MPV_EVENT_NONE:
                    continue
                case MPV_EVENT_LOG_MESSAGE:
                    guard let logMessage = event.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self) else {
                        continue
                    }
                    let prefix = String(cString: logMessage.pointee.prefix)
                    let level = String(cString: logMessage.pointee.level)
                    let text = String(cString: logMessage.pointee.text).trimmingCharacters(in: .whitespacesAndNewlines)
                    if MPVPlaybackEngine.shouldLogMPVMessage(prefix: prefix, level: level) {
                        PlaybackDebugLogger.log("mpv log [\(prefix)] [\(level)] \(text)")
                    }
                case MPV_EVENT_END_FILE:
                    if let endFile = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self) {
                        let endReason = endFile.pointee.reason
                        let endError = endFile.pointee.error
                        let endErrorMessage = mpvLibrary.errorMessage(endError)
                        PlaybackDebugLogger.log(
                            "mpv event end-file reason=\(endReason) error=\(endError) message=\(endErrorMessage)"
                        )
                        if endReason == MPV_END_FILE_REASON_EOF {
                            Task { @MainActor [weak self] in
                                self?.isPlaying = false
                                self?.onPlaybackEnded?()
                            }
                        }
                    } else {
                        PlaybackDebugLogger.log("mpv event end-file")
                    }
                case MPV_EVENT_SHUTDOWN:
                    PlaybackDebugLogger.log("mpv event shutdown")
                    return
                default:
                    continue
                }
            }

            PlaybackDebugLogger.log("mpv event pump cancelled")
        }
    }

    func command(_ arguments: [String]) throws {
        guard let mpv else {
            throw NSError(domain: "SwiftTube.MPV", code: -2, userInfo: [NSLocalizedDescriptionKey: "mpv is not initialized."])
        }
        PlaybackDebugLogger.log("mpv command \(arguments)")

        var cArguments = arguments.map { argument -> UnsafePointer<CChar>? in
            guard let duplicated = strdup(argument) else { return nil }
            return UnsafePointer(duplicated)
        }
        cArguments.append(nil)
        defer {
            cArguments.forEach { pointer in
                free(UnsafeMutablePointer(mutating: pointer))
            }
        }

        try cArguments.withUnsafeMutableBufferPointer { buffer in
            try check(mpvLibrary.command(mpv, buffer.baseAddress))
        }
    }

    func value(forAnyOf candidateKeys: [String], in headers: [String: String]) -> String? {
        let loweredHeaders = Dictionary(
            uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) }
        )
        return candidateKeys.compactMap { loweredHeaders[$0] }.first
    }

    func mpvCustomHeaderFields(from headers: [String: String], reservedKeys: Set<String>) -> String {
        let loweredHeaders = Dictionary(
            uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) }
        )
        let allowedKeys: Set<String> = [
            "origin"
        ]

        let safeEntries = loweredHeaders
            .filter { key, value in
                guard reservedKeys.contains(key) == false else { return false }
                guard allowedKeys.contains(key) else { return false }
                return value.contains(",") == false
                    && value.contains("\r") == false
                    && value.contains("\n") == false
            }
            .sorted { $0.key < $1.key }

        let skippedKeys = loweredHeaders.keys
            .filter { reservedKeys.contains($0) == false && allowedKeys.contains($0) == false }
            .sorted()

        if skippedKeys.isEmpty == false {
            PlaybackDebugLogger.log("mpv skip custom headers keys=\(skippedKeys)")
        }

        return safeEntries
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ",")
    }

    nonisolated static func shouldLogMPVMessage(prefix: String, level: String) -> Bool {
        if level == "error" || level == "warn" {
            return true
        }

        let noisyPrefixes: Set<String> = [
            "ffmpeg",
            "stream",
            "demux",
            "cache",
            "cplayer",
            "vo",
            "gpu",
            "vulkan",
            "vd",
            "ad"
        ]
        return noisyPrefixes.contains(prefix)
    }

}
