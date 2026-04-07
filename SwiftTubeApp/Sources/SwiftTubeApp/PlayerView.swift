import AppKit
import SwiftUI

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

private struct ManagedPopoverPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    let preferredEdge: NSRectEdge
    let contentSize: CGSize
    let content: AnyView
    let onDismiss: () -> Void

    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.anchorView = view
        return view
    }

    @MainActor
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.anchorView = nsView
        context.coordinator.onDismiss = {
            DispatchQueue.main.async {
                onDismiss()
                if isPresented {
                    isPresented = false
                }
            }
        }
        context.coordinator.update(
            isPresented: isPresented,
            preferredEdge: preferredEdge,
            contentSize: contentSize,
            content: content
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        weak var anchorView: NSView?
        let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        let popover = NSPopover()
        var onDismiss: (() -> Void)?

        override init() {
            super.init()
            popover.contentViewController = hostingController
            popover.behavior = .transient
            popover.animates = true
            popover.delegate = self
        }

        func update(
            isPresented: Bool,
            preferredEdge: NSRectEdge,
            contentSize: CGSize,
            content: AnyView
        ) {
            hostingController.rootView = content

            if popover.contentSize != contentSize {
                NSAnimationContext.runAnimationGroup { context in
                    context.allowsImplicitAnimation = true
                    context.duration = 0.30
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    popover.contentSize = contentSize
                }
            }

            guard let anchorView else { return }

            if isPresented {
                if popover.isShown {
                    popover.contentViewController?.view.needsLayout = true
                } else {
                    DispatchQueue.main.async { [weak self, weak anchorView] in
                        guard let self, let anchorView, self.popover.isShown == false else { return }
                        self.popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: preferredEdge)
                    }
                }
            } else if popover.isShown {
                popover.performClose(nil)
            }
        }

        func popoverDidClose(_ notification: Notification) {
            onDismiss?()
        }
    }
}


private struct PlayerSurfaceBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private enum PlayerSidePanelTab: String, CaseIterable, Identifiable {
    case suggestions
    case liveChat

    var id: String { rawValue }

    func title(liveChatTitle: String) -> String {
        switch self {
        case .suggestions:
            return "Suggestions"
        case .liveChat:
            return liveChatTitle
        }
    }
}

struct PlayerScreen: View {
    let video: VideoItem
    let libraryPlaylists: [PlaylistSummary]

    @StateObject private var viewModel: PlayerViewModel
    @StateObject private var layoutState: PlayerLayoutState
    @State private var playbackCoordinator: PlayerPlaybackCoordinator
    @State private var isDescriptionExpanded = false
    @State private var isSharePopoverPresented = false
    @State private var isPlaylistPopoverPresented = false
    @State private var isPlaylistRailExpanded = true
    @State private var selectedSidePanelTab: PlayerSidePanelTab = .suggestions
    @State private var playerStageHeight: CGFloat = 0
    @State private var headerSectionHeight: CGFloat = 0
    @ObservedObject private var mutationCenter = AppMutationCenter.shared
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var authSession: AuthSessionModel

    init(video: VideoItem, libraryPlaylists: [PlaylistSummary]) {
        self.video = video
        self.libraryPlaylists = libraryPlaylists
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
            (layoutState.isFullscreen ? Color.black : AppSettings.shared.windowBackgroundColor)
                .ignoresSafeArea()
        )
        .overlayPreferenceValue(PlayerSurfaceBoundsKey.self) { anchor in
            GeometryReader { proxy in
                if let rect = surfaceRect(anchor: anchor, proxy: proxy) {
                    let errorMessage = viewModel.errorMessage ?? playbackCoordinator.errorMessage
                    PlayerStageSurface(
                        coordinator: playbackCoordinator,
                        isLoading: viewModel.isLoading,
                        errorMessage: errorMessage,
                        immersive: usesImmersiveLayout,
                        retry: viewModel.load
                    )
                    .clipShape(RoundedRectangle(cornerRadius: usesImmersiveLayout ? 0 : 22))
                    .shadow(color: usesImmersiveLayout ? .clear : .black.opacity(0.18), radius: 22, y: 10)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .overlay(alignment: .trailing) {
            if layoutState.isFullscreen, layoutState.isSidePanelVisible {
                fullscreenSidePanel
                    .frame(width: secondaryPanelWidth)
                    .padding(.vertical, 18)
                    .padding(.trailing, 18)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
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
                if let startTime = navigation.consumePendingStartTime(for: video.id) {
                    playbackCoordinator.setInitialStartTime(startTime)
                } else if let resumeStartTime = playback.resumeStartTimeSeconds {
                    playbackCoordinator.setInitialStartTime(resumeStartTime)
                }
                playbackCoordinator.updateSponsorSegments(playback.sponsorSegments)
                playbackCoordinator.configure(with: playback)
                selectedSidePanelTab = defaultSidePanelTab(for: playback)
                if playback.liveChat?.isReplay == true {
                    viewModel.syncReplayChat(to: playback.resumeStartTimeSeconds ?? 0, force: true)
                }
                if authSession.status.authenticated, playback.playlistSaveEnabled {
                    viewModel.loadPlaylistOptions()
                }
            } else {
                playbackCoordinator.reset()
            }
        }
        .onChange(of: viewModel.playback?.sponsorSegments ?? []) { _, segments in
            playbackCoordinator.updateSponsorSegments(segments)
        }
        .onChange(of: playbackCoordinator.isScrubbing) { wasScrubbing, isScrubbing in
            guard wasScrubbing, !isScrubbing else { return }
            guard viewModel.playback?.liveChat?.isReplay == true else { return }
            viewModel.syncReplayChat(to: playbackCoordinator.scrubPosition, force: true)
        }
        .onChange(of: selectedSidePanelTab) { _, tab in
            guard tab == .liveChat else { return }
            guard viewModel.playback?.liveChat?.isReplay == true else { return }
            viewModel.syncReplayChat(to: playbackCoordinator.currentTime, force: true)
        }
        .task(id: "\(video.id)-\(viewModel.playbackLoadID.uuidString)-progress") {
            await monitorPlaybackProgress()
        }
        .onAppear {
            playbackCoordinator.onPlaybackEnded = handlePlaybackEnded
            playbackCoordinator.onShortcutAction = handleShortcutAction
            navigation.setActivePlaylistCurrentVideo(video.id)
        }
        .onDisappear {
            viewModel.reportPlaybackProgress(
                currentTime: playbackCoordinator.currentTime,
                duration: playbackCoordinator.duration,
                didFinish: false
            )
            viewModel.stop()
            playbackCoordinator.stop()
            playbackCoordinator.onShortcutAction = nil
        }
    }
}

private extension PlayerScreen {
    var standardPlayerColumnMaxWidth: CGFloat {
        980
    }

    var secondaryPanelWidth: CGFloat {
        368
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
        viewModel.recommendations
    }

    var playlistUserLibrary: [PlaylistSummary] {
        libraryPlaylists.filter { !["WL", "LL"].contains($0.playlistId) }
    }

    var activePlaylistFeed: PlaylistFeed? {
        navigation.activePlaylistFeed
    }

    var hasActivePlaylistContext: Bool {
        navigation.activePlaylistReference != nil
            && navigation.activePlaylistItems.contains(where: { $0.id == video.id })
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

    var statsOverviewItems: [(title: String, value: String)] {
        var items: [(String, String)] = []

        if let views = playback?.viewCountText ?? video.viewCountText, !views.isEmpty {
            items.append(("Views", views))
        }
        if let published = playback?.publishedDateText ?? playback?.publishedTimeText ?? video.publishedTimeText, !published.isEmpty {
            items.append(("Uploaded", published))
        }

        return items
    }

    var displayTags: [VideoTag] {
        if let playback {
            return playback.tags.filter { tag in
                tag.isLive == false || playback.isLive
            }
        }
        return video.tags.filter { !$0.isLive }
    }

    var playbackAccessIssue: VideoAccessIssue? {
        playback?.accessIssue
    }

    var effectiveSidePanelTab: PlayerSidePanelTab {
        if selectedSidePanelTab == .liveChat, playback?.liveChat == nil {
            return .suggestions
        }
        return selectedSidePanelTab
    }

    var usesTabbedSidePanel: Bool {
        playback?.liveChat != nil
    }

    var liveChatTabTitle: String {
        playback?.liveChat?.tabTitle ?? "Live Chat"
    }

    var standardLiveChatHeight: CGFloat {
        let measuredPrimaryHeight = playerStageHeight > 0 && headerSectionHeight > 0
            ? playerStageHeight + 24 + headerSectionHeight
            : 0
        if measuredPrimaryHeight > 0 {
            return max(measuredPrimaryHeight - 14, 500)
        }

        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let windowHeight = NSApp.keyWindow?.contentLayoutRect.height ?? screenHeight
        let availableHeight = min(screenHeight, windowHeight)
        return min(max(availableHeight - 164, 600), 940)
    }

    var scrollContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if layoutState.isFullscreen {
                // Fullscreen: surface fills viewport via surfaceRect
                Color.clear.frame(height: 0)
            } else if layoutState.isTheaterMode {
                // Transparent spacer reserves the 16:9 slot for the overlay.
                // Must be clear — a black spacer would show below the overlay when scrolled.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .anchorPreference(key: PlayerSurfaceBoundsKey.self, value: .bounds) { $0 }

                standardContent
                    .padding(24)
            } else {
                standardContent
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var standardContent: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                mainColumn
                    .frame(maxWidth: standardPlayerColumnMaxWidth, alignment: .leading)
                sidePanel
                    .frame(width: secondaryPanelWidth)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 24) {
                mainColumn
                    .frame(maxWidth: standardPlayerColumnMaxWidth, alignment: .leading)
                sidePanel
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var mainColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !layoutState.isTheaterMode {
                standardPlayerStagePlaceholder
            }
            headerSection
            descriptionSection
            commentsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func surfaceRect(anchor: Anchor<CGRect>?, proxy: GeometryProxy) -> CGRect? {
        if layoutState.isFullscreen {
            let sideInset = layoutState.isSidePanelVisible ? secondaryPanelWidth + 32 : 0
            return CGRect(
                x: 0,
                y: 0,
                width: max(proxy.size.width - sideInset, 0),
                height: proxy.size.height
            )
        }
        if layoutState.isTheaterMode, let anchor {
            let anchorRect = proxy[anchor]
            let w = proxy.size.width
            let h = min(w * 9.0 / 16.0, proxy.size.height)
            return CGRect(x: 0, y: anchorRect.minY, width: w, height: h)
        }
        return anchor.map { proxy[$0] }
    }

    var standardPlayerStagePlaceholder: some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(Color.clear)
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { playerStageHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in
                            playerStageHeight = height
                        }
                }
            )
            .anchorPreference(key: PlayerSurfaceBoundsKey.self, value: .bounds) { $0 }
    }

    var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(displayTitle)
                .font(.system(size: 24, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)

            if !displayTags.isEmpty || !statsOverviewItems.isEmpty {
                compactStatsRow
            }

            if let accessIssue = playbackAccessIssue {
                PlayerAccessIssueBanner(issue: accessIssue)
            }

            channelAndActionsSection
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { headerSectionHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, height in
                        headerSectionHeight = height
                    }
            }
        )
    }

    var sidePanel: some View {
        Group {
            if usesTabbedSidePanel {
                WatchSecondaryPanel(
                    isFullscreen: layoutState.isFullscreen,
                    selectedTab: Binding(
                        get: { effectiveSidePanelTab },
                        set: { selectedSidePanelTab = $0 }
                    ),
                    liveChatContent: AnyView(liveChatPanelContent),
                    suggestionsContent: AnyView(suggestionsPanelContent),
                    liveChatTitle: liveChatTabTitle,
                    standardLiveChatHeight: standardLiveChatHeight
                )
            } else {
                suggestionsPanelContent
            }
        }
    }

    var fullscreenSidePanel: some View {
        sidePanel
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.black.opacity(0.86))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.34), radius: 24, y: 10)
    }

    var channelAndActionsSection: some View {
        HStack(alignment: .center, spacing: 18) {
            channelSubscriptionCluster
                .layoutPriority(1)

            Spacer(minLength: 16)

            actionToolbar
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var channelSubscriptionCluster: some View {
        HStack(alignment: .center, spacing: 12) {
            ChannelSummary(
                avatarURL: playback?.channelAvatarURL,
                channel: displayChannel,
                subscriberCount: playback?.subscription?.subscriberCountText ?? playback?.subscriberCountText,
                onOpenChannel: {
                    guard let channel = playback?.channelReference else { return }
                    navigation.showChannel(channel)
                }
            )

            subscribeButton
        }
    }

    var actionToolbar: some View {
        HStack(spacing: 8) {
            likeDislikeControl
            shareButton
            watchLaterButton
            playlistButton
        }
        .padding(.vertical, 2)
    }

    var subscribeButton: some View {
        let subscription = playback?.subscription
        let isSubscribed = subscription?.subscribed == true

        return Button {
            viewModel.toggleSubscription()
        } label: {
            HStack(spacing: 10) {
                Text(isSubscribed ? "Subscribed" : "Subscribe")
                    .font(.subheadline.weight(.bold))
            }
            .foregroundStyle(isSubscribed ? Color.primary : Color.black)
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(
                Capsule()
                    .fill(isSubscribed ? Color.white.opacity(0.14) : Color.white)
            )
            .overlay(
                Capsule()
                    .stroke(isSubscribed ? Color.white.opacity(0.18) : Color.white.opacity(0.75), lineWidth: 1)
            )
            .shadow(color: isSubscribed ? .clear : .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .opacity((subscription?.enabled == true) ? 1 : 0.5)
        .disabled(subscription?.enabled != true)
    }

    var likeDislikeControl: some View {
        let rating = playback?.rating
        let isLiked = rating?.status == "LIKE"
        let isDisliked = rating?.status == "DISLIKE"

        return HStack(spacing: 0) {
            Button {
                viewModel.toggleRating("like")
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                    Text(rating?.likeCountText ?? playback?.likeCountText ?? "Like")
                        .lineLimit(1)
                }
                .font(.subheadline.weight(.semibold))
                .frame(height: 36)
                .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isLiked ? Color.blue : Color.white)

            Divider()
                .frame(height: 22)
                .overlay(Color.white.opacity(0.18))

            Button {
                viewModel.toggleRating("dislike")
            } label: {
                Image(systemName: isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .frame(width: 42, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isDisliked ? Color.blue : Color.white)
        }
        .background(
            Capsule()
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .fixedSize(horizontal: true, vertical: false)
        .opacity(rating == nil ? 0.55 : 1)
        .disabled(rating == nil)
    }

    var shareButton: some View {
        Button {
            isPlaylistPopoverPresented = false
            withAnimation(.easeOut(duration: 0.2)) {
                isSharePopoverPresented.toggle()
            }
        } label: {
            playerActionPill(symbol: "square.and.arrow.up", title: "Share", showsChevron: true)
        }
        .buttonStyle(.plain)
        .background {
            ManagedPopoverPresenter(
                isPresented: $isSharePopoverPresented,
                preferredEdge: .minY,
                contentSize: CGSize(width: 220, height: 96),
                content: AnyView(sharePopoverContent),
                onDismiss: { isSharePopoverPresented = false }
            )
            .allowsHitTesting(false)
        }
    }

    var watchLaterButton: some View {
        let isSaved = playback?.watchLater?.saved == true

        return Button {
            viewModel.toggleWatchLater()
        } label: {
            playerActionPill(
                symbol: isSaved ? "clock.fill" : "clock",
                title: isSaved ? "Saved" : "Watch later",
                isActive: isSaved
            )
        }
        .buttonStyle(.plain)
        .opacity(playback?.watchLater == nil ? 0.55 : 1)
        .disabled(playback?.watchLater == nil)
    }

    var playlistButton: some View {
        Button {
            guard playback?.playlistSaveEnabled == true else { return }
            if viewModel.playlistOptions.isEmpty {
                viewModel.loadPlaylistOptions()
            }
            isSharePopoverPresented = false
            withAnimation(.easeOut(duration: 0.2)) {
                isPlaylistPopoverPresented.toggle()
            }
        } label: {
            playerActionPill(
                symbol: "text.badge.plus",
                title: "Save to playlist",
                showsChevron: true
            )
        }
        .buttonStyle(.plain)
        .disabled(playback?.playlistSaveEnabled != true)
        .opacity(playback?.playlistSaveEnabled == true ? 1 : 0.55)
        .background {
            ManagedPopoverPresenter(
                isPresented: $isPlaylistPopoverPresented,
                preferredEdge: .minY,
                contentSize: playlistPopoverSize,
                content: AnyView(playlistPopoverContent),
                onDismiss: { isPlaylistPopoverPresented = false }
            )
            .allowsHitTesting(false)
        }
    }

    func playerActionPill(
        symbol: String,
        title: String,
        isActive: Bool = false,
        showsChevron: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
            Text(title)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isActive ? Color.blue : Color.white)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(
            Capsule()
                .fill(Color.white.opacity(isActive ? 0.13 : 0.08))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .fixedSize(horizontal: true, vertical: false)
    }

    var compactStatsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(displayTags) { tag in
                    VideoTagBadgeView(tag: tag, font: .system(size: 13, weight: .semibold))
                }

                ForEach(Array(statsOverviewItems.enumerated()), id: \.offset) { _, item in
                    CompactVideoStatPill(title: item.title, value: item.value)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var sharePopoverContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            playerPopoverAction(title: "Copy Link", symbol: "link") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(shareURL.absoluteString, forType: .string)
                isSharePopoverPresented = false
            }

            playerPopoverAction(title: "Open in YouTube", symbol: "safari") {
                NSWorkspace.shared.open(shareURL)
                isSharePopoverPresented = false
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var playlistPopoverSize: CGSize {
        CGSize(width: 280, height: min(max(CGFloat(max(viewModel.playlistOptions.count, 1)) * 42 + 24, 96), 320))
    }

    var playlistPopoverContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if viewModel.isLoadingPlaylistOptions {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading playlists...")
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            } else if viewModel.playlistOptions.isEmpty {
                Text("No playlists available")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ForEach(viewModel.playlistOptions) { option in
                    playerPopoverPlaylistRow(option: option)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func playerPopoverAction(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 16)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    func playerPopoverPlaylistRow(option: PlaylistOption) -> some View {
        Button {
            viewModel.togglePlaylist(option)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: option.saved ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(option.saved ? Color.blue : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .lineLimit(1)
                    if let privacy = option.privacy, !privacy.isEmpty {
                        Text(privacy.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if mutationCenter.isPending(MutationQueueKey.playlist(videoID: video.id, playlistID: option.id)) {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(option.saved ? Color.blue.opacity(0.14) : Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    var shareURL: URL {
        var components = URLComponents(string: "https://youtube.com/watch")!
        let seconds = max(0, Int(playbackCoordinator.currentTime.rounded(.down)))
        components.queryItems = [
            URLQueryItem(name: "v", value: playback?.id ?? video.id),
            URLQueryItem(name: "t", value: String(seconds))
        ]
        return components.url!
    }

    var descriptionSection: some View {
        DetailCard(title: nil) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Description")
                    .font(.headline.weight(.bold))

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

    func handleShortcutAction(_ action: PlayerKeyAction) {
        switch action {
        case .likeVideo:
            viewModel.toggleRating("like")
        case .dislikeVideo:
            viewModel.toggleRating("dislike")
        case .watchLater:
            viewModel.toggleWatchLater()
        case .saveToPlaylist:
            guard playback?.playlistSaveEnabled == true else { return }
            if viewModel.playlistOptions.isEmpty {
                viewModel.loadPlaylistOptions()
            }
            isSharePopoverPresented = false
            withAnimation(.easeOut(duration: 0.2)) {
                isPlaylistPopoverPresented.toggle()
            }
        case .subscribe:
            viewModel.toggleSubscription()
        case .share:
            isPlaylistPopoverPresented = false
            withAnimation(.easeOut(duration: 0.2)) {
                isSharePopoverPresented.toggle()
            }
        case .playPause, .seekShortBack, .seekShortForward, .seekMediumBack, .seekMediumForward, .seekLongBack, .seekLongForward, .frameBack, .frameForward, .theaterMode, .fullscreen, .subtitles:
            break
        }
    }

    var commentsSection: some View {
        DetailCard(title: commentHeaderText) {
            LazyVStack(alignment: .leading, spacing: 18) {
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
                            .onAppear {
                                viewModel.loadMoreCommentsIfNeeded(currentComment: comment)
                            }
                        if comment.id != comments.last?.id {
                            Divider()
                        }
                    }

                    if viewModel.isLoadingComments {
                        ProgressView("Loading more comments...")
                            .padding(.top, 4)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    func playlistQueueColumn(feed: PlaylistFeed) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if isPlaylistRailExpanded {
                expandedPlaylistQueue(feed: feed)
            } else {
                collapsedPlaylistQueue(feed: feed)
            }
        }
    }

    func expandedPlaylistQueue(feed: PlaylistFeed) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(feed.title)
                        .font(.title3.weight(.bold))

                    if !navigation.activePlaylistDetailsLine.isEmpty {
                        Text(navigation.activePlaylistDetailsLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(activePlaylistPositionLine)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary.opacity(0.88))
                }

                Spacer(minLength: 12)

                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        isPlaylistRailExpanded = false
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.headline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    navigation.cycleActivePlaylistLoopMode()
                } label: {
                    Label(navigation.activePlaylistLoopMode.title, systemImage: navigation.activePlaylistLoopMode.symbolName)
                }
                .buttonStyle(.bordered)

                Button {
                    navigation.toggleActivePlaylistShuffle()
                } label: {
                    Label(
                        navigation.activePlaylistShuffleEnabled ? "Shuffle On" : "Shuffle Off",
                        systemImage: "shuffle"
                    )
                }
                .buttonStyle(.bordered)
                .tint(navigation.activePlaylistShuffleEnabled ? .blue : nil)
            }

            Divider()
                .overlay(Color.white.opacity(0.06))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(navigation.activePlaylistItems.enumerated()), id: \.element) { index, queueVideo in
                        PlaylistQueueDropZone {
                            moveQueueVideo(withID: $0, toInsertionIndex: index)
                        }

                        Button {
                            navigation.showVideo(queueVideo)
                        } label: {
                            PlaylistQueueRailRow(
                                video: queueVideo,
                                index: index + 1,
                                isCurrent: navigation.activePlaylistCurrentVideoID == queueVideo.id,
                                canReorder: canReorderQueueVideo(queueVideo)
                            )
                        }
                        .buttonStyle(.plain)
                        .draggable(queueVideo.id)
                        .contextMenu {
                            VideoContextMenuContent(
                                video: queueVideo,
                                userPlaylists: movablePlaylistsForQueue(),
                                onPlay: { navigation.showVideo(queueVideo) },
                                onPlayFromHere: { navigation.showVideo(queueVideo) },
                                onAddToWatchLater: navigation.activePlaylistReference?.kind == .watchLater ? nil : queueAddToWatchLater(videoID: queueVideo.id),
                                onSaveToPlaylist: { playlistID in
                                    queueSaveToPlaylist(videoID: queueVideo.id, playlistID: playlistID)
                                },
                                onMoveToPlaylist: queueVideo.playlistCanRemove ? { playlistID in
                                    moveQueueVideo(queueVideo, to: playlistID)
                                } : nil,
                                onMoveToWatchLater: navigation.activePlaylistReference?.kind == .watchLater || !queueVideo.playlistCanRemove ? nil : {
                                    moveQueueVideoToWatchLater(queueVideo)
                                },
                                onRemoveFromCurrentPlaylist: queueVideo.playlistCanRemove ? { removeQueueVideo(queueVideo) } : nil,
                                onMoveToTop: queueVideo.playlistCanMoveToTop ? { moveQueueVideo(queueVideo, position: "top") } : nil,
                                onMoveToBottom: queueVideo.playlistCanMoveToBottom ? { moveQueueVideo(queueVideo, position: "bottom") } : nil,
                                onRemoveFromWatchHistory: nil
                            )
                        }
                        .padding(.bottom, 6)
                    }

                    PlaylistQueueDropZone {
                        moveQueueVideo(withID: $0, toInsertionIndex: navigation.activePlaylistItems.count)
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(height: playlistRailHeight)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(AppSettings.shared.cardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    func collapsedPlaylistQueue(feed: PlaylistFeed) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                isPlaylistRailExpanded = true
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(queueCollapsedTitle(feed: feed))
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    Text(activePlaylistPositionLine)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Image(systemName: "chevron.down")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.blue.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    func handlePlaybackEnded() {
        viewModel.reportPlaybackProgress(
            currentTime: playbackCoordinator.currentTime,
            duration: playbackCoordinator.duration,
            didFinish: true
        )

        if navigation.activePlaylistLoopMode == .one {
            playbackCoordinator.restartPlayback()
            return
        }

        guard let nextVideo = navigation.nextVideoForActivePlaylist() else { return }
        navigation.showVideo(nextVideo)
    }

    func removeQueueVideo(_ video: VideoItem) {
        guard let playlistID = navigation.activePlaylistReference?.playlistId,
              let setVideoId = video.playlistSetVideoId else { return }

        let previousItems = navigation.activePlaylistItems

        mutationCenter.submit(
            key: MutationQueueKey.playlistMembership(playlistID: playlistID, setVideoID: setVideoId),
            successNotice: MutationNotice(
                title: "Removed from \(navigation.activePlaylistTitle ?? "playlist")",
                message: nil,
                symbol: "trash",
                accent: .green
            ),
            errorNotice: { error in
                MutationNotice(
                    title: "Couldn’t update playlist",
                    message: error.localizedDescription,
                    symbol: "trash",
                    accent: .red
                )
            },
            optimistic: {
                navigation.replaceActivePlaylistItems(
                    previousItems.filter { $0.playlistSetVideoId != setVideoId }
                )
            },
            rollback: { _ in
                navigation.replaceActivePlaylistItems(previousItems)
            },
            execute: {
                _ = try await BackendClient.shared.removePlaylistItem(
                    playlistId: playlistID,
                    setVideoId: setVideoId
                )
            }
        )
    }

    func monitorPlaybackProgress() async {
        guard viewModel.playback != nil else { return }

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            guard viewModel.playback != nil else { continue }

            viewModel.reportPlaybackProgress(
                currentTime: playbackCoordinator.currentTime,
                duration: playbackCoordinator.duration,
                didFinish: false
            )
        }
    }

    func moveQueueVideo(_ video: VideoItem, position: String) {
        guard let playlistID = navigation.activePlaylistReference?.playlistId,
              let setVideoId = video.playlistSetVideoId else { return }

        let previousItems = navigation.activePlaylistItems

        mutationCenter.submit(
            key: MutationQueueKey.playlistPosition(playlistID: playlistID, setVideoID: setVideoId),
            successNotice: MutationNotice(
                title: position == "top" ? "Moved to top" : "Moved to bottom",
                message: nil,
                symbol: position == "top" ? "arrow.up.to.line" : "arrow.down.to.line",
                accent: .green
            ),
            errorNotice: { error in
                MutationNotice(
                    title: "Couldn’t reorder playlist",
                    message: error.localizedDescription,
                    symbol: "arrow.up.arrow.down",
                    accent: .red
                )
            },
            optimistic: {
                navigation.replaceActivePlaylistItems(reorderedQueue(previousItems, moving: video, position: position))
            },
            rollback: { _ in
                navigation.replaceActivePlaylistItems(previousItems)
            },
            execute: {
                _ = try await BackendClient.shared.reorderPlaylistItem(
                    playlistId: playlistID,
                    setVideoId: setVideoId,
                    position: position
                )
            }
        )
    }

    func moveQueueVideo(withID draggedID: String, toInsertionIndex insertionIndex: Int) -> Bool {
        guard let playlistID = navigation.activePlaylistReference?.playlistId else { return false }

        let previousItems = navigation.activePlaylistItems
        guard let sourceIndex = previousItems.firstIndex(where: { $0.id == draggedID }) else {
            return false
        }

        let updated = reorderedQueue(previousItems, sourceIndex: sourceIndex, insertionIndex: insertionIndex)
        guard updated != previousItems else { return false }

        mutationCenter.submit(
            key: MutationQueueKey.playlistOrder(playlistID: playlistID),
            successNotice: MutationNotice(
                title: "Playlist order updated",
                message: nil,
                symbol: "arrow.up.arrow.down",
                accent: .green
            ),
            errorNotice: { error in
                MutationNotice(
                    title: "Couldn’t save playlist order",
                    message: error.localizedDescription,
                    symbol: "arrow.up.arrow.down",
                    accent: .red
                )
            },
            optimistic: {
                navigation.replaceActivePlaylistItems(updated)
            },
            rollback: { _ in
                navigation.replaceActivePlaylistItems(previousItems)
            },
            execute: {
                try await syncQueueOrder(updated, playlistId: playlistID)
            }
        )

        return true
    }

    func moveQueueVideo(_ video: VideoItem, to playlistID: String) {
        guard let currentPlaylistID = navigation.activePlaylistReference?.playlistId,
              let setVideoId = video.playlistSetVideoId else { return }

        let previousItems = navigation.activePlaylistItems
        let destinationTitle = playlistUserLibrary.first(where: { $0.playlistId == playlistID })?.title ?? "playlist"

        mutationCenter.submit(
            key: MutationQueueKey.playlistMembership(playlistID: currentPlaylistID, setVideoID: setVideoId),
            successNotice: MutationNotice(
                title: "Moved to \(destinationTitle)",
                message: nil,
                symbol: "folder.fill",
                accent: .green
            ),
            errorNotice: { error in
                MutationNotice(
                    title: "Couldn’t move video",
                    message: error.localizedDescription,
                    symbol: "folder",
                    accent: .red
                )
            },
            optimistic: {
                navigation.replaceActivePlaylistItems(
                    previousItems.filter { $0.playlistSetVideoId != setVideoId }
                )
            },
            rollback: { _ in
                navigation.replaceActivePlaylistItems(previousItems)
            },
            execute: {
                _ = try await BackendClient.shared.updatePlaylist(
                    id: video.id,
                    playlistId: playlistID,
                    saved: true
                )
                _ = try await BackendClient.shared.removePlaylistItem(
                    playlistId: currentPlaylistID,
                    setVideoId: setVideoId
                )
            }
        )
    }

    func moveQueueVideoToWatchLater(_ video: VideoItem) {
        guard let currentPlaylistID = navigation.activePlaylistReference?.playlistId,
              let setVideoId = video.playlistSetVideoId else { return }

        let previousItems = navigation.activePlaylistItems

        mutationCenter.submit(
            key: MutationQueueKey.playlistMembership(playlistID: currentPlaylistID, setVideoID: setVideoId),
            successNotice: MutationNotice(
                title: "Moved to Watch Later",
                message: nil,
                symbol: "clock.fill",
                accent: .green
            ),
            errorNotice: { error in
                MutationNotice(
                    title: "Couldn’t move video",
                    message: error.localizedDescription,
                    symbol: "clock",
                    accent: .red
                )
            },
            optimistic: {
                navigation.replaceActivePlaylistItems(
                    previousItems.filter { $0.playlistSetVideoId != setVideoId }
                )
            },
            rollback: { _ in
                navigation.replaceActivePlaylistItems(previousItems)
            },
            execute: {
                _ = try await BackendClient.shared.updateWatchLater(id: video.id, saved: true)
                _ = try await BackendClient.shared.removePlaylistItem(
                    playlistId: currentPlaylistID,
                    setVideoId: setVideoId
                )
            }
        )
    }

    func reorderedQueue(_ items: [VideoItem], moving video: VideoItem, position: String) -> [VideoItem] {
        guard let index = items.firstIndex(where: { $0.playlistSetVideoId == video.playlistSetVideoId }) else {
            return items
        }

        var updated = items
        let moved = updated.remove(at: index)
        if position == "top" {
            updated.insert(moved, at: 0)
        } else {
            updated.append(moved)
        }
        return updated
    }

    func reorderedQueue(_ items: [VideoItem], sourceIndex: Int, insertionIndex: Int) -> [VideoItem] {
        guard items.indices.contains(sourceIndex) else { return items }

        var updated = items
        let moved = updated.remove(at: sourceIndex)
        let targetIndex = sourceIndex < insertionIndex ? max(insertionIndex - 1, 0) : insertionIndex
        updated.insert(moved, at: min(max(targetIndex, 0), updated.count))
        return updated
    }

    func syncQueueOrder(_ items: [VideoItem], playlistId: String) async throws {
        for queueVideo in items.reversed() {
            guard let setVideoId = queueVideo.playlistSetVideoId else { continue }
            _ = try await BackendClient.shared.reorderPlaylistItem(
                playlistId: playlistId,
                setVideoId: setVideoId,
                position: "top"
            )
        }
    }

    func canReorderQueueVideo(_ video: VideoItem) -> Bool {
        video.playlistSetVideoId != nil
    }

    var playlistRailHeight: CGFloat {
        420
    }

    var activePlaylistPositionLine: String {
        let count = navigation.activePlaylistItems.count
        guard count > 0 else { return "Playlist queue" }

        if let currentID = navigation.activePlaylistCurrentVideoID,
           let currentIndex = navigation.activePlaylistItems.firstIndex(where: { $0.id == currentID }) {
            return "\(navigation.activePlaylistTitle ?? "Playlist") • \(currentIndex + 1) / \(count)"
        }

        return "\(navigation.activePlaylistTitle ?? "Playlist") • \(count) videos"
    }

    func queueCollapsedTitle(feed: PlaylistFeed) -> String {
        if let nextVideo = navigation.nextVideoForActivePlaylist(), nextVideo.id != video.id {
            return "Next: \(nextVideo.title)"
        }
        return feed.title
    }

    func movablePlaylistsForQueue() -> [PlaylistSummary] {
        let currentPlaylistID = navigation.activePlaylistReference?.playlistId
        return playlistUserLibrary.filter { $0.playlistId != currentPlaylistID }
    }

    func queueAddToWatchLater(videoID: String) -> () -> Void {
        {
            mutationCenter.submit(
                key: MutationQueueKey.watchLater(videoID: videoID),
                successNotice: MutationNotice(
                    title: "Added to Watch Later",
                    message: nil,
                    symbol: "clock.fill",
                    accent: .green
                ),
                errorNotice: { error in
                    MutationNotice(
                        title: "Couldn’t update Watch Later",
                        message: error.localizedDescription,
                        symbol: "clock",
                        accent: .red
                    )
                },
                optimistic: {},
                execute: {
                    _ = try await BackendClient.shared.updateWatchLater(id: videoID, saved: true)
                }
            )
        }
    }

    func queueSaveToPlaylist(videoID: String, playlistID: String) {
        let playlistTitle = playlistUserLibrary.first(where: { $0.playlistId == playlistID })?.title ?? "playlist"
        mutationCenter.submit(
            key: MutationQueueKey.playlist(videoID: videoID, playlistID: playlistID),
            successNotice: MutationNotice(
                title: "Saved to \(playlistTitle)",
                message: nil,
                symbol: "music.note.list",
                accent: .green
            ),
            errorNotice: { error in
                MutationNotice(
                    title: "Couldn’t save to \(playlistTitle)",
                    message: error.localizedDescription,
                    symbol: "music.note.list",
                    accent: .red
                )
            },
            optimistic: {},
            execute: {
                _ = try await BackendClient.shared.updatePlaylist(
                    id: videoID,
                    playlistId: playlistID,
                    saved: true
                )
            }
        )
    }

    func defaultSidePanelTab(for playback: VideoPlayback) -> PlayerSidePanelTab {
        if playback.liveChat != nil {
            return .liveChat
        }
        return .suggestions
    }

    var suggestionsPanelContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if hasActivePlaylistContext, let activePlaylistFeed {
                playlistQueueColumn(feed: activePlaylistFeed)
            }

            if recommendations.isEmpty {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(NSColor.controlBackgroundColor).opacity(0.55))
                            .frame(height: 92)
                    }
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(recommendations, id: \.id) { relatedVideo in
                        RecommendationRow(
                            video: relatedVideo,
                            onOpenChannel: {
                                guard let channel = relatedVideo.channelReference else { return }
                                navigation.showChannel(channel)
                            }
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                        .onTapGesture {
                            navigation.showVideo(relatedVideo)
                        }
                        .contextMenu {
                            VideoContextMenuContent(
                                video: relatedVideo,
                                userPlaylists: playlistUserLibrary,
                                onPlay: { navigation.showVideo(relatedVideo) },
                                onPlayFromHere: nil,
                                onAddToWatchLater: authSession.status.authenticated ? queueAddToWatchLater(videoID: relatedVideo.id) : nil,
                                onSaveToPlaylist: authSession.status.authenticated ? { playlistID in
                                    queueSaveToPlaylist(videoID: relatedVideo.id, playlistID: playlistID)
                                } : nil,
                                onMoveToPlaylist: nil,
                                onMoveToWatchLater: nil,
                                onRemoveFromCurrentPlaylist: nil,
                                onMoveToTop: nil,
                                onMoveToBottom: nil,
                                onRemoveFromWatchHistory: nil
                            )
                        }
                        .onAppear {
                            viewModel.loadMoreRecommendationsIfNeeded(currentVideo: relatedVideo)
                        }
                    }

                    if viewModel.isLoadingRecommendations {
                        ProgressView("Loading more videos...")
                            .padding(.top, 4)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var transcriptPanelContent: some View {
        Group {
            if viewModel.isLoadingTranscript && viewModel.transcriptSegments.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading transcript...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = viewModel.transcriptErrorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if viewModel.transcriptSegments.isEmpty {
                Text("A transcript isn’t available for this video.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.transcriptSegments) { segment in
                            Button {
                                playbackCoordinator.seek(to: segment.startTime)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(transcriptTimestamp(segment.startTime))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                    Text(segment.text)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(AppSettings.shared.cardBackgroundColor.opacity(0.78))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    var liveChatPanelContent: some View {
        LiveChatPanel(
            messages: viewModel.liveChatMessages,
            composer: viewModel.liveChatComposer,
            isLoading: viewModel.isLoadingLiveChat,
            errorMessage: viewModel.liveChatErrorMessage,
            onSend: { viewModel.sendLiveChatMessage($0) }
        )
    }

    func transcriptTimestamp(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds.rounded(.down))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secondsPart = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secondsPart)
        }
        return String(format: "%d:%02d", minutes, secondsPart)
    }
}

@MainActor
private final class LiveChatUsernameColorStore: ObservableObject {
    static let shared = LiveChatUsernameColorStore()

    @Published private var colors: [String: Color] = [:]
    private var loadingKeys: Set<String> = []

    func color(for avatarURL: URL?, fallbackKey: String) -> Color {
        if let key = avatarURL?.absoluteString, let cached = colors[key] {
            return cached
        }
        return fallbackColor(for: fallbackKey)
    }

    func loadColor(for avatarURL: URL?, fallbackKey: String) async {
        guard let avatarURL else { return }
        let key = avatarURL.absoluteString
        guard colors[key] == nil, loadingKeys.contains(key) == false else { return }
        loadingKeys.insert(key)
        defer { loadingKeys.remove(key) }

        do {
            let (data, _) = try await URLSession.shared.data(from: avatarURL)
            guard let bitmap = NSBitmapImageRep(data: data) else {
                colors[key] = fallbackColor(for: fallbackKey)
                return
            }

            let stepX = max(bitmap.pixelsWide / 8, 1)
            let stepY = max(bitmap.pixelsHigh / 8, 1)
            var red = 0.0
            var green = 0.0
            var blue = 0.0
            var count = 0.0

            for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.alphaComponent < 0.2 { continue }
                    red += Double(color.redComponent)
                    green += Double(color.greenComponent)
                    blue += Double(color.blueComponent)
                    count += 1
                }
            }

            guard count > 0 else {
                colors[key] = fallbackColor(for: fallbackKey)
                return
            }

            let averaged = Color(
                hue: normalizedHue(red / count, green / count, blue / count),
                saturation: 0.55,
                brightness: 0.92
            )
            colors[key] = averaged
        } catch {
            colors[key] = fallbackColor(for: fallbackKey)
        }
    }

    private func normalizedHue(_ red: Double, _ green: Double, _ blue: Double) -> Double {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue
        guard delta > 0.0001 else { return 0.62 }

        let rawHue: Double
        if maxValue == red {
            rawHue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxValue == green {
            rawHue = ((blue - red) / delta) + 2
        } else {
            rawHue = ((red - green) / delta) + 4
        }

        let hue = rawHue / 6
        return hue >= 0 ? hue : hue + 1
    }

    private func fallbackColor(for key: String) -> Color {
        let hash = abs(key.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.56, brightness: 0.9)
    }
}

private struct WatchSecondaryPanel: View {
    @ObservedObject private var settings = AppSettings.shared
    let isFullscreen: Bool
    @Binding var selectedTab: PlayerSidePanelTab
    let liveChatContent: AnyView
    let suggestionsContent: AnyView
    let liveChatTitle: String
    let standardLiveChatHeight: CGFloat
    @State private var tabBarHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                secondaryPanelTab(.suggestions, enabled: true)
                secondaryPanelTab(.liveChat, enabled: true)
            }
            .padding(4)
            .background(
                GeometryReader { proxy in
                    Capsule(style: .continuous)
                        .fill(settings.sidebarBackgroundColor.opacity(0.88))
                        .onAppear { tabBarHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in
                            tabBarHeight = height
                        }
                }
            )

            panelContent
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var panelContent: some View {
        if isFullscreen {
            switch selectedTab {
            case .suggestions:
                ScrollView {
                    suggestionsContent
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .liveChat:
                liveChatCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            switch selectedTab {
            case .suggestions:
                suggestionsContent
            case .liveChat:
                VStack(alignment: .leading, spacing: 16) {
                    liveChatCard
                        .frame(height: max(standardLiveChatHeight - tabBarHeight - 14, 320))
                    suggestionsContent
                }
            }
        }
    }

    private var liveChatCard: some View {
        liveChatContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(settings.cardBackgroundColor.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
    }

    private func secondaryPanelTab(_ tab: PlayerSidePanelTab, enabled: Bool) -> some View {
        Button {
            guard enabled else { return }
            withAnimation(.snappy(duration: 0.18, extraBounce: 0)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 8) {
                if selectedTab == tab {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                }
                Text(tab.title(liveChatTitle: liveChatTitle))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(selectedTab == tab ? Color.black : (enabled ? Color.primary : Color.secondary.opacity(0.7)))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(selectedTab == tab ? Color.white : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct LiveChatPanel: View {
    @ObservedObject private var settings = AppSettings.shared
    let messages: [LiveChatMessage]
    let composer: LiveChatComposer?
    let isLoading: Bool
    let errorMessage: String?
    let onSend: (String) -> Void

    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isLoading && messages.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Connecting to live chat...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, messages.isEmpty {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if messages.isEmpty {
                        Text("Live chat hasn’t started yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(messages) { message in
                                    LiveChatMessageRow(message: message)
                                }
                                Color.clear
                                    .frame(height: 1)
                                    .id("live-chat-bottom")
                            }
                        }
                        .onAppear {
                            proxy.scrollTo("live-chat-bottom", anchor: .bottom)
                        }
                        .onChange(of: messages.map(\.id)) { _, _ in
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo("live-chat-bottom", anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let composer, let sendParams = composer.sendParams, sendParams.isEmpty == false {
                Divider()
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        TextField(composer.placeholder ?? "Type to chat...", text: $draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.body)
                            .lineLimit(1...4)
                            .onSubmit(sendDraft)

                        Button {
                            NSApp.orderFrontCharacterPalette(nil)
                        } label: {
                            Image(systemName: "face.smiling")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        Button(action: sendDraft) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : BrandAssets.youtubeRed)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if let errorMessage, !errorMessage.isEmpty {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(BrandAssets.youtubeRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
            } else if let restrictedMessage = composer?.restrictedMessage, !restrictedMessage.isEmpty {
                Divider()
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                Label(restrictedMessage, systemImage: "play.rectangle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(BrandAssets.youtubeRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(BrandAssets.youtubeRed.opacity(settings.preferredColorScheme == .dark ? 0.14 : 0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(BrandAssets.youtubeRed.opacity(0.26), lineWidth: 1)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func sendDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        onSend(trimmed)
        draft = ""
    }
}

private struct LiveChatMessageRow: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var colorStore = LiveChatUsernameColorStore.shared
    let message: LiveChatMessage

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Group {
                if let author = displayAuthor, !author.isEmpty {
                    Text("\(authorText(author))\(Text(": ").foregroundColor(.secondary))\(bodyText)")
                } else {
                    bodyText.foregroundColor(message.kind == .system ? BrandAssets.youtubeRed : .secondary)
                }
            }
            Spacer(minLength: 0)
            if let hoverTimestampText, isHovered {
                Text(hoverTimestampText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .font(.system(size: 15, weight: .medium))
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(rowBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(rowBorderColor, lineWidth: showsBorder ? 1 : 0)
        )
        .opacity(message.isPending ? 0.68 : 1)
        .scaleEffect(isHovered && message.kind != .system ? 1.004 : 1)
        .shadow(color: .black.opacity(isHovered && message.kind != .system ? 0.08 : 0), radius: 12, y: 6)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .task {
            await colorStore.loadColor(for: message.avatarURL, fallbackKey: message.author ?? message.id)
        }
    }

    private func authorText(_ author: String) -> Text {
        var text = Text(author)
            .foregroundColor(resolvedAuthorColor)
        if message.isOwner || message.isModerator || message.isVerified {
            text = text.fontWeight(.bold)
        }
        return text
    }

    private var bodyText: Text {
        let initial = message.purchaseAmountText.map {
            Text("\($0) ")
                .foregroundColor(Color(red: 1.0, green: 0.79, blue: 0.36))
                .fontWeight(.bold)
        } ?? Text("")

        return message.fragments.reduce(initial) { partial, fragment in
            Text("\(partial)\(styledText(for: fragment))")
        }
    }

    private var hoverTimestampText: String? {
        guard let timestampUsec = message.timestampUsec,
              let micros = Double(timestampUsec) else {
            return nil
        }

        let date = Date(timeIntervalSince1970: micros / 1_000_000)
        return Self.timestampFormatter.string(from: date)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private func styledText(for fragment: LiveChatMessageFragment) -> Text {
        if message.kind == .system {
            return Text(fragment.text)
                .foregroundColor(BrandAssets.youtubeRed)
                .fontWeight(.semibold)
        }

        switch fragment.kind {
        case .mention:
            return Text(fragment.text)
                .foregroundColor(Color(red: 0.62, green: 0.56, blue: 0.98))
                .fontWeight(.semibold)
        case .link:
            return Text(fragment.text)
                .foregroundColor(Color(red: 0.56, green: 0.69, blue: 1.0))
        case .emoji:
            return Text(fragment.text)
                .foregroundColor(.primary)
        case .text:
            return Text(fragment.text)
                .foregroundColor(.primary)
        }
    }

    private var resolvedAuthorColor: Color {
        colorStore.color(for: message.avatarURL, fallbackKey: message.author ?? message.id)
    }

    private var displayAuthor: String? {
        guard let author = message.author?.trimmingCharacters(in: .whitespacesAndNewlines),
              author.isEmpty == false else {
            return nil
        }
        return author.hasPrefix("@") ? String(author.dropFirst()) : author
    }

    private var rowBackgroundColor: Color {
        if message.kind == .system {
            return BrandAssets.youtubeRed.opacity(settings.preferredColorScheme == .dark ? 0.14 : 0.10)
        }
        return isHovered ? settings.hoverCardBackgroundColor : .clear
    }

    private var rowBorderColor: Color {
        if message.kind == .system {
            return BrandAssets.youtubeRed.opacity(0.24)
        }
        if isHovered {
            return Color.white.opacity(settings.preferredColorScheme == .dark ? 0.10 : 0.16)
        }
        return .clear
    }

    private var showsBorder: Bool {
        message.kind == .system || isHovered
    }
}

private func feedbackID(_ feedback: ActionFeedback) -> String {
    switch feedback {
    case .play: return "play"
    case .pause: return "pause"
    case .seekForward: return "seek-fwd"
    case .seekBackward: return "seek-bwd"
    case .frameForward: return "frame-fwd"
    case .frameBackward: return "frame-bwd"
    }
}

private struct PlayerStageSurface: View {
    @ObservedObject var coordinator: PlayerPlaybackCoordinator
    @State private var hoverExitTask: Task<Void, Never>? = nil
    @FocusState private var isFocused: Bool
    let isLoading: Bool
    let errorMessage: String?
    let immersive: Bool
    let retry: () -> Void

    var body: some View {
        GeometryReader { geo in
            let pad = Self.sidePad(for: geo.size, aspect: coordinator.videoAspect)

            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.94))

                if let engine = coordinator.mpvEngine {
                    MPVMetalRenderView(engine: engine, onLayoutChange: {})
                }

                // During scrubbing, cover the video with a storyboard tile scaled to
                // fill — same image data the hover popup uses, already cached, instant.
                if coordinator.isScrubbing, let spec = coordinator.storyboard {
                    ScrubVideoOverlay(
                        spec: spec,
                        time: coordinator.scrubPosition,
                        containerSize: geo.size
                    )
                        .allowsHitTesting(false)
                }

                if coordinator.shouldShowPlaybackErrorOverlay,
                   let errorMessage {
                    PlayerStageErrorOverlay(message: errorMessage, retry: retry)
                } else if coordinator.shouldShowPlaybackLoadingOverlay {
                    PlayerStageLoadingOverlay(text: isLoading ? "Loading video..." : coordinator.playbackLoadingText)
                } else if coordinator.didReachPlaybackEnd {
                    PlayerStageEndedOverlay {
                        coordinator.restartPlayback()
                    }
                }

                // Tap-to-toggle layer. Hover enter/exit is tracked on the
                // parent ZStack so moving to child controls doesn't trigger
                // a spurious exit. onContinuousHover here tracks pointer
                // position for letterbox filtering and auto-hide reset.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        coordinator.togglePlayback()
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let touchingFullscreenEdge = coordinator.isFullscreen
                                && (location.x <= 2 || location.x >= geo.size.width - 2)
                            if touchingFullscreenEdge {
                                coordinator.setHovering(false)
                                break
                            }
                            let inVideo = pad < 1 || (location.x >= pad && location.x <= geo.size.width - pad)
                            if inVideo {
                                if coordinator.controlsVisible == false {
                                    coordinator.setHovering(true)
                                }
                                coordinator.handlePointerMovement()
                            }
                        case .ended:
                            break
                        }
                    }

                if let feedback = coordinator.actionFeedback {
                    ActionFeedbackOverlay(feedback: feedback, generation: coordinator.feedbackGeneration)
                        .id(feedbackID(feedback))
                        .allowsHitTesting(false)
                }

                if coordinator.mpvEngine != nil {
                    PlayerChromeOverlay(
                        coordinator: coordinator,
                        edgeToEdge: immersive,
                        sidePad: pad
                    )
                }

                if let segment = coordinator.manualSkipSponsorSegment {
                    SponsorBlockManualSkipOverlay(
                        segment: segment,
                        skip: coordinator.skipManualSponsorSegment
                    )
                    .padding(.trailing, (immersive ? 22 : 18) + pad)
                    .padding(.leading, (immersive ? 22 : 18) + pad)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if coordinator.keyboardLocked {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {}
                }

                if coordinator.keyboardLocked || coordinator.isSpacebarHoldSpeedActive {
                    PlayerTopStatusOverlay(coordinator: coordinator, edgeToEdge: immersive)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onHover { hovering in
                if hovering {
                    hoverExitTask?.cancel()
                    hoverExitTask = nil
                    coordinator.setHovering(true)
                } else {
                    hoverExitTask?.cancel()
                    hoverExitTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        guard !Task.isCancelled else { return }
                        coordinator.setHovering(false)
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Defer by one run-loop cycle so the view is fully in the window
            // hierarchy before we programmatically transfer keyboard focus.
            DispatchQueue.main.async { isFocused = true }
        }
    }

    private static func sidePad(for size: CGSize, aspect: Double) -> CGFloat {
        let videoWidth = min(size.width, size.height * aspect)
        return max(0, (size.width - videoWidth) / 2)
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

private struct PlayerStageEndedOverlay: View {
    let replay: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.9))

            Text("Playback finished")
                .font(.headline)
                .foregroundStyle(.white)

            Button("Replay") {
                replay()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private struct PlayerAccessIssueBanner: View {
    let issue: VideoAccessIssue

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: issue.kind == .membersOnly ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(issue.kind == .membersOnly ? Color(red: 0.27, green: 0.88, blue: 0.41) : Color.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title)
                    .font(.headline.weight(.bold))
                Text(issue.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct SponsorBlockTimelineOverlay: View {
    let segments: [SponsorBlockSegment]
    let duration: Double

    private let trackHeight: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            if duration > 0, !segments.isEmpty {
                ZStack(alignment: .leading) {
                    ForEach(segments) { segment in
                        let startFraction = max(min(segment.startTime / duration, 1), 0)
                        let endFraction = max(min(segment.endTime / duration, 1), startFraction)
                        let width = max((endFraction - startFraction) * proxy.size.width, 3)

                        Capsule(style: .continuous)
                            .fill(segment.categoryTint.opacity(0.96))
                            .frame(width: width, height: trackHeight)
                            .offset(x: startFraction * proxy.size.width)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: trackHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SponsorBlockManualSkipOverlay: View {
    let segment: SponsorBlockSegment
    let skip: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Button(action: skip) {
            HStack(spacing: 14) {
                Image(systemName: "forward.end.alt.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(segment.categoryTint)

                Text("Skip \(segment.categoryShortTitle)?")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)

                Rectangle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 1, height: 18)

                Text("Skip")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.96))

                Text(returnKeyTitle)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .playerControlSurface(
            reduceTransparency: reduceTransparency,
            glass: .regular,
            shape: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.bottom, 140)
        .allowsHitTesting(true)
        .animation(.snappy(duration: 0.2, extraBounce: 0), value: segment.id)
    }

    private var returnKeyTitle: String {
        "Enter"
    }
}

private struct ActionFeedbackOverlay: View {
    let feedback: ActionFeedback
    let generation: Int
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var appeared = false
    @State private var slideX: CGFloat = 0

    private var isSeek: Bool {
        switch feedback {
        case .seekForward, .seekBackward, .frameForward, .frameBackward: return true
        default: return false
        }
    }

    // Settled position of the circle
    private var settledX: CGFloat {
        switch feedback {
        case .seekForward, .frameForward: return 310
        case .seekBackward, .frameBackward: return -310
        case .play, .pause: return 0
        }
    }

    private var entrySlideX: CGFloat {
        switch feedback {
        case .seekForward, .frameForward: return -30
        case .seekBackward, .frameBackward: return 30
        case .play, .pause: return 0
        }
    }

    private var symbolName: String {
        switch feedback {
        case .play: return "play.fill"
        case .pause: return "pause.fill"
        case .seekForward: return "forward.fill"
        case .seekBackward: return "backward.fill"
        case .frameForward: return "forward.frame.fill"
        case .frameBackward: return "backward.frame.fill"
        }
    }

    private var label: String? {
        switch feedback {
        case .seekForward(let s): return "+\(s)s"
        case .seekBackward(let s): return "-\(s)s"
        default: return nil
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbolName)
                .font(.system(size: 26, weight: .semibold))
                .contentTransition(.symbolEffect(.replace.offUp))

            if let label {
                Text(label)
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: label.hasPrefix("-")))
            }
        }
        .foregroundStyle(.white)
        .frame(width: 72, height: 72)
        .playerControlSurface(
            reduceTransparency: reduceTransparency,
            glass: .regular,
            shape: Circle()
        )
        .scaleEffect(appeared ? 1.0 : 0.5)
        .opacity(appeared ? 1.0 : 0.0)
        .offset(x: settledX + slideX)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            slideX = entrySlideX
            withAnimation(.easeOut(duration: 0.15)) {
                appeared = true
                if isSeek { slideX = 0 }
            }
        }
        .onChange(of: generation) { _, _ in
            // Replay the slide-in on every tap (seeks, frame steps, etc.)
            slideX = entrySlideX
            withAnimation(.easeOut(duration: 0.15)) {
                slideX = 0
            }
        }
    }
}

private struct PlayerChromeOverlay: View {
    @ObservedObject var coordinator: PlayerPlaybackCoordinator
    let edgeToEdge: Bool
    let sidePad: CGFloat

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
                    if coordinator.selectedSubtitleOptionID != SubtitleOption.offID,
                       coordinator.hasSubtitleOptions {
                        PlayerStatusPill(text: coordinator.subtitleControlText)
                    }

                    Spacer()
                }
                .padding(.horizontal, (edgeToEdge ? 20 : 18) + sidePad)
                .padding(.top, edgeToEdge ? 20 : 18)

                Spacer()

                PlayerControlBar(coordinator: coordinator)
                    .padding(.horizontal, (edgeToEdge ? 20 : 18) + sidePad)
                    .padding(.bottom, edgeToEdge ? 20 : 18)
            }
            // Keep the chrome pinned to the stage width so scrub-preview updates
            // cannot change the control stack's ideal width mid-drag.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            // Keep the scrub-preview bubble out of layout so it cannot widen
            // the player chrome while dragging.
            if coordinator.scrubPreviewFraction != nil, coordinator.storyboard != nil {
                GeometryReader { geo in
                    ScrubPreviewPositioned(
                        coordinator: coordinator,
                        edgeToEdge: edgeToEdge,
                        sidePad: sidePad,
                        stageSize: geo.size
                    )
                }
                .allowsHitTesting(false)
            }
        }
        .opacity(coordinator.controlsVisible ? 1 : 0)
        .allowsHitTesting(coordinator.controlsVisible)
        .animation(.linear(duration: 0.1), value: coordinator.controlsVisible)
    }
}

private struct PlayerTopStatusOverlay: View {
    @ObservedObject var coordinator: PlayerPlaybackCoordinator
    let edgeToEdge: Bool

    var body: some View {
        VStack(spacing: 8) {
            if coordinator.keyboardLocked {
                PlayerStatusPill(
                    text: "Keyboard locked",
                    systemImage: "lock.fill"
                )
            }

            if coordinator.isSpacebarHoldSpeedActive {
                PlayerStatusPill(
                    text: coordinator.spacebarHoldSpeedIndicatorText,
                    systemImage: "hare.fill"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, edgeToEdge ? 20 : 18)
        .allowsHitTesting(false)
    }
}

private struct PlayerControlBar: View {
    private enum SettingsPopoverDestination: String {
        case root
        case subtitles
        case playbackSpeed
        case quality
    }

    @ObservedObject var coordinator: PlayerPlaybackCoordinator
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var playPauseNamespace
    @State private var isQualityPopoverPresented = false
    @State private var isSubtitlePopoverPresented = false
    @State private var isSettingsOverlayPresented = false
    @State private var settingsCurrentPage: SettingsPopoverDestination = .root
    @State private var settingsVisibleSubmenu: SettingsPopoverDestination? = nil
    @State private var settingsShowingSubmenu = false
    @State private var sliderWidth: CGFloat = 0
    @State private var lastMeasuredSliderWidth: CGFloat = 0

    private let compactControlHeight: CGFloat = 38
    private let circularButtonLabelSize: CGFloat = 30
    private let qualityButtonMinWidth: CGFloat = 104
    private let volumeIconContentHeight: CGFloat = 22
    private let timeLabelWidth: CGFloat = 54
    private let liveIndicatorWidth: CGFloat = 66

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                playPauseButton
                volumeControl
                Spacer(minLength: 0)
                subtitlesButton
                qualityMenu
                settingsMenu
                sidebarToggle
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
            leadingScrubberStatus

            // Keep this row structure aligned with the pre-refactor scrubber so
            // the sponsor overlay shares the same native slider geometry.
            ZStack {
                SponsorBlockTimelineOverlay(
                    segments: coordinator.visibleSponsorSegments,
                    duration: coordinator.duration
                )
                .padding(.horizontal, 10)
                .allowsHitTesting(false)

                Slider(
                    value: Binding(
                        get: { coordinator.displayedScrubPosition },
                        set: { coordinator.updateScrubPosition($0) }
                    ),
                    in: coordinator.scrubberRange,
                    onEditingChanged: { isEditing in
                        coordinator.setScrubbing(isEditing)
                        // Always clear the hover fraction so scrubPreviewFraction falls
                        // through to the isScrubbing path, which tracks scrubPosition
                        // in real-time rather than the frozen initial hover position.
                        coordinator.scrubHoverFraction = nil
                    }
                )
                .disabled(!coordinator.hasSeekableTimeline)
                .accessibilityLabel("Playback position")
            }
            // Measure the ZStack width (= Slider width) without affecting layout.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { updateMeasuredSliderWidth(geo.size.width) }
                        .onChange(of: geo.size.width) { _, width in
                            updateMeasuredSliderWidth(width)
                        }
                }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    guard coordinator.hasSeekableTimeline, sliderWidth > 0 else { return }
                    let trackInset: CGFloat = 10
                    let trackW = max(1, sliderWidth - trackInset * 2)
                    coordinator.scrubHoverFraction = max(0, min(1, (loc.x - trackInset) / trackW))
                case .ended:
                    coordinator.scrubHoverFraction = nil
                }
            }

            trailingScrubberStatus
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

    @ViewBuilder
    private var leadingScrubberStatus: some View {
        if coordinator.isLivePlayback {
            Button {
                coordinator.seekToLiveEdge()
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(coordinator.isAtLiveEdge ? BrandAssets.youtubeRed : Color.secondary.opacity(0.75))
                        .frame(width: 8, height: 8)

                    Text("LIVE")
                        .foregroundStyle(coordinator.isAtLiveEdge ? BrandAssets.youtubeRed : .secondary)
                        .fontWeight(.bold)
                }
                .frame(width: liveIndicatorWidth, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Jump to live")
            .accessibilityValue(coordinator.isAtLiveEdge ? "At live edge" : "Behind live")
        } else {
            Text(coordinator.currentTimeText)
                .foregroundStyle(.primary)
                .frame(width: timeLabelWidth, alignment: .leading)
        }
    }

    @ViewBuilder
    private var trailingScrubberStatus: some View {
        if coordinator.isLivePlayback {
            Color.clear
                .frame(width: liveIndicatorWidth, height: 1)
        } else {
            Text(coordinator.remainingTimeText)
                .foregroundStyle(.secondary)
                .frame(width: timeLabelWidth, alignment: .trailing)
        }
    }

    private func updateMeasuredSliderWidth(_ width: CGFloat) {
        sliderWidth = width

        guard abs(width - lastMeasuredSliderWidth) > 0.5 else { return }
        PlaybackDebugLogger.log(
            "player scrubber width=\(Int(width.rounded())) previous=\(Int(lastMeasuredSliderWidth.rounded())) " +
            "isScrubbing=\(coordinator.isScrubbing) sponsorSegments=\(coordinator.visibleSponsorSegments.count) " +
            "duration=\(coordinator.duration) liveRange=\(String(describing: coordinator.liveSeekableRange))"
        )
        lastMeasuredSliderWidth = width
    }

    var settingsMenu: some View {
        Button {
            if !isSettingsOverlayPresented {
                resetSettingsMenuNavigation()
            }
            withAnimation(.easeOut(duration: 0.26)) {
                isSettingsOverlayPresented.toggle()
            }
        } label: {
            circularButtonLabel(symbol: "gearshape", fontSize: 14)
        }
        .buttonStyle(.glass(.regular.interactive()))
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .background {
            ManagedPopoverPresenter(
                isPresented: $isSettingsOverlayPresented,
                preferredEdge: .minY,
                contentSize: settingsPopoverSize,
                content: AnyView(settingsPopoverContent),
                onDismiss: resetSettingsMenuNavigation
            )
            .allowsHitTesting(false)
        }
        .onChange(of: isSettingsOverlayPresented) { _, isPresented in
            if isPresented {
                resetSettingsMenuNavigation()
                coordinator.beginMenuInteraction()
            } else {
                resetSettingsMenuNavigation()
                coordinator.endMenuInteraction()
            }
        }
        .accessibilityLabel("Playback Settings")
    }

    var settingsPopoverSize: CGSize {
        let fixedWidth: CGFloat = 280
        switch settingsShowingSubmenu ? settingsCurrentPage : .root {
        case .root:
            return CGSize(width: fixedWidth, height: 166)
        case .subtitles:
            return CGSize(width: fixedWidth, height: listPopoverHeight(itemCount: coordinator.subtitleOptions.count + 1))
        case .playbackSpeed:
            return CGSize(width: fixedWidth, height: listPopoverHeight(itemCount: coordinator.playbackSpeedOptions.count))
        case .quality:
            return CGSize(width: fixedWidth, height: listPopoverHeight(itemCount: coordinator.qualityOptions.count))
        }
    }

    var settingsPopoverContent: some View {
        let panelSize = settingsPopoverSize

        return HStack(spacing: 0) {
            settingsRootPopoverContent
                .frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)

            settingsSubmenuContent(for: settingsVisibleSubmenu ?? .subtitles)
                .frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)
        }
        .frame(width: panelSize.width * 2, height: panelSize.height, alignment: .leading)
        .offset(x: settingsShowingSubmenu ? -panelSize.width : 0)
        .frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)
        .clipped()
        .animation(.easeOut(duration: 0.30), value: settingsShowingSubmenu)
        .animation(.easeOut(duration: 0.30), value: settingsCurrentPage)
    }

    var settingsRootPopoverContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            settingsNavigationButton(
                title: "Subtitles",
                detail: coordinator.subtitleControlText,
                symbolName: coordinator.subtitleSymbolName,
                disabled: !coordinator.hasSubtitleOptions
            ) {
                showSettingsSubmenu(.subtitles)
            }
            settingsNavigationButton(
                title: "Playback Speed",
                detail: coordinator.playbackSpeedControlText,
                symbolName: "speedometer"
            ) {
                showSettingsSubmenu(.playbackSpeed)
            }
            settingsNavigationButton(
                title: "Quality",
                detail: coordinator.qualityControlText,
                symbolName: "dial.medium"
            ) {
                showSettingsSubmenu(.quality)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func settingsSubmenuContent(for destination: SettingsPopoverDestination) -> some View {
        switch destination {
        case .root:
            settingsRootPopoverContent
        case .subtitles:
            subtitlePopoverContent
        case .playbackSpeed:
            playbackSpeedPopoverContent
        case .quality:
            qualityPopoverContent
        }
    }

    var subtitlesButton: some View {
        Button {
            isSubtitlePopoverPresented.toggle()
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
        .popover(
            isPresented: $isSubtitlePopoverPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            standaloneSubtitlePopoverContent
        }
        .onChange(of: isSubtitlePopoverPresented) { _, isPresented in
            if isPresented {
                coordinator.beginMenuInteraction()
            } else {
                coordinator.endMenuInteraction()
            }
        }
        .accessibilityLabel("Subtitles")
    }

    var subtitlePopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsSubmenuHeader(title: "Subtitles")

            subtitleMenuList
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var standaloneSubtitlePopoverContent: some View {
        subtitleMenuList
            .padding(8)
            .frame(minWidth: 220)
    }

    var subtitleMenuList: some View {
        VStack(alignment: .leading, spacing: 4) {
            subtitleMenuOptionButton(for: .off)
            ForEach(coordinator.subtitleOptions) { option in
                subtitleMenuOptionButton(for: option)
            }
        }
    }

    func subtitleMenuOptionButton(for option: SubtitleOption) -> some View {
        Button {
            coordinator.selectSubtitle(option)
            isSettingsOverlayPresented = false
            isSubtitlePopoverPresented = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: option.id == coordinator.selectedSubtitleOptionID ? "checkmark" : "circle")
                    .foregroundStyle(option.id == coordinator.selectedSubtitleOptionID ? Color.accentColor : .secondary)
                Text(option.title)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        option.id == coordinator.selectedSubtitleOptionID
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear
                    )
            )
        }
        .buttonStyle(.plain)
    }

    var playbackSpeedPopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsSubmenuHeader(title: "Playback Speed")

            VStack(alignment: .leading, spacing: 4) {
                ForEach(coordinator.playbackSpeedOptions) { option in
                    playbackSpeedMenuOptionButton(for: option)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func playbackSpeedMenuOptionButton(for option: PlaybackSpeedOption) -> some View {
        Button {
            coordinator.selectPlaybackSpeed(option.speed)
            isSettingsOverlayPresented = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: option.speed == coordinator.selectedPlaybackSpeed ? "checkmark" : "circle")
                    .foregroundStyle(option.speed == coordinator.selectedPlaybackSpeed ? Color.accentColor : .secondary)
                Text(option.title)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        option.speed == coordinator.selectedPlaybackSpeed
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear
                    )
            )
        }
        .buttonStyle(.plain)
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
            standaloneQualityPopoverContent
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
        VStack(alignment: .leading, spacing: 8) {
            settingsSubmenuHeader(title: "Quality")

            qualityMenuList
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var standaloneQualityPopoverContent: some View {
        qualityMenuList
            .padding(8)
            .frame(minWidth: 260)
    }

    var qualityMenuList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(coordinator.qualityOptions) { option in
                qualityMenuOptionButton(for: option)
            }
        }
    }

    func qualityMenuOptionButton(for option: QualityOption) -> some View {
        Button {
            coordinator.selectQuality(option)
            isSettingsOverlayPresented = false
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

    var sidebarToggle: some View {
        Button {
            coordinator.toggleSidePanel()
        } label: {
            circularButtonLabel(symbol: coordinator.sidebarPanelSymbolName, fontSize: 14)
        }
        .buttonStyle(.glass(.regular.interactive()))
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .accessibilityLabel("Sidebar Panel")
        .accessibilityValue(coordinator.isSidePanelVisible ? "Visible" : "Hidden")
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

    func settingsNavigationButton(
        title: String,
        detail: String,
        symbolName: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbolName)
                    .foregroundStyle(disabled ? .tertiary : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(disabled ? .secondary : .primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(disabled ? Color.clear : Color.primary.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    func settingsSubmenuHeader(title: String) -> some View {
        HStack(spacing: 10) {
            Button {
                showSettingsRoot()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("Settings")
                }
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)

            Spacer()

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func showSettingsSubmenu(_ destination: SettingsPopoverDestination) {
        settingsVisibleSubmenu = destination
        settingsCurrentPage = destination
        withAnimation(.easeOut(duration: 0.30)) {
            settingsShowingSubmenu = true
        }
    }

    private func showSettingsRoot() {
        settingsCurrentPage = .root
        withAnimation(.easeOut(duration: 0.30)) {
            settingsShowingSubmenu = false
        }
    }

    private func resetSettingsMenuNavigation() {
        settingsCurrentPage = .root
        settingsVisibleSubmenu = nil
        settingsShowingSubmenu = false
    }

    private func listPopoverHeight(itemCount: Int) -> CGFloat {
        let headerHeight: CGFloat = 44
        let rowHeight: CGFloat = 38
        let verticalPadding: CGFloat = 6
        return min(max(headerHeight + (CGFloat(itemCount) * rowHeight) + verticalPadding, 112), 420)
    }
}

private struct PlayerStatusPill: View {
    let text: String
    let systemImage: String?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
            }

            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .fixedSize(horizontal: true, vertical: false)
        .playerControlSurface(
            reduceTransparency: reduceTransparency,
            glass: .regular,
            shape: Capsule()
        )
    }
}

private struct DetailCard<Content: View>: View {
    let title: String?
    let content: Content

    init(title: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                Text(title)
                    .font(.headline.weight(.bold))
            }
            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

private struct CompactVideoStatPill: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .tracking(0.8)

            Text(value)
                .font(.footnote.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}

private struct PlaylistQueueRailRow: View {
    let video: VideoItem
    let index: Int
    let isCurrent: Bool
    let canReorder: Bool

    @State private var isHovered = false

    private var statsLine: String {
        [video.channel, video.viewCountText, video.publishedTimeText]
            .compactMap { $0 }
            .joined(separator: " • ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if isHovered && canReorder {
                    Image(systemName: "line.3.horizontal")
                        .font(.body.weight(.semibold))
                } else if isCurrent {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                } else {
                    Text("\(index)")
                        .font(.callout.monospacedDigit().weight(.semibold))
                }
            }
            .foregroundStyle(isCurrent ? .blue : .secondary)
            .frame(width: 18, height: 67.5, alignment: .center)

            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: video.thumbnailURL, maxPixelSize: 480) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.18))
                        .overlay(
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary)
                        )
                }
                .frame(width: 120, height: 67.5)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottom) {
                    VideoThumbnailProgressBars(progress: video.progress, cornerRadius: 12, isEnabled: !video.isLive)
                }

                if let duration = video.durationText {
                    Text(duration)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.74)))
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(2)

                if !video.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(video.tags) { tag in
                            VideoTagBadgeView(tag: tag, font: .caption2)
                        }
                    }
                }

                if !statsLine.isEmpty {
                    Text(statsLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(isCurrent ? Color.blue.opacity(0.14) : Color.white.opacity(isHovered ? 0.08 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(isCurrent ? Color.blue.opacity(0.32) : Color.white.opacity(isHovered ? 0.09 : 0.03), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct PlaylistQueueDropZone: View {
    let onInsert: (String) -> Bool
    @State private var isTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 999, style: .continuous)
            .fill(isTargeted ? Color.blue.opacity(0.65) : .clear)
            .frame(height: isTargeted ? 4 : 10)
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .animation(.easeOut(duration: 0.12), value: isTargeted)
            .dropDestination(for: String.self) { items, _ in
                guard let draggedID = items.first else { return false }
                return onInsert(draggedID)
            } isTargeted: { hovering in
                isTargeted = hovering
            }
    }
}

private struct ChannelSummary: View {
    let avatarURL: URL?
    let channel: String?
    let subscriberCount: String?
    let onOpenChannel: (() -> Void)?

    var body: some View {
        Group {
            if let onOpenChannel {
                Button(action: onOpenChannel) {
                    label
                }
                .buttonStyle(.plain)
            } else {
                label
            }
        }
    }

    private var label: some View {
        HStack(spacing: 10) {
            CachedAsyncImage(url: avatarURL, maxPixelSize: 128) {
                Circle()
                    .fill(Color.gray.opacity(0.28))
                    .overlay(
                        Image(systemName: "person.fill")
                            .foregroundStyle(.secondary)
                    )
            }
            .frame(width: 42, height: 42)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(channel ?? "Unknown channel")
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                if let subscriberCount, !subscriberCount.isEmpty {
                    Text(subscriberCount)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
            CachedAsyncImage(url: comment.avatarURL, maxPixelSize: 96) {
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
    @ObservedObject private var settings = AppSettings.shared
    let video: VideoItem
    let onOpenChannel: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: video.thumbnailURL, maxPixelSize: 256) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.secondary)
                        )
                }
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottom) {
                    VideoThumbnailProgressBars(progress: video.progress, cornerRadius: 12, isEnabled: !video.isLive)
                }

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
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(2)

                VideoChannelIdentityLine(
                    avatarURL: video.channelAvatarURL,
                    channelID: video.channelId,
                    channel: video.channel,
                    avatarSize: 20,
                    font: .system(size: 12.5, weight: .medium),
                    onOpenChannel: onOpenChannel
                )

                VideoStatsMetadataLine(
                    tags: video.tags,
                    viewCountText: video.viewCountText,
                    publishedTimeText: video.publishedTimeText,
                    font: .system(size: 12.5, weight: .medium)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isHovered ? settings.hoverCardBackgroundColor : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .scaleEffect(isHovered ? 1.006 : 1)
        .offset(y: isHovered ? -0.5 : 0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Scrub preview thumbnail

/// Full-player storyboard overlay shown while dragging the scrubber.
/// Covers the paused video with the low-res storyboard tile scaled to fill —
/// uses the same ImageCache as the hover popup so tiles are already cached.
private struct ScrubVideoOverlay: View {
    let spec: StoryboardSpec
    let time: Double
    let containerSize: CGSize

    @State private var tile: CGImage? = nil

    var body: some View {
        ZStack {
            Color.black
            if let tile {
                Image(decorative: tile, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        // Storyboard tiles can be much wider than the stage on ultrawide videos.
        // Pin this overlay to the measured stage size so the tile cannot widen
        // the parent ZStack while scrubbing.
        .frame(width: containerSize.width, height: containerSize.height)
        .clipped()
        .task(id: tileTaskID) {
            await loadTile()
        }
    }

    private var tileTaskID: String {
        guard let info = spec.tileInfo(at: time) else { return "" }
        return "\(info.url.absoluteString)/\(info.col)/\(info.row)"
    }

    private func loadTile() async {
        guard let info = spec.tileInfo(at: time) else { return }
        do {
            let decoded = try await ImageCache.shared.loadDecodedImage(from: info.url)
            guard !Task.isCancelled else { return }
            let cropRect = CGRect(
                x: CGFloat(info.col * spec.tileWidth),
                y: CGFloat(info.row * spec.tileHeight),
                width: CGFloat(spec.tileWidth),
                height: CGFloat(spec.tileHeight)
            )
            if let cropped = decoded.cgImage.cropping(to: cropRect) {
                tile = cropped
            }
        } catch {}
    }
}

/// Positions the scrub-preview popup over the scrubber track inside the stage.
private struct ScrubPreviewPositioned: View {
    @ObservedObject var coordinator: PlayerPlaybackCoordinator
    let edgeToEdge: Bool
    let sidePad: CGFloat
    let stageSize: CGSize

    // Must match constants in PlayerControlBar.
    private let timeLabelWidth: CGFloat = 54
    private let liveIndicatorWidth: CGFloat = 66
    private let scrubberRowHeight: CGFloat = 38
    // Fixed display width for the preview tile; height is derived from the tile's aspect ratio.
    private let previewDisplayWidth: CGFloat = 136

    var body: some View {
        if let fraction = coordinator.scrubPreviewFraction,
           let spec = coordinator.storyboard,
           coordinator.hasSeekableTimeline {
            let hoverTime = coordinator.scrubberTime(forFraction: fraction)

            // Tile display dimensions (independent of raw storyboard pixel size).
            let dispW = previewDisplayWidth
            let dispH = spec.tileWidth > 0
                ? previewDisplayWidth * CGFloat(spec.tileHeight) / CGFloat(spec.tileWidth)
                : previewDisplayWidth * 9 / 16

            // Horizontal centre of the hovered position on stage.
            // Layout: edgePad | controlBarPad(14) | timeLabel(54) | spacing(12) | [track] | …
            let edgePad = CGFloat(edgeToEdge ? 20 : 18) + sidePad
            let statusWidth = coordinator.isLivePlayback ? liveIndicatorWidth : timeLabelWidth
            let innerOffset: CGFloat = 14 + statusWidth + 12 + 10
            let trackLeft = edgePad + innerOffset
            let trackRight = stageSize.width - edgePad - innerOffset
            let thumbX = trackLeft + fraction * max(0, trackRight - trackLeft)
            let clampedX = min(max(thumbX, dispW / 2 + 8), stageSize.width - dispW / 2 - 8)

            // Vertical: just above the scrubber row.
            let bottomPad = CGFloat(edgeToEdge ? 20 : 18)
            let popupY = stageSize.height - bottomPad - scrubberRowHeight - 10 - dispH / 2

            ScrubPreviewBubble(
                spec: spec,
                time: hoverTime,
                displayWidth: dispW,
                displayHeight: dispH,
                timestampText: timestampText(for: hoverTime)
            )
                .fixedSize()
                .position(x: clampedX, y: popupY)
        }
    }

    private func timestampText(for hoverTime: Double) -> String {
        if coordinator.isLivePlayback {
            return "-\(formatTimestamp(max(coordinator.scrubberUpperBound - hoverTime, 0)))"
        }
        return formatTimestamp(hoverTime)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3_600
        let m = (total % 3_600) / 60
        let s = total % 60
        if h > 0 { return "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", s))" }
        return "\(m):\(String(format: "%02d", s))"
    }
}

/// Thumbnail + timestamp label shown above the scrubber during hover/drag.
private struct ScrubPreviewBubble: View {
    let spec: StoryboardSpec
    let time: Double
    let displayWidth: CGFloat
    let displayHeight: CGFloat
    let timestampText: String

    var body: some View {
        VStack(spacing: 5) {
            ScrubPreviewTile(spec: spec, time: time, displayWidth: displayWidth, displayHeight: displayHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )

            Text(timestampText)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.72)))
        }
        .shadow(color: .black.opacity(0.55), radius: 10, y: 4)
    }
}

/// Downloads the correct sprite-sheet file and crops the individual tile for the given timestamp.
private struct ScrubPreviewTile: View {
    let spec: StoryboardSpec
    let time: Double
    let displayWidth: CGFloat
    let displayHeight: CGFloat

    @State private var tile: CGImage? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
            if let tile {
                Image(decorative: tile, scale: 1)
                    .resizable()
                    .frame(width: displayWidth, height: displayHeight)
            }
        }
        .frame(width: displayWidth, height: displayHeight)
        .task(id: tileTaskID) {
            await loadTile()
        }
    }

    private var tileTaskID: String {
        guard let info = spec.tileInfo(at: time) else { return "" }
        return "\(info.url.absoluteString)/\(info.col)/\(info.row)"
    }

    private func loadTile() async {
        guard let info = spec.tileInfo(at: time) else { return }
        do {
            let decoded = try await ImageCache.shared.loadDecodedImage(from: info.url)
            guard !Task.isCancelled else { return }
            let cropRect = CGRect(
                x: CGFloat(info.col * spec.tileWidth),
                y: CGFloat(info.row * spec.tileHeight),
                width: CGFloat(spec.tileWidth),
                height: CGFloat(spec.tileHeight)
            )
            if let cropped = decoded.cgImage.cropping(to: cropRect) {
                tile = cropped
            }
        } catch {
            // Image unavailable; tile stays dark.
        }
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
