import Foundation
import SwiftUI

@MainActor
final class InlinePlaybackManager: ObservableObject {
    static let shared = InlinePlaybackManager()

    @Published private(set) var activeVideoID: String?
    @Published private(set) var preparedVideoID: String?
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isMuted = true
    @Published private(set) var isLoading = false

    private let hoverDelayNanoseconds: UInt64 = 450_000_000
    private let reportThresholdSeconds = 3.0
    private var hoverTasks: [String: Task<Void, Never>] = [:]
    private var activeEngine: MPVPlaybackEngine?
    private var activePayload: InlinePlaybackPayload?
    private var pollTask: Task<Void, Never>?
    private var resumePositions: [String: Double] = [:]
    private var lastReportedSecondByVideoID: [String: Double] = [:]
    private var isScrubbing = false

    private init() {}

    func isActive(_ videoID: String) -> Bool {
        preparedVideoID == videoID
    }

    func isRendering(_ videoID: String) -> Bool {
        activeVideoID == videoID
    }

    func canStartInlinePlayback(for video: VideoItem) -> Bool {
        !video.isLive && !video.isMembersOnly
    }

    func engine(for videoID: String) -> MPVPlaybackEngine? {
        guard activeVideoID == videoID else { return nil }
        return activeEngine
    }

    func resumePosition(for videoID: String) -> Double? {
        if activeVideoID == videoID, let engine = activeEngine {
            let snapshot = engine.snapshot()
            saveResumePosition(snapshot.currentTime, for: videoID)
        }

        guard let position = resumePositions[videoID], position >= 1 else { return nil }
        return position
    }

    func scheduleHover(for video: VideoItem) {
        guard canStartInlinePlayback(for: video) else { return }
        guard hoverTasks[video.id] == nil else { return }

        let delay = hoverDelayNanoseconds
        hoverTasks[video.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.start(video: video)
        }
    }

    func endHover(for videoID: String) {
        hoverTasks[videoID]?.cancel()
        hoverTasks.removeValue(forKey: videoID)

        guard activeVideoID == videoID || preparedVideoID == videoID else { return }
        pauseActive(keepEngine: true)
    }

    func toggleMute() {
        isMuted.toggle()
        activeEngine?.setVolume(isMuted ? 0 : 1)
    }

    func seek(to seconds: Double) {
        guard let activeVideoID, let activeEngine else { return }
        isScrubbing = true
        Task { [weak self, weak activeEngine] in
            await activeEngine?.seek(to: seconds)
            await MainActor.run {
                self?.currentTime = seconds
                self?.saveResumePosition(seconds, for: activeVideoID)
                self?.lastReportedSecondByVideoID[activeVideoID] = floor(seconds)
                self?.isScrubbing = false
            }
        }
    }

    func seek(toFraction fraction: Double) {
        let upperBound = max(duration, currentTime, 1)
        seek(to: max(0, min(1, fraction)) * upperBound)
    }

    func pause(videoID: String) {
        guard activeVideoID == videoID else { return }
        pauseActive(keepEngine: true)
    }
}

private extension InlinePlaybackManager {
    func start(video: VideoItem) async {
        hoverTasks.removeValue(forKey: video.id)
        guard canStartInlinePlayback(for: video) else { return }

        if activeVideoID == video.id, let engine = activeEngine {
            activeVideoID = video.id
            engine.play()
            await Task.yield()
            preparedVideoID = video.id
            startPolling(engine: engine, payload: activePayload)
            return
        }

        pauseActive(keepEngine: activePayload?.id == video.id)

        if activePayload?.id == video.id, let engine = activeEngine {
            activeVideoID = video.id
            engine.setVolume(isMuted ? 0 : 1)
            engine.play()
            await Task.yield()
            preparedVideoID = video.id
            startPolling(engine: engine, payload: activePayload)
            return
        }

        isLoading = true
        do {
            let payload = try await BackendClient.shared.fetchInlinePlayback(id: video.id)
            guard !Task.isCancelled else { return }
            let request = try playbackRequest(for: payload)
            let engine = MPVPlaybackEngine(request: request)
            activePayload = payload
            activeEngine = engine
            activeVideoID = video.id
            currentTime = resumePositions[video.id] ?? payload.progress?.bestResumeSeconds ?? 0
            duration = payload.durationSeconds ?? 0
            isLoading = false

            await Task.yield()
            try await engine.prepare(startTime: currentTime, autoPlay: false)
            guard !Task.isCancelled else {
                engine.stop()
                if activeVideoID == video.id {
                    activeVideoID = nil
                }
                activePayload = nil
                activeEngine = nil
                return
            }
            engine.setVolume(isMuted ? 0 : 1)
            engine.play()
            preparedVideoID = video.id
            startPolling(engine: engine, payload: payload)
        } catch {
            guard !Task.isCancelled else { return }
            if activeVideoID == video.id {
                activeVideoID = nil
            }
            if preparedVideoID == video.id {
                preparedVideoID = nil
            }
            activePayload = nil
            activeEngine?.stop()
            activeEngine = nil
            isLoading = false
        }
    }

    func pauseActive(keepEngine: Bool) {
        pollTask?.cancel()
        pollTask = nil

        if let activeVideoID, let engine = activeEngine {
            let snapshot = engine.snapshot()
            saveResumePosition(snapshot.currentTime, for: activeVideoID)
            reportProgress(videoID: activeVideoID, currentTime: snapshot.currentTime, duration: snapshot.duration, didFinish: false)
            engine.pause()
        }

        activeVideoID = nil
        preparedVideoID = nil
        currentTime = 0
        duration = 0
        isLoading = false

        if !keepEngine {
            activeEngine?.stop()
            activeEngine = nil
            activePayload = nil
        }
    }

    func startPolling(engine: MPVPlaybackEngine, payload: InlinePlaybackPayload?) {
        pollTask?.cancel()
        pollTask = Task { [weak self, weak engine] in
            while !Task.isCancelled {
                guard let self, let engine, self.activeEngine === engine, let videoID = self.activeVideoID else {
                    return
                }
                let snapshot = engine.snapshot()
                self.currentTime = snapshot.currentTime
                self.duration = snapshot.duration > 0 ? snapshot.duration : (payload?.durationSeconds ?? self.duration)
                self.saveResumePosition(snapshot.currentTime, for: videoID)

                if snapshot.isPlaying, !self.isScrubbing {
                    self.maybeReportProgress(videoID: videoID, snapshot: snapshot)
                }

                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func maybeReportProgress(videoID: String, snapshot: MPVPlaybackSnapshot) {
        let currentSecond = floor(snapshot.currentTime)
        guard currentSecond >= reportThresholdSeconds else { return }
        guard currentSecond > (lastReportedSecondByVideoID[videoID] ?? -1) else { return }
        lastReportedSecondByVideoID[videoID] = currentSecond
        reportProgress(videoID: videoID, currentTime: snapshot.currentTime, duration: snapshot.duration, didFinish: false)
    }

    func reportProgress(videoID: String, currentTime: Double, duration: Double, didFinish: Bool) {
        guard currentTime >= reportThresholdSeconds || didFinish else { return }

        Task {
            try? await BackendClient.shared.recordPlaybackProgress(
                id: videoID,
                currentTime: currentTime,
                duration: duration > 0 ? duration : activePayload?.durationSeconds,
                didFinish: didFinish
            )
        }
    }

    func saveResumePosition(_ seconds: Double, for videoID: String) {
        guard seconds.isFinite, seconds >= 0 else { return }
        resumePositions[videoID] = seconds
    }

    func playbackRequest(for payload: InlinePlaybackPayload) throws -> MPVPlaybackRequest {
        guard let videoURL = URL(string: payload.videoStream.url) else {
            throw URLError(.badURL)
        }

        let audioRequest: MediaStreamRequest?
        if let audioStream = payload.audioStream {
            guard let audioURL = URL(string: audioStream.url) else {
                throw URLError(.badURL)
            }
            audioRequest = MediaStreamRequest(url: audioURL, headers: audioStream.httpHeaders)
        } else {
            audioRequest = nil
        }

        return MPVPlaybackRequest(
            video: MediaStreamRequest(url: videoURL, headers: payload.videoStream.httpHeaders),
            audio: audioRequest
        )
    }
}

struct InlineVideoThumbnail: View {
    @ObservedObject private var manager = InlinePlaybackManager.shared
    let video: VideoItem
    let width: CGFloat?
    let height: CGFloat?
    let cornerRadius: CGFloat
    let maxPixelSize: Int
    let placeholderIconSize: CGFloat

    @State private var isPointerInside = false
    @State private var isPointerInLowerRegion = false
    @State private var pointerFraction: Double = 0

    init(
        video: VideoItem,
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        cornerRadius: CGFloat,
        maxPixelSize: Int,
        placeholderIconSize: CGFloat
    ) {
        self.video = video
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.maxPixelSize = maxPixelSize
        self.placeholderIconSize = placeholderIconSize
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                thumbnailBase

                if manager.isRendering(video.id), let engine = manager.engine(for: video.id) {
                    MPVMetalRenderView(engine: engine) {
                        try? engine.refreshPausedFrame(at: manager.currentTime)
                    }
                    .background(Color.black)
                    .opacity(manager.isActive(video.id) ? 1 : 0)
                }

                overlayContent(size: proxy.size)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering in
                isPointerInside = hovering
                if hovering {
                    manager.scheduleHover(for: video)
                } else {
                    isPointerInLowerRegion = false
                    manager.endHover(for: video.id)
                }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let lowerHoverHeight = max(CGFloat(32), proxy.size.height * 0.30)
                    isPointerInLowerRegion = location.y >= proxy.size.height - lowerHoverHeight
                    pointerFraction = max(0, min(1, location.x / max(proxy.size.width, 1)))
                case .ended:
                    isPointerInLowerRegion = false
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(width: width, height: height)
    }

    private var thumbnailBase: some View {
        CachedAsyncImage(url: video.thumbnailURL, maxPixelSize: maxPixelSize) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.gray.opacity(0.18))
                .overlay(
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: placeholderIconSize))
                        .foregroundStyle(.secondary)
                )
        }
    }

    @ViewBuilder
    private func overlayContent(size: CGSize) -> some View {
        let isInlineActive = manager.isActive(video.id)

        if isInlineActive {
            Button(action: manager.toggleMute) {
                Image(systemName: manager.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.black.opacity(0.62)))
            }
            .buttonStyle(.plain)
            .help(manager.isMuted ? "Unmute" : "Mute")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(8)

            inlineScrubber
                .padding(.horizontal, isPointerInLowerRegion ? max(size.width * 0.045, 8) : 0)
                .padding(.bottom, isPointerInLowerRegion ? max(size.height * 0.06, 6) : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .animation(.snappy(duration: 0.18, extraBounce: 0), value: isPointerInLowerRegion)
        } else if let duration = video.durationText {
            Text(duration)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.74)))
                .foregroundStyle(.white)
                .padding(max(size.width * 0.035, 6))
        }

        if !isInlineActive {
            VideoThumbnailProgressBars(progress: video.progress, cornerRadius: cornerRadius, isEnabled: !video.isLive)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var inlineScrubber: some View {
        InlineThumbnailScrubber(
            currentTime: manager.currentTime,
            duration: max(manager.duration, manager.currentTime, 1),
            isExpanded: isPointerInside && isPointerInLowerRegion,
            hoverFraction: pointerFraction,
            onSeekFraction: manager.seek(toFraction:)
        )
    }
}

private struct InlineThumbnailScrubber: View {
    let currentTime: Double
    let duration: Double
    let isExpanded: Bool
    let hoverFraction: Double
    let onSeekFraction: (Double) -> Void

    private var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, currentTime / duration))
    }

    private var displayedFraction: Double {
        isExpanded ? hoverFraction : progressFraction
    }

    var body: some View {
        GeometryReader { proxy in
            let trackWidth = max(proxy.size.width, 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(isExpanded ? 0.30 : 0.22))

                Capsule()
                    .fill(BrandAssets.youtubeRed)
                    .frame(width: trackWidth * progressFraction)

                if isExpanded {
                    Capsule()
                        .fill(Color.white.opacity(0.34))
                        .frame(width: trackWidth * displayedFraction)

                    Circle()
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                        .offset(x: max(0, min(trackWidth - 10, (trackWidth * displayedFraction) - 5)))

                    Text(formatTime(duration * displayedFraction))
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.72)))
                        .offset(
                            x: max(0, min(trackWidth - 48, (trackWidth * displayedFraction) - 24)),
                            y: -30
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .frame(height: isExpanded ? 7 : 5)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = max(0, min(1, value.location.x / trackWidth))
                        onSeekFraction(fraction)
                    }
            )
        }
        .frame(height: isExpanded ? 38 : 5)
        .animation(.snappy(duration: 0.18, extraBounce: 0), value: isExpanded)
    }

    private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds.rounded(.down))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secondsPart = totalSeconds % 60

        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", secondsPart))"
        }
        return "\(minutes):\(String(format: "%02d", secondsPart))"
    }
}
