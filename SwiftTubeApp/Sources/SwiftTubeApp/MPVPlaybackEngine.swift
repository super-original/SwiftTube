import AppKit
import Foundation
import Libmpv

@MainActor
final class MPVPlaybackEngine: NSObject {
    let id = UUID()

    let renderController = MPVRenderViewController()
    private let request: MPVPlaybackRequest
    private var mpv: OpaquePointer?
    private var didLoadFile = false
    private var isStopping = false
    private var loadWaitTask: Task<Void, Error>?
    private var audioReadyTask: Task<Void, Never>?
    private var eventPumpTask: Task<Void, Never>?

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var videoAspect: Double = 16.0 / 9.0

    init(request: MPVPlaybackRequest) {
        self.request = request
        super.init()
    }

    func prepare(startTime: Double, autoPlay: Bool) async throws {
        PlaybackDebugLogger.log(
            "mpv prepare start video=\(request.video.url.absoluteString) audio=\(request.audio?.url.absoluteString ?? "nil") startTime=\(startTime) autoPlay=\(autoPlay)"
        )
        let layer = await renderController.waitForDisplayReady()
        PlaybackDebugLogger.log(
            "mpv render surface ready \(renderController.renderSurfaceDescription())"
        )
        let handle = try initializeIfNeeded(layer: layer)
        didLoadFile = false
        try command(["loadfile", request.video.url.absoluteString, "replace", "-1"])
        let loadWaitTask = makeFileLoadedTask(for: handle)
        self.loadWaitTask = loadWaitTask
        try await loadWaitTask.value
        self.loadWaitTask = nil
        didLoadFile = true
        if let audio = request.audio {
            let audioReadyTask = makeAudioReadyTask(for: audio, handle: handle)
            self.audioReadyTask = audioReadyTask
            await audioReadyTask.value
            self.audioReadyTask = nil
        }
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
            "mpv prepare ready duration=\(duration) currentTime=\(currentTime) isPlaying=\(isPlaying) isBuffering=\(isBuffering)"
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
        currentTime = max(seconds, 0)
        do {
            try command(["seek", String(currentTime), "absolute", "exact"])
            updateCachedState()
            PlaybackDebugLogger.log("mpv seek applied currentTime=\(currentTime) duration=\(duration)")
        } catch {
            return
        }
    }

    func setVolume(_ volume: Double) {
        guard let mpv else { return }
        var clampedVolume = max(0, min(volume, 1)) * 100
        mpv_set_property(mpv, MPVProperty.volume, MPV_FORMAT_DOUBLE, &clampedVolume)
    }

    func snapshot() -> (currentTime: Double, duration: Double, isPlaying: Bool, isBuffering: Bool) {
        updateCachedState()
        return (currentTime, duration, isPlaying, isBuffering)
    }

    func replaceFile(with newRequest: MPVPlaybackRequest, seekTo time: Double) async throws {
        guard let mpv else {
            throw NSError(domain: "SwiftTube.MPV", code: -2, userInfo: [NSLocalizedDescriptionKey: "mpv is not initialized."])
        }

        PlaybackDebugLogger.log(
            "mpv replaceFile start video=\(newRequest.video.url.absoluteString) audio=\(newRequest.audio?.url.absoluteString ?? "nil") seekTo=\(time)"
        )

        let previousEventPump = eventPumpTask
        eventPumpTask = nil
        previousEventPump?.cancel()
        mpv_wakeup(mpv)
        _ = await previousEventPump?.result

        didLoadFile = false
        try command(["loadfile", newRequest.video.url.absoluteString, "replace"])

        let loadWaitTask = makeFileLoadedTask(for: mpv, isReplace: true)
        self.loadWaitTask = loadWaitTask
        try await loadWaitTask.value
        self.loadWaitTask = nil
        didLoadFile = true

        if let audio = newRequest.audio {
            let audioReadyTask = makeAudioReadyTask(for: audio, handle: mpv)
            self.audioReadyTask = audioReadyTask
            await audioReadyTask.value
            self.audioReadyTask = nil
        }

        startEventPump(using: mpv)

        if time > 0 {
            await seek(to: time)
        }

        updateCachedState()
        PlaybackDebugLogger.log(
            "mpv replaceFile ready duration=\(duration) currentTime=\(currentTime) isPlaying=\(isPlaying)"
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
        mpv_set_property(mpv, "sid", MPV_FORMAT_INT64, &value)
        PlaybackDebugLogger.log("mpv set sid=\(trackID)")
    }

    func setSubtitleVisibility(_ visible: Bool) {
        guard let mpv else { return }
        var value: Int32 = visible ? 1 : 0
        mpv_set_property(mpv, "sub-visibility", MPV_FORMAT_FLAG, &value)
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
        guard let handle = mpv_create() else {
            throw NSError(domain: "SwiftTube.MPV", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create mpv context."])
        }

        mpv = handle
        try check(mpv_request_log_messages(handle, "debug"))
        PlaybackDebugLogger.log(
            "mpv initialize videoHeaders=\(request.video.headers.keys.sorted()) audioHeaders=\(request.audio?.headers.keys.sorted() ?? []) logPath=\(PlaybackDebugLogger.path)"
        )

        try setOption("vo", value: "gpu-next")
        try setOption("gpu-api", value: "vulkan")
        try setOption("gpu-context", value: "moltenvk")
        try setOption("hwdec", value: "auto-safe")
        try setOption("hwdec-software-fallback", value: "1")
        try setOption("osc", value: "no")
        try setOption("input-default-bindings", value: "no")
        try setOption("ytdl", value: "no")
        try setOption("sub-auto", value: "no")
        try setOption("audio-file-auto", value: "no")
        var layerReference = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque())))
        try check(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &layerReference))
        PlaybackDebugLogger.log(
            "mpv set option wid=\(layerReference) \(renderController.renderSurfaceDescription())"
        )

        let userAgentKeys = ["user-agent"]
        let referrerKeys = ["referer", "referrer"]
        let headers = request.video.headers

        if let userAgent = value(forAnyOf: userAgentKeys, in: headers) {
            try setOption("user-agent", value: userAgent)
        }

        if let referrer = value(forAnyOf: referrerKeys, in: headers) {
            try setOption("referrer", value: referrer)
        }

        let reservedKeys = Set(userAgentKeys + referrerKeys)
        let headerFields = mpvCustomHeaderFields(from: headers, reservedKeys: reservedKeys)

        if headerFields.isEmpty == false {
            try setOption("http-header-fields", value: headerFields)
        }

        try check(mpv_initialize(handle))
        didLoadFile = false
        return handle
    }

    func destroyPlayer() async {
        guard let mpv else { return }

        let loadWaitTask = self.loadWaitTask
        let audioReadyTask = self.audioReadyTask
        let eventPumpTask = self.eventPumpTask
        self.loadWaitTask = nil
        self.audioReadyTask = nil
        self.eventPumpTask = nil

        loadWaitTask?.cancel()
        audioReadyTask?.cancel()
        eventPumpTask?.cancel()
        mpv_wakeup(mpv)

        if loadWaitTask != nil || audioReadyTask != nil || eventPumpTask != nil {
            PlaybackDebugLogger.log(
                "mpv stop draining waiters load=\(loadWaitTask != nil) audio=\(audioReadyTask != nil) eventPump=\(eventPumpTask != nil)"
            )
        }

        _ = try? await loadWaitTask?.value
        _ = await audioReadyTask?.result
        _ = await eventPumpTask?.result

        PlaybackDebugLogger.log("mpv terminate")
        mpv_terminate_destroy(mpv)
        self.mpv = nil
        didLoadFile = false
    }

    func setOption(_ name: String, value: String) throws {
        guard let mpv else { return }
        PlaybackDebugLogger.log("mpv set option \(name)=\(value)")
        try check(mpv_set_option_string(mpv, name, value))
    }

    func setPaused(_ paused: Bool) {
        guard let mpv else { return }
        var value: Int32 = paused ? 1 : 0
        mpv_set_property(mpv, MPVProperty.pause, MPV_FORMAT_FLAG, &value)
    }

    func check(_ status: Int32) throws {
        guard status >= 0 else {
            let message = String(cString: mpv_error_string(status))
            PlaybackDebugLogger.log("mpv error status=\(status) message=\(message)")
            throw NSError(domain: "SwiftTube.MPV", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func makeFileLoadedTask(for handle: OpaquePointer, isReplace: Bool = false) -> Task<Void, Error> {
        let handleBits = UInt(bitPattern: handle)

        return Task.detached(priority: .userInitiated) {
            let handle = OpaquePointer(bitPattern: handleBits)!

            while true {
                try Task.checkCancellation()
                guard let event = mpv_wait_event(handle, 0.1) else { continue }
                let eventName = String(cString: mpv_event_name(event.pointee.event_id))

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
                        let endErrorMessage = String(cString: mpv_error_string(endError))
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

    func makeAudioReadyTask(for audio: MediaStreamRequest, handle: OpaquePointer) -> Task<Void, Never> {
        let handleBits = UInt(bitPattern: handle)
        return Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard Task.isCancelled == false else {
                PlaybackDebugLogger.log("mpv audio-add cancelled before command")
                return
            }

            do {
                PlaybackDebugLogger.log("mpv audio-add start url=\(audio.url.absoluteString)")
                try await MainActor.run {
                    try self.command(["audio-add", audio.url.absoluteString, "select"])
                }
            } catch {
                PlaybackDebugLogger.log("mpv audio-add command failed error=\(error.localizedDescription)")
                return
            }

            let handle = OpaquePointer(bitPattern: handleBits)!
            let deadline = Date().addingTimeInterval(5)

            while Date() < deadline {
                if Task.isCancelled {
                    PlaybackDebugLogger.log("mpv audio-add cancelled")
                    return
                }
                let audioTrackID = Self.intProperty(MPVProperty.audioTrackID, from: handle) ?? 0
                if audioTrackID > 0 {
                    let codec = Self.stringProperty(MPVProperty.audioCodecName, from: handle) ?? "nil"
                    let channels = Self.intProperty(MPVProperty.audioChannelCount, from: handle).map(String.init) ?? "nil"
                    PlaybackDebugLogger.log("mpv audio-add ready aid=\(audioTrackID) codec=\(codec) channels=\(channels)")
                    return
                }

                if let event = mpv_wait_event(handle, 0.1),
                   event.pointee.event_id == MPV_EVENT_LOG_MESSAGE,
                   let logMessage = event.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self) {
                    let prefix = String(cString: logMessage.pointee.prefix)
                    let level = String(cString: logMessage.pointee.level)
                    let text = String(cString: logMessage.pointee.text).trimmingCharacters(in: .whitespacesAndNewlines)
                    if Self.shouldLogMPVMessage(prefix: prefix, level: level) {
                        PlaybackDebugLogger.log("mpv log [\(prefix)] [\(level)] \(text)")
                    }
                }
            }

            PlaybackDebugLogger.log("mpv audio-add timed out waiting for aid")
        }
    }

    func updateCachedState() {
        guard let mpv, didLoadFile else { return }

        currentTime = max(doubleProperty(MPVProperty.timePosition, from: mpv), 0)
        duration = max(doubleProperty(MPVProperty.duration, from: mpv), 0)
        isBuffering = flagProperty(MPVProperty.pausedForCache, from: mpv)
        isPlaying = flagProperty(MPVProperty.pause, from: mpv) == false
        let aspect = doubleProperty("video-params/aspect", from: mpv)
        if aspect > 0 { videoAspect = aspect }
    }

    func doubleProperty(_ name: String, from handle: OpaquePointer) -> Double {
        var value = 0.0
        let result = mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value)
        guard result >= 0, value.isFinite else { return 0 }
        return value
    }

    func flagProperty(_ name: String, from handle: OpaquePointer) -> Bool {
        var value: Int32 = 0
        let result = mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value)
        guard result >= 0 else { return false }
        return value != 0
    }

    nonisolated static func intProperty(_ name: String, from handle: OpaquePointer) -> Int64? {
        var value: Int64 = 0
        let result = mpv_get_property(handle, name, MPV_FORMAT_INT64, &value)
        guard result >= 0 else { return nil }
        return value
    }

    nonisolated static func stringProperty(_ name: String, from handle: OpaquePointer) -> String? {
        guard let cString = mpv_get_property_string(handle, name) else {
            return nil
        }
        defer { mpv_free(cString) }
        return String(cString: cString)
    }

    func startEventPump(using handle: OpaquePointer) {
        guard eventPumpTask == nil else { return }
        let handleBits = UInt(bitPattern: handle)
        eventPumpTask = Task.detached(priority: .userInitiated) {
            let handle = OpaquePointer(bitPattern: handleBits)!

            while Task.isCancelled == false {
                guard let event = mpv_wait_event(handle, 0.1) else { continue }
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
                    if Self.shouldLogMPVMessage(prefix: prefix, level: level) {
                        PlaybackDebugLogger.log("mpv log [\(prefix)] [\(level)] \(text)")
                    }
                case MPV_EVENT_END_FILE:
                    if let endFile = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self) {
                        let endReason = endFile.pointee.reason
                        let endError = endFile.pointee.error
                        let endErrorMessage = String(cString: mpv_error_string(endError))
                        PlaybackDebugLogger.log(
                            "mpv event end-file reason=\(endReason) error=\(endError) message=\(endErrorMessage)"
                        )
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
            try check(mpv_command(mpv, buffer.baseAddress))
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
