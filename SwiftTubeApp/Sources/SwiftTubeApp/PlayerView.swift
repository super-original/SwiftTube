import AppKit
import AVKit
import SwiftUI

final class PassivePlayerContainerView: NSView {
    private let playerView = AVPlayerView()
    var onLayoutChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        playerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playerView)

        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override func layout() {
        super.layout()
        onLayoutChange?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func configure(player: AVPlayer) {
        if playerView.player !== player {
            playerView.player = player
        }
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = false
        playerView.allowsMagnification = false
    }
}

final class PlayerContainerViewController: NSViewController {
    override func loadView() {
        view = PassivePlayerContainerView()
    }

    func configure(player: AVPlayer, onLayoutChange: @escaping () -> Void) {
        guard let containerView = view as? PassivePlayerContainerView else { return }
        containerView.onLayoutChange = onLayoutChange
        containerView.configure(player: player)
    }
}

struct PlayerRenderView: NSViewControllerRepresentable {
    let player: AVPlayer
    let onLayoutChange: () -> Void

    func makeNSViewController(context: Context) -> PlayerContainerViewController {
        let controller = PlayerContainerViewController()
        controller.configure(player: player, onLayoutChange: onLayoutChange)
        return controller
    }

    func updateNSViewController(_ controller: PlayerContainerViewController, context: Context) {
        controller.configure(player: player, onLayoutChange: onLayoutChange)
    }
}

private struct PlayerRenderStateView: View {
    let renderState: PlayerRenderState
    let onLayoutChange: () -> Void

    var body: some View {
        switch renderState {
        case .avFoundation(let player):
            PlayerRenderView(player: player, onLayoutChange: onLayoutChange)
        case .mpv(let engine):
            MPVMetalRenderView(engine: engine, onLayoutChange: onLayoutChange)
        }
    }
}

private extension PlayerRenderState {
    var avPlayer: AVPlayer? {
        guard case .avFoundation(let player) = self else { return nil }
        return player
    }

    var mpvEngine: MPVPlaybackEngine? {
        guard case .mpv(let engine) = self else { return nil }
        return engine
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowResolverView {
        let view = WindowResolverView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: WindowResolverView, context: Context) {
        nsView.onResolve = onResolve
    }
}

final class WindowResolverView: NSView {
    var onResolve: ((NSWindow?) -> Void)?
    private weak var lastResolvedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveWindowIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        resolveWindowIfNeeded()
    }

    private func resolveWindowIfNeeded() {
        guard lastResolvedWindow !== window else { return }
        lastResolvedWindow = window
        onResolve?(window)
    }
}

private struct StandardPlayerStageBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct PlayerScreen: View {
    let video: VideoItem

    @StateObject private var viewModel: PlayerViewModel
    @StateObject private var layoutState: PlayerLayoutState
    @State private var playbackCoordinator: PlayerPlaybackCoordinator
    @State private var isDescriptionExpanded = false
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var authSession: AuthSessionModel

    init(video: VideoItem) {
        self.video = video
        let layoutState = PlayerLayoutState()
        _viewModel = StateObject(wrappedValue: PlayerViewModel(video: video))
        _layoutState = StateObject(wrappedValue: layoutState)
        _playbackCoordinator = State(initialValue: PlayerPlaybackCoordinator(layoutState: layoutState))
    }

    var body: some View {
        ScrollView {
            scrollContent
        }
        .scrollDisabled(layoutState.isFullscreen)
        .background(
            (layoutState.isFullscreen ? Color.black : Color(NSColor.windowBackgroundColor))
                .ignoresSafeArea()
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            if usesImmersiveLayout {
                PlayerStageHost(
                    coordinator: playbackCoordinator,
                    isLoading: viewModel.isLoading,
                    errorMessage: viewModel.errorMessage,
                    immersive: true,
                    retry: viewModel.load
                )
            }
        }
        .overlayPreferenceValue(StandardPlayerStageBoundsPreferenceKey.self) { anchor in
            GeometryReader { proxy in
                if !usesImmersiveLayout,
                   let anchor {
                    let rect = proxy[anchor]
                    StandardPlayerStageOverlay(
                        coordinator: playbackCoordinator,
                        isLoading: viewModel.isLoading,
                        errorMessage: viewModel.errorMessage ?? playbackCoordinator.errorMessage,
                        rect: rect,
                        retry: viewModel.load
                    )
                }
            }
        }
        .background(
            WindowAccessor { window in
                playbackCoordinator.setWindow(window)
            }
            .frame(width: 0, height: 0)
        )
        .task(id: "\(video.id)-\(authSession.contentRefreshID.uuidString)") {
            viewModel.load()
        }
        .task(id: viewModel.playbackLoadID) {
            if let playback = viewModel.playback {
                playbackCoordinator.configure(with: playback)
            } else {
                playbackCoordinator.reset()
            }
        }
        .onDisappear {
            viewModel.stop()
            playbackCoordinator.stop()
        }
    }
}

private extension PlayerScreen {
    var standardPlayerColumnMaxWidth: CGFloat {
        980
    }

    var playback: VideoPlayback? {
        viewModel.playback
    }

    var usesImmersiveLayout: Bool {
        layoutState.isTheaterMode || layoutState.isFullscreen
    }

    var displayTitle: String {
        playback?.title ?? video.title
    }

    var displayChannel: String? {
        playback?.channel ?? video.channel
    }

    var recommendations: [VideoItem] {
        playback?.recommendations ?? []
    }

    var comments: [CommentItem] {
        viewModel.comments
    }

    var commentHeaderText: String {
        if let count = viewModel.commentCountText, !count.isEmpty {
            return "\(count) comments"
        }
        return "Comments"
    }

    var metadataPills: [String] {
        var items: [String] = []
        if let views = playback?.viewCountText ?? video.viewCountText {
            items.append(views)
        }
        if let likes = playback?.likeCountText {
            items.append("\(likes) likes")
        }
        if let published = playback?.publishedDateText ?? playback?.publishedTimeText ?? video.publishedTimeText {
            items.append(published)
        }
        if let duration = playback?.durationText ?? video.durationText {
            items.append(duration)
        }
        return items
    }

    var scrollContent: some View {
        VStack(alignment: .leading, spacing: usesImmersiveLayout ? 24 : 0) {
            if layoutState.isFullscreen {
                Color.clear
                    .frame(height: 0)
            } else if usesImmersiveLayout {
                immersiveContent
            } else {
                standardContent
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var immersiveContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            headerSection
            descriptionSection
            commentsSection
            recommendationsColumn
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    var standardContent: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                mainColumn
                    .frame(maxWidth: standardPlayerColumnMaxWidth, alignment: .leading)
                recommendationsColumn
                    .frame(width: 360)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 24) {
                mainColumn
                    .frame(maxWidth: standardPlayerColumnMaxWidth, alignment: .leading)
                recommendationsColumn
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var mainColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            standardPlayerStagePlaceholder
            headerSection
            descriptionSection
            commentsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var standardPlayerStagePlaceholder: some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(Color.clear)
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .anchorPreference(key: StandardPlayerStageBoundsPreferenceKey.self, value: .bounds) { $0 }
    }

    var headerSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(displayTitle)
                .font(.system(size: 30, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 18) {
                ChannelSummary(
                    avatarURL: playback?.channelAvatarURL,
                    channel: displayChannel,
                    subscriberCount: playback?.subscriberCountText
                )

                Spacer(minLength: 12)

                if let publishedTime = playback?.publishedTimeText, !publishedTime.isEmpty {
                    Text(publishedTime)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !metadataPills.isEmpty {
                FlexiblePillRow(items: metadataPills)
            }
        }
    }

    var descriptionSection: some View {
        DetailCard(title: "Description") {
            VStack(alignment: .leading, spacing: 16) {
                if let description = playback?.description, !description.isEmpty {
                    ExpandableDescription(
                        text: description,
                        isExpanded: $isDescriptionExpanded
                    )
                } else {
                    Text("No description available for this video yet.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var commentsSection: some View {
        DetailCard(title: commentHeaderText) {
            VStack(alignment: .leading, spacing: 18) {
                if viewModel.isLoadingComments && comments.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading comments...")
                            .foregroundStyle(.secondary)
                    }
                } else if comments.isEmpty {
                    Text("Comments aren’t available for this video right now.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(comments) { comment in
                        CommentRow(comment: comment)
                        if comment.id != comments.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    var recommendationsColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Up next")
                .font(.title3)
                .fontWeight(.semibold)

            if recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .frame(height: 108)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(recommendations, id: \.id) { relatedVideo in
                        Button {
                            navigation.showVideo(relatedVideo)
                        } label: {
                            RecommendationRow(video: relatedVideo)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlayerStageHost: View {
    @ObservedObject var coordinator: PlayerPlaybackCoordinator
    let isLoading: Bool
    let errorMessage: String?
    let immersive: Bool
    let retry: () -> Void

    private var displayedErrorMessage: String? {
        errorMessage ?? coordinator.errorMessage
    }

    var body: some View {
        let stage = PlayerStageSurface(
            coordinator: coordinator,
            isLoading: isLoading,
            errorMessage: displayedErrorMessage,
            immersive: immersive,
            retry: retry
        )

        Group {
            if immersive {
                stage
                    .frame(maxWidth: .infinity)
            } else {
                stage
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.18), radius: 22, y: 10)
            }
        }
        .padding(.horizontal, immersive ? 0 : 24)
        .padding(.top, immersive ? 0 : 24)
        .padding(.bottom, immersive ? 24 : 0)
        .background(
            immersive
                ? Color.black.opacity(0.96)
                : Color.clear
        )
    }
}

private struct StandardPlayerStageOverlay: View {
    @ObservedObject var coordinator: PlayerPlaybackCoordinator
    let isLoading: Bool
    let errorMessage: String?
    let rect: CGRect
    let retry: () -> Void

    var body: some View {
        if rect.width > 1, rect.height > 1 {
            PlayerStageSurface(
                coordinator: coordinator,
                isLoading: isLoading,
                errorMessage: errorMessage,
                immersive: false,
                retry: retry
            )
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .shadow(color: .black.opacity(0.18), radius: 22, y: 10)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
        }
    }
}

private struct PlayerStageSurface: View {
    @ObservedObject var coordinator: PlayerPlaybackCoordinator
    let isLoading: Bool
    let errorMessage: String?
    let immersive: Bool
    let retry: () -> Void

    private var activeAVPlayer: AVPlayer? {
        coordinator.activeRenderState?.avPlayer
    }

    private var pendingAVPlayer: AVPlayer? {
        coordinator.pendingRenderState?.avPlayer
    }

    private var activeMPVEngine: MPVPlaybackEngine? {
        coordinator.activeRenderState?.mpvEngine
    }

    private var pendingMPVEngine: MPVPlaybackEngine? {
        guard let pending = coordinator.pendingRenderState?.mpvEngine else { return nil }
        guard pending.id != coordinator.activeRenderState?.mpvEngine?.id else { return nil }
        return pending
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.94))

            if let activeMPVEngine {
                MPVMetalRenderView(engine: activeMPVEngine, onLayoutChange: {
                    coordinator.handlePlayerGeometryChange()
                })
            }

            if let pendingMPVEngine {
                MPVMetalRenderView(engine: pendingMPVEngine, onLayoutChange: {
                    coordinator.handlePlayerGeometryChange()
                })
                .opacity(0.001)
                .allowsHitTesting(false)
            }

            if let activeAVPlayer {
                PlayerRenderView(player: activeAVPlayer, onLayoutChange: {
                    coordinator.handlePlayerGeometryChange()
                })
            }

            if let pendingAVPlayer {
                PlayerRenderView(player: pendingAVPlayer, onLayoutChange: {
                    coordinator.handlePlayerGeometryChange()
                })
                .opacity(0.001)
                .allowsHitTesting(false)
            }

            if coordinator.shouldShowPlaybackErrorOverlay,
               let errorMessage {
                PlayerStageErrorOverlay(message: errorMessage, retry: retry)
            } else if coordinator.shouldShowPlaybackLoadingOverlay {
                if coordinator.player == nil {
                    PlayerStageLoadingOverlay(text: isLoading ? "Loading video..." : coordinator.playbackLoadingText)
                } else {
                    PlayerInlineLoadingOverlay(text: coordinator.playbackLoadingText)
                }
            }

            if coordinator.activeRenderState != nil {
                PlayerChromeOverlay(
                    coordinator: coordinator,
                    edgeToEdge: immersive
                )
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .onHover { hovering in
            coordinator.setHovering(hovering)
        }
        .onContinuousHover { phase in
            if case .active = phase {
                coordinator.handlePointerMovement()
            }
        }
    }
}

private struct PlayerStageLoadingOverlay: View {
    let text: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.15)
            Text(text)
                .font(.headline)
        }
        .tint(.white)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct PlayerStageErrorOverlay: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.slash.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white.opacity(0.85))
            Text(message)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
            Button("Retry") {
                retry()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PlayerChromeOverlay: View {
    @ObservedObject var coordinator: PlayerPlaybackCoordinator
    let edgeToEdge: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.55), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 120)

                Spacer(minLength: 0)

                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 170)
            }
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    PlayerStatusPill(text: coordinator.playbackBadgeText)

                    if coordinator.selectedSubtitleOptionID != SubtitleOption.offID,
                       coordinator.hasSubtitleOptions {
                        PlayerStatusPill(text: coordinator.subtitleControlText)
                    }

                    Spacer()
                }
                .padding(.horizontal, edgeToEdge ? 20 : 18)
                .padding(.top, edgeToEdge ? 20 : 18)

                Spacer()

                PlayerControlBar(coordinator: coordinator)
                    .padding(.horizontal, edgeToEdge ? 20 : 18)
                    .padding(.bottom, edgeToEdge ? 20 : 18)
            }
        }
        .opacity(coordinator.controlsVisible ? 1 : 0)
        .allowsHitTesting(coordinator.controlsVisible)
        .animation(.linear(duration: 0.1), value: coordinator.controlsVisible)
    }
}

private struct PlayerControlBar: View {
    @ObservedObject var coordinator: PlayerPlaybackCoordinator
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var playPauseNamespace
    @State private var isQualityPopoverPresented = false

    private let compactControlHeight: CGFloat = 38
    private let circularButtonLabelSize: CGFloat = 30
    private let qualityButtonMinWidth: CGFloat = 104
    private let volumeIconContentHeight: CGFloat = 22
    private let timeLabelWidth: CGFloat = 54

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                playPauseButton
                volumeControl
                Spacer(minLength: 0)
                subtitlesButton
                qualityMenu
                theaterToggle
                fullscreenButton
            }

            scrubberControl
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var playPauseButton: some View {
        Button {
            coordinator.togglePlayback()
        } label: {
            circularButtonLabel(symbol: coordinator.isPlaying ? "pause.fill" : "play.fill", fontSize: 15)
        }
        .buttonStyle(.glass(.regular.interactive()))
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .glassEffectID("playback-control", in: playPauseNamespace)
        .glassEffectTransition(.matchedGeometry)
        .accessibilityLabel(coordinator.isPlaying ? "Pause" : "Play")
    }

    var volumeControl: some View {
        HStack(spacing: 8) {
            Button {
                coordinator.toggleMute()
            } label: {
                Image(systemName: coordinator.volumeIconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 20, height: volumeIconContentHeight)
                    .frame(minHeight: compactControlHeight)
                    .contentShape(Rectangle())
                    .animation(.snappy(duration: 0.11, extraBounce: 0), value: coordinator.volumeIconName)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(coordinator.volume <= 0.01 ? "Unmute" : "Mute")

            Slider(
                value: Binding(
                    get: { coordinator.volume },
                    set: { newValue in
                        coordinator.volume = newValue
                        coordinator.handlePointerMovement()
                    }
                ),
                in: 0...1
            )
            .frame(width: 112)
            .accessibilityLabel("Volume")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: compactControlHeight)
        .playerControlSurface(
            reduceTransparency: reduceTransparency,
            glass: .regular,
            shape: Capsule()
        )
    }

    var scrubberControl: some View {
        HStack(spacing: 12) {
            Text(coordinator.currentTimeText)
                .frame(width: timeLabelWidth, alignment: .leading)

            Slider(
                value: Binding(
                    get: { coordinator.scrubPosition },
                    set: { coordinator.updateScrubPosition($0) }
                ),
                in: 0...coordinator.scrubberUpperBound,
                onEditingChanged: { isEditing in
                    coordinator.setScrubbing(isEditing)
                }
            )
            .disabled(coordinator.duration <= 0)
            .accessibilityLabel("Playback position")

            Text(coordinator.remainingTimeText)
                .frame(width: timeLabelWidth, alignment: .trailing)
        }
        .font(.caption.weight(.medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: compactControlHeight)
        .playerControlSurface(
            reduceTransparency: reduceTransparency,
            glass: .regular,
            shape: Capsule()
        )
    }

    var subtitlesButton: some View {
        Button {
            coordinator.cycleSubtitles()
        } label: {
            circularButtonLabel(
                symbol: coordinator.subtitleSymbolName,
                fontSize: 14,
                foregroundStyle: coordinator.hasSubtitleOptions ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
            )
        }
        .buttonStyle(.glass(.regular.interactive()))
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .disabled(!coordinator.hasSubtitleOptions)
        .accessibilityLabel("Subtitles")
        .accessibilityValue(coordinator.subtitleAccessibilityValue)
    }

    var qualityMenu: some View {
        Button {
            isQualityPopoverPresented.toggle()
        } label: {
            qualityButtonLabel
        }
        .buttonStyle(.glass(.regular.interactive()))
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .popover(
            isPresented: $isQualityPopoverPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            qualityPopoverContent
        }
        .onChange(of: isQualityPopoverPresented) { _, isPresented in
            if isPresented {
                coordinator.beginMenuInteraction()
            } else {
                coordinator.endMenuInteraction()
            }
        }
        .accessibilityLabel("Quality")
        .accessibilityValue(coordinator.qualityControlText)
    }

    var qualityButtonLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "dial.medium")
                .font(.system(size: 13, weight: .semibold))

            Text(coordinator.qualityControlText)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: qualityButtonMinWidth)
        .frame(height: circularButtonLabelSize)
        .fixedSize(horizontal: true, vertical: false)
    }

    var qualityPopoverContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(coordinator.qualityOptions) { option in
                    qualityMenuOptionButton(for: option)
                }
            }
            .padding(8)
        }
        .frame(minWidth: 260)
    }

    func qualityMenuOptionButton(for option: QualityOption) -> some View {
        Button {
            coordinator.selectQuality(option)
            isQualityPopoverPresented = false
        } label: {
            qualityMenuRow(for: option)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            option.id == coordinator.qualityControlSelectionID
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear
                        )
                )
        }
        .buttonStyle(.plain)
    }

    var theaterToggle: some View {
        Button {
            coordinator.toggleTheaterMode()
        } label: {
            circularButtonLabel(symbol: coordinator.theaterSymbolName, fontSize: 14)
        }
        .buttonStyle(.glass(.regular.interactive()))
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .accessibilityLabel("Theater Mode")
        .accessibilityValue(coordinator.isTheaterMode ? "On" : "Off")
    }

    var fullscreenButton: some View {
        Button {
            coordinator.toggleFullscreen()
        } label: {
            circularButtonLabel(symbol: coordinator.fullscreenSymbolName, fontSize: 14)
        }
        .buttonStyle(.glass(.regular.interactive()))
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .accessibilityLabel(coordinator.isFullscreen ? "Exit Fullscreen" : "Fullscreen")
        .accessibilityValue(coordinator.isFullscreen ? "On" : "Off")
    }

    @ViewBuilder
    func qualityMenuRow(for option: QualityOption) -> some View {
        HStack(spacing: 10) {
            Image(systemName: option.id == coordinator.qualityControlSelectionID ? "checkmark" : "circle")
                .foregroundStyle(option.id == coordinator.qualityControlSelectionID ? Color.accentColor : .secondary)

            Text(option.title)

            Spacer(minLength: 12)

            if let detail = option.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 220, alignment: .leading)
    }

    func circularButtonLabel(
        symbol: String,
        fontSize: CGFloat = 18,
        foregroundStyle: AnyShapeStyle = AnyShapeStyle(.primary)
    ) -> some View {
        Image(systemName: symbol)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(foregroundStyle)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: circularButtonLabelSize, height: circularButtonLabelSize)
            .animation(.snappy(duration: 0.11, extraBounce: 0), value: symbol)
    }
}

private struct PlayerStatusPill: View {
    let text: String
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .playerControlSurface(
                reduceTransparency: reduceTransparency,
                glass: .regular,
                shape: Capsule()
            )
    }
}

private struct PlayerInlineLoadingOverlay: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()

            HStack(spacing: 10) {
                ProgressView()
                Text(text)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.black.opacity(0.72))
            )

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }
}

private struct DetailCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

private struct ChannelSummary: View {
    let avatarURL: URL?
    let channel: String?
    let subscriberCount: String?

    var body: some View {
        HStack(spacing: 14) {
            CachedAsyncImage(url: avatarURL) {
                Circle()
                    .fill(Color.gray.opacity(0.28))
                    .overlay(
                        Image(systemName: "person.fill")
                            .foregroundStyle(.secondary)
                    )
            }
            .frame(width: 54, height: 54)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(channel ?? "Unknown channel")
                    .font(.headline)
                if let subscriberCount, !subscriberCount.isEmpty {
                    Text(subscriberCount)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct FlexiblePillRow: View {
    let items: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color(NSColor.controlBackgroundColor))
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ExpandableDescription: View {
    let text: String
    @Binding var isExpanded: Bool

    private var shouldShowToggle: Bool {
        text.count > 260
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(isExpanded ? nil : 5)
                .fixedSize(horizontal: false, vertical: true)

            if shouldShowToggle {
                Button(isExpanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CommentRow: View {
    let comment: CommentItem

    private var footerItems: [String] {
        var items: [String] = []
        if let likeCount = comment.likeCountText, !likeCount.isEmpty {
            items.append("\(likeCount) likes")
        }
        if let replyCount = comment.replyCountText, !replyCount.isEmpty {
            items.append("\(replyCount) replies")
        }
        return items
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CachedAsyncImage(url: comment.avatarURL) {
                Circle()
                    .fill(Color.gray.opacity(0.28))
                    .overlay(
                        Image(systemName: "person.fill")
                            .foregroundStyle(.secondary)
                    )
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(comment.author)
                        .font(.subheadline.weight(.semibold))
                    if let published = comment.publishedTimeText, !published.isEmpty {
                        Text(published)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let pinned = comment.pinnedText, !pinned.isEmpty {
                        Text(pinned)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                    }
                }

                Text(comment.body)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                if !footerItems.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(footerItems, id: \.self) { item in
                            Text(item)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RecommendationRow: View {
    let video: VideoItem

    private var statsLine: String {
        let parts = [video.channel, video.viewCountText, video.publishedTimeText]
            .compactMap { $0 }
        return parts.joined(separator: " • ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: video.thumbnailURL) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.secondary)
                        )
                }
                .frame(width: 210)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                if let duration = video.durationText {
                    Text(duration)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.74))
                        )
                        .foregroundStyle(.white)
                        .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(video.title)
                    .font(.headline)
                    .lineLimit(2)
                if !statsLine.isEmpty {
                    Text(statsLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .contentShape(Rectangle())
    }
}

private extension View {
    @ViewBuilder
    func playerControlSurface<S: Shape>(
        reduceTransparency: Bool,
        glass: Glass,
        shape: S
    ) -> some View {
        if reduceTransparency {
            self
                .background(
                    shape
                        .fill(Color.black.opacity(0.82))
                        .overlay(
                            shape.stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
        } else {
            self.glassEffect(glass, in: shape)
        }
    }
}
