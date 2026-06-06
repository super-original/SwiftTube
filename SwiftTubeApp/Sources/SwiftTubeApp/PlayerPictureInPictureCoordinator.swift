import AppKit
import AVFoundation
import AVKit
import SwiftUI

@MainActor
final class PlayerPictureInPictureCoordinator: NSObject, ObservableObject {
    @Published private(set) var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false
    @Published private(set) var isPreparing = false

    var onSetPlaying: ((Bool) -> Void)?
    var onSeek: ((Double) -> Void)?

    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private var controller: AVPictureInPictureController?
    private var currentRequest: MPVPlaybackRequest?
    private var wantsStartWhenPossible = false
    private var isApplyingExternalSync = false
    private var lastSyncedTime: Double = 0
    private var lastSyncedPlaying = false
    private var lastSyncedRate: Double = 1
    private var rateObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var possibleObservation: NSKeyValueObservation?

    override init() {
        super.init()
        player.isMuted = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        installPlayerObservers()
    }

    var symbolName: String {
        isActive ? "pip.exit" : "pip.enter"
    }

    func attach(to hostView: NSView) {
        hostView.wantsLayer = true
        if hostView.layer == nil {
            hostView.layer = CALayer()
        }
        if playerLayer.superlayer !== hostView.layer {
            playerLayer.removeFromSuperlayer()
            hostView.layer?.addSublayer(playerLayer)
        }
        updateHostBounds(hostView.bounds)
    }

    func updateHostBounds(_ bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func start(
        request: MPVPlaybackRequest,
        currentTime: Double,
        isPlaying: Bool,
        playbackRate: Double
    ) {
        guard isSupported else { return }
        wantsStartWhenPossible = true
        prepareIfNeeded(for: request)
        sync(currentTime: currentTime, isPlaying: isPlaying, playbackRate: playbackRate)
        startIfPossible()
    }

    func stop() {
        wantsStartWhenPossible = false
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        } else {
            isActive = false
            isPreparing = false
            player.pause()
        }
    }

    func reset() {
        wantsStartWhenPossible = false
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        itemStatusObservation = nil
        possibleObservation = nil
        controller = nil
        currentRequest = nil
        isActive = false
        isPossible = false
        isPreparing = false
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func sync(
        request: MPVPlaybackRequest?,
        currentTime: Double,
        isPlaying: Bool,
        playbackRate: Double
    ) {
        guard isActive || isPreparing || wantsStartWhenPossible else { return }
        if let request {
            prepareIfNeeded(for: request)
        }
        sync(currentTime: currentTime, isPlaying: isPlaying, playbackRate: playbackRate)
    }
}

extension PlayerPictureInPictureCoordinator: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPreparing = true
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
        isPreparing = false
        wantsStartWhenPossible = false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        PlaybackDebugLogger.log("pip failed to start error=\(error.localizedDescription)")
        isActive = false
        isPreparing = false
        wantsStartWhenPossible = false
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPreparing = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false
        isPreparing = false
        wantsStartWhenPossible = false
        player.pause()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

private extension PlayerPictureInPictureCoordinator {
    func prepareIfNeeded(for request: MPVPlaybackRequest) {
        guard currentRequest != request else {
            ensureController()
            return
        }

        currentRequest = request
        itemStatusObservation = nil
        possibleObservation = nil
        isPossible = false
        isPreparing = true

        let options: [String: Any]? = request.video.headers.isEmpty
            ? nil
            : ["AVURLAssetHTTPHeaderFieldsKey": request.video.headers]
        let asset = AVURLAsset(url: request.video.url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 4
        player.replaceCurrentItem(with: item)
        installItemObserver(item)
        ensureController()
    }

    func ensureController() {
        guard controller == nil, isSupported else { return }
        guard playerLayer.superlayer != nil else { return }
        guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else {
            isSupported = false
            return
        }
        controller.delegate = self
        self.controller = controller
        installControllerObserver(controller)
    }

    func installPlayerObservers() {
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.handlePlayerRateChange(player.rate)
            }
        }
    }

    func installItemObserver(_ item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.handleItemStatusChange(item.status)
            }
        }
    }

    func installControllerObserver(_ controller: AVPictureInPictureController) {
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let isPossible = controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                self?.isPossible = isPossible
                self?.startIfPossible()
            }
        }
    }

    func handleItemStatusChange(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            isPreparing = wantsStartWhenPossible
            startIfPossible()
        case .failed:
            PlaybackDebugLogger.log("pip AVPlayerItem failed error=\(player.currentItem?.error?.localizedDescription ?? "nil")")
            isPreparing = false
            wantsStartWhenPossible = false
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    func sync(currentTime: Double, isPlaying: Bool, playbackRate: Double) {
        lastSyncedTime = currentTime
        lastSyncedPlaying = isPlaying
        lastSyncedRate = playbackRate
        guard player.currentItem != nil else { return }

        isApplyingExternalSync = true
        defer { isApplyingExternalSync = false }

        let playerTime = player.currentTime().seconds
        if playerTime.isFinite == false || abs(playerTime - currentTime) > 0.75 {
            player.seek(
                to: CMTime(seconds: max(currentTime, 0), preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }

        player.defaultRate = Float(max(playbackRate, 0.25))
        if isPlaying {
            player.playImmediately(atRate: Float(max(playbackRate, 0.25)))
        } else {
            player.pause()
        }
    }

    func startIfPossible() {
        guard wantsStartWhenPossible, let controller else { return }
        guard controller.isPictureInPictureActive == false else { return }
        guard playerLayer.isReadyForDisplay || player.currentItem?.status == .readyToPlay else { return }

        isPreparing = true
        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else if lastSyncedPlaying == false {
            player.preroll(atRate: Float(max(lastSyncedRate, 0.25))) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.startIfPossible()
                }
            }
        }
    }

    func handlePlayerRateChange(_ rate: Float) {
        guard isActive, !isApplyingExternalSync else { return }
        let requestedPlaying = rate > 0.01
        guard requestedPlaying != lastSyncedPlaying else { return }
        onSetPlaying?(requestedPlaying)
    }
}

@MainActor
struct PictureInPictureSourceView: NSViewRepresentable {
    @ObservedObject var pictureInPicture: PlayerPictureInPictureCoordinator

    func makeNSView(context: Context) -> PictureInPictureHostView {
        let view = PictureInPictureHostView()
        view.onLayout = { [weak pictureInPicture] bounds in
            pictureInPicture?.updateHostBounds(bounds)
        }
        pictureInPicture.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: PictureInPictureHostView, context: Context) {
        pictureInPicture.attach(to: nsView)
        pictureInPicture.updateHostBounds(nsView.bounds)
    }
}

final class PictureInPictureHostView: NSView {
    var onLayout: ((CGRect) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        onLayout?(bounds)
    }
}
