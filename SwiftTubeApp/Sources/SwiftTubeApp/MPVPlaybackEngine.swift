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

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false

    init(request: MPVPlaybackRequest) {
        self.request = request
        super.init()
    }

    func prepare(startTime: Double, autoPlay: Bool) async throws {
        if mpv == nil {
            try initializeIfNeeded()
        }

        if startTime > 0 {
            currentTime = startTime
        }

        if autoPlay {
            play()
        } else {
            pause()
        }
    }

    func play() {
        isPlaying = true
    }

    func pause() {
        isPlaying = false
    }

    func stop() {
        isPlaying = false
        destroyPlayer()
    }

    func seek(to seconds: Double) async {
        currentTime = max(seconds, 0)
    }

    func setVolume(_ volume: Double) {
        guard let mpv else { return }
        var clampedVolume = max(0, min(volume, 1)) * 100
        mpv_set_property(mpv, MPVProperty.volume, MPV_FORMAT_DOUBLE, &clampedVolume)
    }
}

private extension MPVPlaybackEngine {
    func initializeIfNeeded() throws {
        guard mpv == nil else { return }
        guard let handle = mpv_create() else {
            throw NSError(domain: "SwiftTube.MPV", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create mpv context."])
        }

        mpv = handle

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
            var layerReference = layer
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

        try check(mpv_initialize(handle))
    }

    func destroyPlayer() {
        guard let mpv else { return }
        mpv_terminate_destroy(mpv)
        self.mpv = nil
    }

    func setOption(_ name: String, value: String) throws {
        guard let mpv else { return }
        try check(mpv_set_option_string(mpv, name, value))
    }

    func check(_ status: Int32) throws {
        guard status >= 0 else {
            let message = String(cString: mpv_error_string(status))
            throw NSError(domain: "SwiftTube.MPV", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
