import AVFoundation
import Foundation

@MainActor
final class AVFoundationPlaybackEngine: NSObject, PlaybackEngine {
    let id = UUID()
    let kind: PlaybackBackendKind = .avFoundation

    weak var delegate: PlaybackEngineDelegate?

    let player: AVPlayer
    private let item: AVPlayerItem

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false

    init(item: AVPlayerItem, volume: Double) {
        self.player = AVPlayer()
        self.item = item
        super.init()
        player.automaticallyWaitsToMinimizeStalling = false
        player.volume = Float(max(0, min(volume, 1)))
    }

    func prepare(startTime: Double, autoPlay: Bool) async throws {
        player.replaceCurrentItem(with: item)
        duration = max(item.asset.duration.seconds, 0)

        if startTime > 0 {
            await seek(to: startTime)
        }

        if autoPlay {
            play()
        } else {
            pause()
        }
    }

    func play() {
        isPlaying = true
        player.play()
    }

    func pause() {
        isPlaying = false
        player.pause()
    }

    func stop() {
        isPlaying = false
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func seek(to seconds: Double) async {
        let clampedSeconds = max(seconds, 0)
        let target = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        await withCheckedContinuation { continuation in
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                self?.currentTime = clampedSeconds
                continuation.resume()
            }
        }
    }

    func setVolume(_ volume: Double) {
        player.volume = Float(max(0, min(volume, 1)))
    }
}
