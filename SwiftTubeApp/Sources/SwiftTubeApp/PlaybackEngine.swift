import AVFoundation
import Foundation

enum PlaybackBackendKind: String, Sendable {
    case avFoundation
    case mpv
}

enum PlaybackCapability: Sendable {
    case native
    case compatibility
    case unsupported
}

struct MediaStreamRequest: Hashable, Sendable {
    let url: URL
    let headers: [String: String]

    init(url: URL, headers: [String: String]?) {
        self.url = url
        self.headers = headers ?? [:]
    }
}

struct MPVPlaybackRequest: Hashable, Sendable {
    let video: MediaStreamRequest
    let audio: MediaStreamRequest?
}

@MainActor
protocol PlaybackEngineDelegate: AnyObject {
    func playbackEngineDidBecomeReady(_ engine: PlaybackEngine)
    func playbackEngine(_ engine: PlaybackEngine, didUpdateCurrentTime currentTime: Double)
    func playbackEngine(_ engine: PlaybackEngine, didUpdateDuration duration: Double)
    func playbackEngine(_ engine: PlaybackEngine, didChangePlaying isPlaying: Bool)
    func playbackEngine(_ engine: PlaybackEngine, didChangeBuffering isBuffering: Bool)
    func playbackEngineDidReachEnd(_ engine: PlaybackEngine)
    func playbackEngine(_ engine: PlaybackEngine, didFail message: String)
}

@MainActor
protocol PlaybackEngine: AnyObject {
    var id: UUID { get }
    var kind: PlaybackBackendKind { get }
    var delegate: PlaybackEngineDelegate? { get set }
    var currentTime: Double { get }
    var duration: Double { get }
    var isPlaying: Bool { get }
    var isBuffering: Bool { get }
    func prepare(startTime: Double, autoPlay: Bool) async throws
    func play()
    func pause()
    func stop()
    func seek(to seconds: Double) async
    func setVolume(_ volume: Double)
}
