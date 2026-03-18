import AppKit
import Foundation
import Libmpv

@MainActor
final class MPVPlaybackEngine: NSObject, PlaybackEngine {
    let id = UUID()
    let kind: PlaybackBackendKind = .mpv

    weak var delegate: PlaybackEngineDelegate?

    let renderController = MPVRenderViewController()
    private let request: MPVPlaybackRequest
    private var mpv: OpaquePointer?
    private var didLoadFile = false

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false

    init(request: MPVPlaybackRequest) {
        self.request = request
        super.init()
    }

    func prepare(startTime: Double, autoPlay: Bool) async throws {
        PlaybackDebugLogger.log(
            "mpv prepare start video=\(request.video.url.absoluteString) audio=\(request.audio?.url.absoluteString ?? "nil") startTime=\(startTime) autoPlay=\(autoPlay)"
        )
        let _ = await renderController.waitForRenderLayer()
        let handle = try initializeIfNeeded()
        didLoadFile = false
        try command(["loadfile", request.video.url.absoluteString, "replace", "-1"])
        try await waitUntilFileLoaded(handle)

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
        setPaused(false)
        isPlaying = true
    }

    func pause() {
        setPaused(true)
        isPlaying = false
    }

    func stop() {
        isPlaying = false
        destroyPlayer()
    }

    func seek(to seconds: Double) async {
        currentTime = max(seconds, 0)
        do {
            try command(["seek", String(currentTime), "absolute", "exact"])
            updateCachedState()
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
}

private extension MPVPlaybackEngine {
    func initializeIfNeeded() throws -> OpaquePointer {
        if let mpv {
            return mpv
        }
        guard let handle = mpv_create() else {
            throw NSError(domain: "SwiftTube.MPV", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create mpv context."])
        }

        mpv = handle
        PlaybackDebugLogger.log(
            "mpv initialize videoHeaders=\(request.video.headers.keys.sorted()) audioHeaders=\(request.audio?.headers.keys.sorted() ?? []) logPath=\(PlaybackDebugLogger.path)"
        )

        try setOption("vo", value: "gpu-next")
        try setOption("gpu-api", value: "vulkan")
        try setOption("gpu-context", value: "moltenvk")
        try setOption("hwdec", value: "videotoolbox")
        try setOption("osc", value: "no")
        try setOption("input-default-bindings", value: "no")
        try setOption("ytdl", value: "no")
        try setOption("sub-auto", value: "no")
        try setOption("audio-file-auto", value: "no")

        if let layer = renderController.currentMetalLayer {
            var layerReference = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque())))
            try check(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &layerReference))
        }

        let userAgentKeys = ["User-Agent", "user-agent"]
        let referrerKeys = ["Referer", "referer", "Referrer", "referrer"]
        let headers = request.video.headers

        if let userAgent = userAgentKeys.compactMap({ headers[$0] }).first {
            try setOption("user-agent", value: userAgent)
        }

        if let referrer = referrerKeys.compactMap({ headers[$0] }).first {
            try setOption("referrer", value: referrer)
        }

        let headerFields = headers
            .filter { entry in
                userAgentKeys.contains(entry.key) == false && referrerKeys.contains(entry.key) == false
            }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ",")

        if headerFields.isEmpty == false {
            try setOption("http-header-fields", value: headerFields)
        }

        if let audio = request.audio {
            try setOption("audio-files", value: audio.url.absoluteString)
        }

        try check(mpv_initialize(handle))
        didLoadFile = false
        return handle
    }

    func destroyPlayer() {
        guard let mpv else { return }
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

    func waitUntilFileLoaded(_ handle: OpaquePointer) async throws {
        let handleBits = UInt(bitPattern: handle)

        try await Task.detached(priority: .userInitiated) {
            let handle = OpaquePointer(bitPattern: handleBits)!

            while true {
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
                            "mpv event \(eventName) reason=\(endReason) error=\(endError) message=\(endErrorMessage)"
                        )
                        throw NSError(
                            domain: "SwiftTube.MPV",
                            code: Int(endError != 0 ? endError : -11),
                            userInfo: [NSLocalizedDescriptionKey: "mpv ended the file before it became ready. reason=\(endReason) error=\(endErrorMessage)"]
                        )
                    }
                    PlaybackDebugLogger.log("mpv event \(eventName)")
                    throw NSError(domain: "SwiftTube.MPV", code: -11, userInfo: [NSLocalizedDescriptionKey: "mpv ended the file before it became ready."])
                case MPV_EVENT_LOG_MESSAGE:
                    if let logMessage = event.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self) {
                        let prefix = String(cString: logMessage.pointee.prefix)
                        let level = String(cString: logMessage.pointee.level)
                        let text = String(cString: logMessage.pointee.text).trimmingCharacters(in: .whitespacesAndNewlines)
                        if level == "error" || level == "warn" || prefix == "ffmpeg" {
                            PlaybackDebugLogger.log("mpv log [\(prefix)] [\(level)] \(text)")
                        }
                    }
                default:
                    continue
                }
            }
        }.value

        didLoadFile = true
    }

    func updateCachedState() {
        guard let mpv, didLoadFile else { return }

        currentTime = max(doubleProperty(MPVProperty.timePosition, from: mpv), 0)
        duration = max(doubleProperty(MPVProperty.duration, from: mpv), 0)
        isBuffering = flagProperty(MPVProperty.pausedForCache, from: mpv)
        isPlaying = flagProperty(MPVProperty.pause, from: mpv) == false
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
}
