import AVKit
import SwiftUI

struct PlayerRenderView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        nsView.controlsStyle = .none
        nsView.showsFullScreenToggleButton = false
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
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}

final class WindowResolverView: NSView {
    var onResolve: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onResolve?(window)
    }
}

struct PlayerScreen: View {
    let video: VideoItem

    @StateObject private var viewModel: PlayerViewModel
    @StateObject private var playbackCoordinator = PlayerPlaybackCoordinator()
    @State private var isDescriptionExpanded = false
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var authSession: AuthSessionModel

    init(video: VideoItem) {
        self.video = video
        _viewModel = StateObject(wrappedValue: PlayerViewModel(video: video))
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: playbackCoordinator.isTheaterMode ? 24 : 0) {
                    if playbackCoordinator.isTheaterMode {
                        playerStage(
                            viewportHeight: proxy.size.height,
                            edgeToEdge: true
                        )

                        VStack(alignment: .leading, spacing: 24) {
                            headerSection
                            descriptionSection
                            commentsSection
                            recommendationsColumn
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    } else {
                        contentLayout(
                            for: proxy.size.width,
                            viewportHeight: proxy.size.height
                        )
                        .padding(24)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(
                Color(NSColor.windowBackgroundColor)
                    .ignoresSafeArea()
            )
            .background(
                WindowAccessor { window in
                    playbackCoordinator.setWindow(window)
                }
                .frame(width: 0, height: 0)
            )
        }
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
    var playback: VideoPlayback? {
        viewModel.playback
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

    var blockingPlayerError: String? {
        if playbackCoordinator.player == nil {
            return viewModel.errorMessage ?? playbackCoordinator.errorMessage
        }
        return viewModel.errorMessage
    }

    @ViewBuilder
    func contentLayout(for width: CGFloat, viewportHeight: CGFloat) -> some View {
        let isWideLayout = width >= 1_280
        let railWidth = min(max(width * 0.28, 320), 400)

        if isWideLayout {
            HStack(alignment: .top, spacing: 24) {
                mainColumn(viewportHeight: viewportHeight)
                recommendationsColumn
                    .frame(width: railWidth)
            }
        } else {
            VStack(alignment: .leading, spacing: 24) {
                mainColumn(viewportHeight: viewportHeight)
                recommendationsColumn
            }
        }
    }

    func mainColumn(viewportHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            playerStage(
                viewportHeight: viewportHeight,
                edgeToEdge: false
            )
            headerSection
            descriptionSection
            commentsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func playerStage(viewportHeight: CGFloat, edgeToEdge: Bool) -> some View {
        let stage = ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.94))

            if let player = playbackCoordinator.player {
                PlayerRenderView(player: player)
                    .onDisappear {
                        player.pause()
                    }
            }

            if viewModel.isLoading, playbackCoordinator.player == nil {
                playerLoadingOverlay
            } else if let error = blockingPlayerError, playbackCoordinator.player == nil {
                playerErrorOverlay(message: error)
            } else if playbackCoordinator.isPreparing, playbackCoordinator.player != nil {
                PlayerInlineLoadingOverlay()
            }

            if let player = playbackCoordinator.player {
                PlayerChromeOverlay(
                    coordinator: playbackCoordinator,
                    player: player,
                    edgeToEdge: edgeToEdge
                )
            }
        }
        .onHover { hovering in
            if hovering {
                playbackCoordinator.handleHoverEntry()
            }
        }
        .onContinuousHover { phase in
            if case .active = phase {
                playbackCoordinator.handlePointerMovement()
            }
        }

        if edgeToEdge {
            stage
                .frame(maxWidth: .infinity)
                .frame(height: viewportHeight)
        } else {
            stage
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .shadow(color: .black.opacity(0.18), radius: 22, y: 10)
        }
    }

    var playerLoadingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.15)
            Text("Loading video...")
                .font(.headline)
        }
        .tint(.white)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func playerErrorOverlay(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "play.slash.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white.opacity(0.85))
            Text(message)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
            Button("Retry") {
                viewModel.load()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private struct PlayerChromeOverlay: View {
    @ObservedObject var coordinator: PlayerPlaybackCoordinator
    let player: AVPlayer
    let edgeToEdge: Bool

    var body: some View {
        ZStack {
            if coordinator.controlsVisible {
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
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: coordinator.controlsVisible)
    }
}

private struct PlayerControlBar: View {
    @ObservedObject var coordinator: PlayerPlaybackCoordinator
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var playPauseNamespace

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                playPauseButton
                volumeControl
                scrubberControl
                subtitlesButton
                qualityMenu
                theaterToggle
                fullscreenButton
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 30)
                    .fill(Color.black.opacity(0.84))
                    .overlay(
                        RoundedRectangle(cornerRadius: 30)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
        }
    }

    var playPauseButton: some View {
        Button {
            coordinator.togglePlayback()
        } label: {
            ZStack {
                if coordinator.isPlaying {
                    controlIcon(symbol: "pause.fill")
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.horizontal, 8)
                        .playerControlSurface(
                            reduceTransparency: reduceTransparency,
                            glass: .regular.interactive(),
                            shape: Capsule()
                        )
                        .glassEffectID("playback-control", in: playPauseNamespace)
                        .glassEffectTransition(.matchedGeometry)
                } else {
                    controlIcon(symbol: "play.fill")
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.horizontal, 8)
                        .playerControlSurface(
                            reduceTransparency: reduceTransparency,
                            glass: .regular.interactive(),
                            shape: Capsule()
                        )
                        .glassEffectID("playback-control", in: playPauseNamespace)
                        .glassEffectTransition(.matchedGeometry)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(coordinator.isPlaying ? "Pause" : "Play")
    }

    var volumeControl: some View {
        HStack(spacing: 10) {
            Button {
                coordinator.toggleMute()
            } label: {
                Image(systemName: coordinator.volumeIconName)
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .playerControlSurface(
                reduceTransparency: reduceTransparency,
                glass: .regular.interactive(),
                shape: Capsule()
            )
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
            .frame(width: 132)
            .accessibilityLabel("Volume")
        }
        .padding(.leading, 2)
        .padding(.trailing, 12)
        .frame(minHeight: 44)
        .playerControlSurface(
            reduceTransparency: reduceTransparency,
            glass: .regular,
            shape: Capsule()
        )
    }

    var scrubberControl: some View {
        HStack(spacing: 12) {
            Text(coordinator.currentTimeText)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)

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
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 44)
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
            Image(systemName: coordinator.subtitleSymbolName)
                .font(.system(size: 16, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, 8)
                .playerControlSurface(
                    reduceTransparency: reduceTransparency,
                    glass: .regular.interactive(),
                    shape: Capsule()
                )
        }
        .buttonStyle(.plain)
        .disabled(!coordinator.hasSubtitleOptions)
        .opacity(coordinator.hasSubtitleOptions ? 1 : 0.55)
        .accessibilityLabel("Subtitles")
        .accessibilityValue(coordinator.subtitleAccessibilityValue)
    }

    var qualityMenu: some View {
        Menu {
            ForEach(coordinator.qualityOptions) { option in
                Button {
                    coordinator.selectQuality(option)
                } label: {
                    qualityMenuRow(for: option)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "dial.medium")
                    .font(.system(size: 14, weight: .semibold))

                VStack(alignment: .leading, spacing: 1) {
                    Text(coordinator.qualityControlText)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    if let detail = coordinator.qualityControlDetail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .playerControlSurface(
                reduceTransparency: reduceTransparency,
                glass: .regular.interactive(),
                shape: Capsule()
            )
        }
        .menuStyle(.borderlessButton)
        .simultaneousGesture(
            TapGesture().onEnded {
                coordinator.beginMenuInteraction()
            }
        )
        .accessibilityLabel("Quality")
        .accessibilityValue(coordinator.qualityControlText)
    }

    var theaterToggle: some View {
        Toggle(
            isOn: Binding(
                get: { coordinator.isTheaterMode },
                set: { isOn in
                    coordinator.isTheaterMode = isOn
                    coordinator.handlePointerMovement()
                }
            )
        ) {
            Image(systemName: coordinator.isTheaterMode ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                .font(.system(size: 16, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, 8)
                .playerControlSurface(
                    reduceTransparency: reduceTransparency,
                    glass: .regular.interactive(),
                    shape: Capsule()
                )
        }
        .toggleStyle(.button)
        .accessibilityLabel("Theater Mode")
        .accessibilityValue(coordinator.isTheaterMode ? "On" : "Off")
    }

    var fullscreenButton: some View {
        Button {
            coordinator.toggleFullscreen()
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 15, weight: .semibold))
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, 8)
                .playerControlSurface(
                    reduceTransparency: reduceTransparency,
                    glass: .regular.interactive(),
                    shape: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fullscreen")
    }

    @ViewBuilder
    func qualityMenuRow(for option: QualityOption) -> some View {
        HStack(spacing: 10) {
            Image(systemName: option.id == coordinator.selectedQualityOptionID ? "checkmark" : "circle")
                .foregroundStyle(option.id == coordinator.selectedQualityOptionID ? Color.accentColor : .secondary)

            Text(option.title)

            Spacer(minLength: 12)

            if let detail = option.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 220, alignment: .leading)
    }

    func controlIcon(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
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
    var body: some View {
        VStack {
            Spacer()

            HStack(spacing: 10) {
                ProgressView()
                Text("Updating player...")
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
