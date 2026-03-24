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
            return CGRect(origin: .zero, size: proxy.size)
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
            .anchorPreference(key: PlayerSurfaceBoundsKey.self, value: .bounds) { $0 }
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
    @ObservedObject private var settings = AppSettings.shared
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
                    ScrubVideoOverlay(spec: spec, time: coordinator.scrubPosition)
                        .allowsHitTesting(false)
                }

                if coordinator.shouldShowPlaybackErrorOverlay,
                   let errorMessage {
                    PlayerStageErrorOverlay(message: errorMessage, retry: retry)
                } else if coordinator.shouldShowPlaybackLoadingOverlay {
                    PlayerStageLoadingOverlay(text: isLoading ? "Loading video..." : coordinator.playbackLoadingText)
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
                            let inVideo = pad < 1 || (location.x >= pad && location.x <= geo.size.width - pad)
                            if inVideo { coordinator.handlePointerMovement() }
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

                if coordinator.keyboardLocked {
                    Label("Keyboard locked", systemImage: "keyboard.badge.ellipsis")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.black.opacity(0.72)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 16)
                        .allowsHitTesting(false)
                }
            }
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
            // Lock key fires regardless of keyboard lock state.
            .onKeyPress(characters: .init(charactersIn: "`\\zx")) { press in
                guard let lockChar = AppSettings.shared.keyboardLockKey.character,
                      press.characters == String(lockChar) else { return .ignored }
                coordinator.keyboardLocked.toggle()
                return .handled
            }
            .onKeyPress(.space, phases: [.down, .repeat, .up]) { press in
                // Return .handled even when locked so macOS doesn't play the error beep.
                guard !coordinator.keyboardLocked else { return .handled }
                switch press.phase {
                case .down:
                    coordinator.handleSpacebarKeyDown()
                case .repeat:
                    break
                case .up:
                    coordinator.handleSpacebarKeyUp()
                default:
                    break
                }
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: settings.playPauseKey)) { _ in
                guard !coordinator.keyboardLocked else { return .handled }
                coordinator.togglePlayback()
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard !coordinator.keyboardLocked else { return .handled }
                coordinator.seekRelative(-Double(settings.arrowSeekSeconds))
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard !coordinator.keyboardLocked else { return .handled }
                coordinator.seekRelative(Double(settings.arrowSeekSeconds))
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: settings.seekBackKey)) { _ in
                guard !coordinator.keyboardLocked else { return .handled }
                coordinator.seekRelative(-Double(settings.jlSeekSeconds))
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: settings.seekFwdKey)) { _ in
                guard !coordinator.keyboardLocked else { return .handled }
                coordinator.seekRelative(Double(settings.jlSeekSeconds))
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: settings.frameBackKey)) { _ in
                guard !coordinator.keyboardLocked else { return .handled }
                if let secs = settings.commaSeekMode.seconds {
                    coordinator.seekRelative(-secs)
                } else {
                    coordinator.stepFrame(direction: -1)
                }
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: settings.frameFwdKey)) { _ in
                guard !coordinator.keyboardLocked else { return .handled }
                if let secs = settings.commaSeekMode.seconds {
                    coordinator.seekRelative(secs)
                } else {
                    coordinator.stepFrame(direction: 1)
                }
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: settings.theaterKey)) { _ in
                guard !coordinator.keyboardLocked else { return .handled }
                coordinator.toggleTheaterMode()
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: settings.fullscreenKey)) { _ in
                guard !coordinator.keyboardLocked else { return .handled }
                coordinator.toggleFullscreen()
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: settings.subtitleKey)) { _ in
                guard !coordinator.keyboardLocked else { return .handled }
                coordinator.toggleSubtitles()
                return .handled
            }
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
                    PlayerStatusPill(text: coordinator.playbackBadgeText)
                    PlayerStatusPill(text: coordinator.effectivePlaybackSpeedText)

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

            // Scrub-preview thumbnail (hover/drag over timeline).
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
                settingsMenu
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

            // Wrap in ZStack so onContinuousHover sits on the *container*, not the
            // Slider itself — AppKit's NSSlider modal drag loop suppresses mouseMoved
            // events when applied directly, so the container approach is reliable
            // for both passive hover and active drag.
            ZStack {
                Slider(
                    value: Binding(
                        get: { coordinator.scrubPosition },
                        set: { coordinator.updateScrubPosition($0) }
                    ),
                    in: 0...coordinator.scrubberUpperBound,
                    onEditingChanged: { isEditing in
                        coordinator.setScrubbing(isEditing)
                        // Always clear the hover fraction so scrubPreviewFraction falls
                        // through to the isScrubbing path, which tracks scrubPosition
                        // in real-time rather than the frozen initial hover position.
                        coordinator.scrubHoverFraction = nil
                    }
                )
                .disabled(coordinator.duration <= 0)
                .accessibilityLabel("Playback position")
            }
            // Measure the ZStack width (= Slider width) without affecting layout.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { sliderWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in sliderWidth = w }
                }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    guard coordinator.duration > 0, sliderWidth > 0 else { return }
                    let trackInset: CGFloat = 10
                    let trackW = max(1, sliderWidth - trackInset * 2)
                    coordinator.scrubHoverFraction = max(0, min(1, (loc.x - trackInset) / trackW))
                case .ended:
                    coordinator.scrubHoverFraction = nil
                }
            }

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

// MARK: - Scrub preview thumbnail

/// Full-player storyboard overlay shown while dragging the scrubber.
/// Covers the paused video with the low-res storyboard tile scaled to fill —
/// uses the same ImageCache as the hover popup so tiles are already cached.
private struct ScrubVideoOverlay: View {
    let spec: StoryboardSpec
    let time: Double

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    private let scrubberRowHeight: CGFloat = 38
    // Fixed display width for the preview tile; height is derived from the tile's aspect ratio.
    private let previewDisplayWidth: CGFloat = 120

    var body: some View {
        if let fraction = coordinator.scrubPreviewFraction,
           let spec = coordinator.storyboard,
           coordinator.duration > 0 {
            let hoverTime = min(fraction * coordinator.duration, coordinator.duration)

            // Tile display dimensions (independent of raw storyboard pixel size).
            let dispW = previewDisplayWidth
            let dispH = spec.tileWidth > 0
                ? previewDisplayWidth * CGFloat(spec.tileHeight) / CGFloat(spec.tileWidth)
                : previewDisplayWidth * 9 / 16

            // Horizontal centre of the hovered position on stage.
            // Layout: edgePad | controlBarPad(14) | timeLabel(54) | spacing(12) | [track] | …
            let edgePad = CGFloat(edgeToEdge ? 20 : 18) + sidePad
            let innerOffset: CGFloat = 14 + timeLabelWidth + 12 + 10   // ~90 pt (includes track inset)
            let trackLeft = edgePad + innerOffset
            let trackRight = stageSize.width - edgePad - innerOffset
            let thumbX = trackLeft + fraction * max(0, trackRight - trackLeft)
            let clampedX = min(max(thumbX, dispW / 2 + 8), stageSize.width - dispW / 2 - 8)

            // Vertical: just above the scrubber row.
            let bottomPad = CGFloat(edgeToEdge ? 20 : 18)
            let popupY = stageSize.height - bottomPad - scrubberRowHeight - 10 - dispH / 2

            ScrubPreviewBubble(spec: spec, time: hoverTime, displayWidth: dispW, displayHeight: dispH)
                .position(x: clampedX, y: popupY)
        }
    }
}

/// Thumbnail + timestamp label shown above the scrubber during hover/drag.
private struct ScrubPreviewBubble: View {
    let spec: StoryboardSpec
    let time: Double
    let displayWidth: CGFloat
    let displayHeight: CGFloat

    var body: some View {
        VStack(spacing: 5) {
            ScrubPreviewTile(spec: spec, time: time, displayWidth: displayWidth, displayHeight: displayHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )

            Text(formatTimestamp(time))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.72)))
        }
        .shadow(color: .black.opacity(0.55), radius: 10, y: 4)
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
