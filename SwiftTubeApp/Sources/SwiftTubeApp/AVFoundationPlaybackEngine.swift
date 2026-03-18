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
        if let assetDuration = try? await item.asset.load(.duration) {
            duration = max(assetDuration.seconds, 0)
        }
        try await waitUntilReadyToPlay(item)

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

private extension AVFoundationPlaybackEngine {
    func waitUntilReadyToPlay(_ item: AVPlayerItem) async throws {
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
                guard box.didResume == false else { return }

                switch observedItem.status {
                case .readyToPlay:
                    box.didResume = true
                    box.observation?.invalidate()
                    box.observation = nil
                    continuation.resume()
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
}
