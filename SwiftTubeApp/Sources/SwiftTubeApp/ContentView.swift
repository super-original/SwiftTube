import AppKit
import SwiftUI

func browseGridColumns(count: Int) -> [GridItem] {
    Array(
        repeating: GridItem(
            .flexible(minimum: 220, maximum: 640),
            spacing: 20,
            alignment: .top
        ),
        count: max(1, count)
    )
}

private enum SearchAssistState: Equatable {
    case hidden
    case loading
    case suggestions([String])
    case link(SearchViewModel.LinkPreview)

    var isVisible: Bool {
        self != .hidden
    }
}

private enum ChannelContentLayoutMode: String {
    case grid
    case list

    var symbolName: String {
        switch self {
        case .grid:
            return "square.grid.2x2"
        case .list:
            return "list.bullet"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .grid:
            return "Grid View"
        case .list:
            return "List View"
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var historyViewModel = WatchHistoryViewModel()
    @StateObject private var searchViewModel = SearchViewModel()
    @StateObject private var playlistLibraryViewModel = PlaylistLibraryViewModel()
    @State private var isSearchFieldFocused = false
    @State private var selectedSearchSuggestionIndex = 0
    @State private var keepSearchAssistVisibleUntil = Date.distantPast
    @State private var searchAssistDismissTask: Task<Void, Never>?
    @State private var didHandleAutomationLaunch = false
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var mutationCenter = AppMutationCenter.shared
    @EnvironmentObject private var backend: BackendManager
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var authSession: AuthSessionModel

    private var columns: [GridItem] {
        browseGridColumns(count: settings.browseVideoGridPreset.columnCount)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backgroundView
            appNavigationView
        }
        .overlay(backendOverlay)
        .overlay {
            MutationNotificationOverlay()
        }
        .sheet(isPresented: $authSession.isSheetPresented) {
            AuthConnectionSheet()
                .environmentObject(authSession)
        }
        .toolbar {
            appToolbar
        }
        .task(id: backend.state) {
            if backend.isRunning {
                await authSession.loadStatus()
                viewModel.reload()
                historyViewModel.reload()
                playlistLibraryViewModel.reload()
            }
        }
        .task(id: authSession.contentRefreshID) {
            guard backend.isRunning, authSession.hasLoadedStatus else { return }
            viewModel.reload()
            historyViewModel.reload()
            playlistLibraryViewModel.reload()
        }
        .onAppear {
            navigation.ensureValidSidebarSelection(visibleItems: visibleSidebarItems)
            syncSidebarVisibility(for: navigation.currentRoute)
            handleAutomationLaunchIfNeeded()
        }
        .onChange(of: authSession.status.authenticated) { _, _ in
            navigation.ensureValidSidebarSelection(visibleItems: visibleSidebarItems)
        }
        .onChange(of: settings.sidebarItemOrder) { _, _ in
            navigation.ensureValidSidebarSelection(visibleItems: visibleSidebarItems)
        }
        .onChange(of: settings.hiddenSidebarItems) { _, _ in
            navigation.ensureValidSidebarSelection(visibleItems: visibleSidebarItems)
        }
        .onChange(of: searchViewModel.query) { _, _ in
            handleToolbarQueryChange()
        }
        .onChange(of: navigation.currentRoute) { _, _ in
            syncHistorySearchQuery()
            syncSidebarVisibility(for: navigation.currentRoute)
        }
        .onChange(of: settings.autoHideSidebarOnPlayback) { _, _ in
            syncSidebarVisibility(for: navigation.currentRoute)
        }
        .onChange(of: settings.showSidebarOnHome) { _, _ in
            syncSidebarVisibility(for: navigation.currentRoute)
        }
        .onChange(of: searchViewModel.isActive) { _, _ in
            syncHistorySearchQuery()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackProgressDidUpdate)) { notification in
            guard let videoID = notification.userInfo?["videoID"] as? String,
                  let progress = notification.userInfo?["progress"] as? VideoProgress else {
                return
            }

            viewModel.applyLocalProgress(progress, to: videoID)
            historyViewModel.applyLocalProgress(progress, to: videoID)
            searchViewModel.applyLocalProgress(progress, to: videoID)
        }
        .background(
            AppCommandHandler(
                onRefresh: refreshCurrentRoute,
                onSelectNumberedTab: selectNumberedSidebarItem,
                onEscape: exitFullscreenIfNeeded
            )
        )
    }

    private var appNavigationView: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            sidebar
        } detail: {
            currentScreenContainer
                .navigationTitle(navigation.currentRoute.navigationTitle)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ToolbarContentBuilder
    private var appToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                if case .home = navigation.currentRoute {
                    viewModel.reload()
                } else {
                    searchViewModel.clear()
                    navigation.showHome()
                }
            } label: {
                BrandToolbarLabel()
            }
            .help("SwiftTube")
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup(placement: .navigation) {
            Button(action: handleBackNavigation) {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!navigation.canGoBack)
            .controlSize(.large)

            Button(action: handleForwardNavigation) {
                Label("Forward", systemImage: "chevron.right")
            }
            .disabled(!navigation.canGoForward)
            .controlSize(.large)
        }

        ToolbarItem(placement: .confirmationAction) {
            Button(action: refreshCurrentRoute) {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(!backend.isRunning)
            .buttonBorderShape(.circle)
            .help("Refresh")
        }
    }
}

private extension ContentView {
    func handleAutomationLaunchIfNeeded() {
        guard didHandleAutomationLaunch == false else { return }
        guard let videoID = ProcessInfo.processInfo.environment["SWIFTTUBE_AUTOPLAY_VIDEO_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              videoID.isEmpty == false else {
            return
        }

        didHandleAutomationLaunch = true
        let startTime = ProcessInfo.processInfo.environment["SWIFTTUBE_AUTOPLAY_START_TIME"]
            .flatMap(Double.init)
            .map { max($0, 0) }
        let thumbnail = Thumbnail(
            url: "https://i.ytimg.com/vi/\(videoID)/hq720.jpg",
            width: 1280,
            height: 720
        )
        let video = VideoItem(
            id: videoID,
            title: "Loading",
            channel: nil,
            channelId: nil,
            channelAvatarUrl: nil,
            viewCountText: nil,
            publishedTimeText: nil,
            durationText: nil,
            thumbnails: [thumbnail]
        )
        navigation.showVideo(video, startTime: startTime)
    }
}

private extension ContentView {
    @ViewBuilder
    var currentScreenContainer: some View {
        ZStack(alignment: .top) {
            currentScreen

            if searchAssistState.isVisible {
                searchAssistOverlay
                    .padding(.top, navigation.currentRoute.isSearchRoute ? 76 : 12)
                    .padding(.horizontal, navigation.currentRoute.isSearchRoute ? 24 : 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.snappy(duration: 0.2, extraBounce: 0), value: searchAssistState)
    }

    var visibleSidebarItems: [SidebarItemKind] {
        settings.visibleSidebarItems(isAuthenticated: authSession.status.authenticated)
    }

    var userOwnedPlaylists: [PlaylistSummary] {
        playlistLibraryViewModel.playlists.filter {
            !["WL", "LL"].contains($0.playlistId)
        }
    }

    func syncSidebarVisibility(for route: AppRoute) {
        if case .video = route, settings.autoHideSidebarOnPlayback {
            sidebarVisibility = .detailOnly
        } else if case .home = route, settings.showSidebarOnHome == false {
            sidebarVisibility = .detailOnly
        } else {
            sidebarVisibility = .all
        }
    }

    var toolbarSearchScope: SearchViewModel.Scope {
        switch navigation.currentRoute {
        case .watchHistory:
            return .history
        case .channel(let route):
            return .channel(route.channel)
        default:
            return .global
        }
    }

    var toolbarSearchPlaceholder: String {
        switch toolbarSearchScope {
        case .history:
            return "Search history"
        case .channel:
            return "Search this channel"
        case .global:
            return "Search or paste YouTube URL"
        }
    }

    var searchAssistState: SearchAssistState {
        if !isSearchFieldFocused {
            if Date() >= keepSearchAssistVisibleUntil {
                return .hidden
            }
            if searchViewModel.linkPreview == nil,
               searchViewModel.suggestions.isEmpty,
               searchViewModel.isLoadingSuggestions == false {
                return .hidden
            }
        }
        if let linkPreview = searchViewModel.linkPreview {
            return .link(linkPreview)
        }
        if searchViewModel.isLoadingSuggestions {
            return .loading
        }
        if !searchViewModel.suggestions.isEmpty {
            return .suggestions(searchViewModel.suggestions)
        }
        return .hidden
    }

    var backgroundView: some View {
        Rectangle()
            .fill(settings.windowBackgroundStyle)
            .ignoresSafeArea()
    }

    @ViewBuilder
    var currentScreen: some View {
        switch navigation.currentRoute {
        case .search:
            SearchScreen(
                viewModel: searchViewModel,
                isSearchFocused: $isSearchFieldFocused,
                onOpenVideo: openVideoFromSearch,
                onOpenChannel: { channel in
                    navigation.showChannel(channel)
                    searchViewModel.suspendResultsForNavigation()
                },
                onOpenPlaylist: { playlist in
                    navigation.showPlaylist(
                        PlaylistReference(
                            playlistId: playlist.playlistId,
                            title: playlist.title,
                            kind: playlist.referenceKind
                        )
                    )
                    searchViewModel.suspendResultsForNavigation()
                },
                onRetry: handleToolbarSubmit,
                onSubmit: handleToolbarSubmit,
                onClear: handleToolbarClear,
                onFocusChange: handleSearchFieldFocusChange,
                onMoveSuggestion: moveSelectedSearchSuggestion,
                onAcceptAssist: acceptSelectedSearchAssist
            )
        case .home:
            homeScreen
        case .watchHistory:
            watchHistoryScreen
        case .playlistLibrary:
            PlaylistLibraryScreen(viewModel: playlistLibraryViewModel)
                .environmentObject(navigation)
                .id("playlist-library-\(navigation.routeRefreshID.uuidString)")
        case .playlistFeed(let playlist):
            PlaylistFeedScreen(
                playlist: playlist,
                libraryPlaylists: playlistLibraryViewModel.playlists
            )
                .environmentObject(navigation)
                .id("\(playlist.id)-\(navigation.routeRefreshID.uuidString)")
        case .channel(let route):
            ChannelPageScreen(
                route: route
            )
                .environmentObject(navigation)
                .id("\(route.channel.channelId)-\(navigation.routeRefreshID.uuidString)")
        case .video(let video):
            PlayerScreen(
                video: video,
                libraryPlaylists: playlistLibraryViewModel.playlists
            )
                .id("\(video.id)-\(navigation.routeRefreshID.uuidString)")
        }
    }

    var homeScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let notice = viewModel.notice {
                    NoticeBanner(
                        text: notice,
                        actionTitle: authSession.status.authenticated ? nil : "Sign In"
                    ) {
                        authSession.isSheetPresented = true
                    }
                }
                contentView
            }
            .padding(24)
        }
    }

    var watchHistoryScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("History")
                    .font(.system(size: 28, weight: .bold))

                Text(historyViewModel.hasActiveFilter ? "Search through your watched videos." : "Your recently watched videos.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                watchHistoryContentView
            }
            .padding(24)
        }
        .task {
            historyViewModel.loadInitial()
        }
    }

    var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { Optional(navigation.selectedSidebarItem) },
                set: { if let item = $0 { navigation.selectSidebarItem(item) } }
            )) {
                ForEach(visibleSidebarItems) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.systemImage)
                            .foregroundStyle(BrandAssets.swiftTubeBlue)
                            .frame(width: 18)
                        Text(item.title)
                    }
                        .tag(item)
                }
            }

            Divider()

            SidebarAccountButton(status: authSession.status) {
                authSession.isSheetPresented = true
            }
            .disabled(!backend.isRunning)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
    }

    @ViewBuilder
    var contentView: some View {
        if viewModel.videos.isEmpty {
            if viewModel.isLoading {
                placeholderGrid
            } else if let error = viewModel.errorMessage {
                EmptyStateView(
                    title: "Couldn’t load recommendations",
                    message: error,
                    actionTitle: "Try Again"
                ) {
                    viewModel.reload()
                }
            } else {
                EmptyStateView(
                    title: "No videos yet",
                    message: "The feed is empty. Try refreshing once the backend is running.",
                    actionTitle: "Refresh"
                ) {
                    viewModel.reload()
                }
            }
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(Array(viewModel.videos.enumerated()), id: \.element.id) { index, video in
                    VideoCard(
                        video: video,
                        onOpenChannel: {
                            openChannel(from: video)
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                    .onTapGesture {
                        navigation.showVideo(video)
                    }
                    .contextMenu {
                        VideoContextMenuContent(
                            video: video,
                            userPlaylists: userOwnedPlaylists,
                            onPlay: { navigation.showVideo(video) },
                            onPlayFromHere: nil,
                            onAddToWatchLater: authSession.status.authenticated ? queueAddToWatchLater(videoID: video.id) : nil,
                            onSaveToPlaylist: authSession.status.authenticated ? { playlistID in
                                queueSaveToPlaylist(videoID: video.id, playlistID: playlistID)
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
                        viewModel.loadMoreIfNeeded(currentVideo: video)
                    }
                    .staggeredFadeIn(id: video.id, index: index, columns: columns.count)
                }
            }

            if viewModel.isLoading {
                LoadingMoreIndicator(text: "Loading more videos...")
                    .padding(.top, 16)
            }
        }
    }

    @ViewBuilder
    var watchHistoryContentView: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 28) {
                historyVideoStack
                    .frame(maxWidth: .infinity, alignment: .leading)

                HistoryActionPanel(
                    isFiltering: historyViewModel.hasActiveFilter,
                    onRefresh: historyViewModel.reload,
                    onOpenOfficialControls: openOfficialHistoryControls
                )
                .frame(width: 310)
            }

            VStack(alignment: .leading, spacing: 20) {
                HistoryActionPanel(
                    isFiltering: historyViewModel.hasActiveFilter,
                    onRefresh: historyViewModel.reload,
                    onOpenOfficialControls: openOfficialHistoryControls
                )

                historyVideoStack
            }
        }
    }

    var placeholderGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(0..<8, id: \.self) { _ in
                PlaceholderCard()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    func refreshCurrentRoute() {
        if searchViewModel.isActive {
            handleToolbarSubmit()
            return
        }

        switch navigation.currentRoute {
        case .search:
            if searchViewModel.lastQuery.isEmpty {
                isSearchFieldFocused = true
            } else {
                handleToolbarSubmit()
            }
        case .home:
            viewModel.reload()
        case .watchHistory:
            historyViewModel.reload()
        case .playlistLibrary:
            playlistLibraryViewModel.reload()
        case .playlistFeed:
            navigation.refreshCurrentRoute()
        case .channel:
            navigation.refreshCurrentRoute()
        case .video:
            navigation.refreshCurrentRoute()
        }
    }

    func selectNumberedSidebarItem(_ number: Int) {
        let index = number - 1
        guard visibleSidebarItems.indices.contains(index) else { return }
        navigation.selectSidebarItem(visibleSidebarItems[index])
    }

    func exitFullscreenIfNeeded() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    @ViewBuilder
    var backendOverlay: some View {
        switch backend.state {
        case .idle, .preparing, .installing, .starting:
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    SwiftTubeSpinner(size: 28)
                    ShimmerText(text: backend.statusMessage, font: .headline)
                    if let logLine = backend.lastLogLine {
                        Text(logLine)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(settings.cardBackgroundColor)
                        .shadow(radius: 12)
                )
            }
        case .failed(let message):
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    Text("Backend Error")
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                    if let logLine = backend.lastLogLine {
                        Text(logLine)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Button("Retry") {
                        backend.retry()
                    }
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(NSColor.windowBackgroundColor))
                        .shadow(radius: 12)
                )
            }
        case .running:
            EmptyView()
        }
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
        let playlistTitle = userOwnedPlaylists.first(where: { $0.playlistId == playlistID })?.title ?? "playlist"
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

    var searchAssistOverlay: some View {
        SearchAssistPanel(
            state: searchAssistState,
            selectedSuggestionIndex: selectedSearchSuggestionIndex,
            onSelectSuggestion: { suggestion in
                searchViewModel.applySuggestion(suggestion)
                handleToolbarSubmit()
            },
            onOpenLink: handleToolbarSubmit
        )
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(0.22), radius: 20, y: 10)
    }

    @ViewBuilder
    var historyVideoStack: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text(historySummaryLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            if historyViewModel.filteredItems.isEmpty {
                if historyViewModel.isLoading && historyViewModel.items.isEmpty {
                    LazyVStack(spacing: 14) {
                        ForEach(0..<6, id: \.self) { _ in
                            HistoryVideoRowPlaceholder()
                        }
                    }
                } else if let error = historyViewModel.errorMessage {
                    EmptyStateView(
                        title: "Couldn’t load watch history",
                        message: error,
                        actionTitle: "Try Again"
                    ) {
                        historyViewModel.reload()
                    }
                } else if historyViewModel.hasActiveFilter {
                    EmptyStateView(
                        title: "No matches yet",
                        message: "YouTube history search didn’t find anything for \"\(historyViewModel.searchQuery)\".",
                        actionTitle: "Clear Search"
                    ) {
                        handleToolbarClear()
                    }
                } else {
                    EmptyStateView(
                        title: "No watch history yet",
                        message: "Once YouTube has history for this account, it will show up here.",
                        actionTitle: "Refresh"
                    ) {
                        historyViewModel.reload()
                    }
                }
            } else {
                LazyVStack(spacing: 4) {
                    ForEach(Array(historyViewModel.filteredItems.enumerated()), id: \.element.id) { index, video in
                        HistoryVideoRow(
                            video: video,
                            isDeleting: mutationCenter.isPending(MutationQueueKey.watchHistory(videoID: video.id)),
                            onOpen: { navigation.showVideo(video) },
                            onOpenChannel: { openChannel(from: video) },
                            onDelete: { removeVideoFromHistory(video) }
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            VideoContextMenuContent(
                                video: video,
                                userPlaylists: userOwnedPlaylists,
                                onPlay: { navigation.showVideo(video) },
                                onPlayFromHere: nil,
                                onAddToWatchLater: authSession.status.authenticated ? queueAddToWatchLater(videoID: video.id) : nil,
                                onSaveToPlaylist: authSession.status.authenticated ? { playlistID in
                                    queueSaveToPlaylist(videoID: video.id, playlistID: playlistID)
                                } : nil,
                                onMoveToPlaylist: nil,
                                onMoveToWatchLater: nil,
                                onRemoveFromCurrentPlaylist: nil,
                                onMoveToTop: nil,
                                onMoveToBottom: nil,
                                onRemoveFromWatchHistory: {
                                    removeVideoFromHistory(video)
                                }
                            )
                        }
                        .onAppear {
                            historyViewModel.loadMoreIfNeeded(currentVideo: video)
                        }
                        .staggeredFadeIn(id: video.id, index: index, columns: 1, batchSize: 18)
                    }
                }

                if historyViewModel.isLoading {
                    LoadingMoreIndicator(text: "Loading more history...")
                        .padding(.top, 8)
                }
            }
        }
    }

    var historySummaryLine: String {
        if historyViewModel.hasActiveFilter {
            return "\(historyViewModel.filteredItems.count) official YouTube history matches for \"\(historyViewModel.searchQuery)\""
        }
        return "\(historyViewModel.totalItemCount) videos synced from YouTube watch history"
    }

    func handleToolbarSubmit() {
        isSearchFieldFocused = false
        let outcome = searchViewModel.submit(navigation: navigation, scope: toolbarSearchScope)
        searchViewModel.dismissAssist()
        if outcome == .search {
            navigation.showSearch()
        } else if outcome == .openedVideoLink {
            searchViewModel.dismissResults()
        }
    }

    func handleToolbarClear() {
        searchViewModel.clearToolbarInput()
        syncHistorySearchQuery()
    }

    func handleBackNavigation() {
        let shouldResumeSearchAfterBack = searchViewModel.hasSuspendedResults && navigation.currentRoute.supportsSearchResultResume
        navigation.goBack()
        if shouldResumeSearchAfterBack {
            searchViewModel.resumeSuspendedResultsIfNeeded()
        }
    }

    func handleForwardNavigation() {
        navigation.goForward()
    }

    func handleToolbarQueryChange() {
        searchViewModel.handleQueryChange(scope: toolbarSearchScope)
        selectedSearchSuggestionIndex = 0
        syncHistorySearchQuery()
    }

    func handleSearchFieldFocusChange(_ focused: Bool) {
        isSearchFieldFocused = focused
        searchAssistDismissTask?.cancel()
        if focused {
            keepSearchAssistVisibleUntil = .distantPast
        } else {
            keepSearchAssistVisibleUntil = Date().addingTimeInterval(0.24)
            searchAssistDismissTask = Task {
                try? await Task.sleep(nanoseconds: 240_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if !isSearchFieldFocused {
                        searchViewModel.dismissAssist()
                        keepSearchAssistVisibleUntil = .distantPast
                    }
                }
            }
        }
    }

    func moveSelectedSearchSuggestion(by delta: Int) -> Bool {
        let suggestions = searchViewModel.suggestions
        guard suggestions.isEmpty == false, searchAssistState.isVisible else { return false }
        let count = suggestions.count
        selectedSearchSuggestionIndex = (selectedSearchSuggestionIndex + delta + count) % count
        return true
    }

    func acceptSelectedSearchAssist() -> Bool {
        if case .link = searchAssistState {
            handleToolbarSubmit()
            return true
        }

        let suggestions = searchViewModel.suggestions
        guard suggestions.indices.contains(selectedSearchSuggestionIndex), searchAssistState.isVisible else {
            return false
        }
        searchViewModel.applySuggestion(suggestions[selectedSearchSuggestionIndex])
        handleToolbarSubmit()
        return true
    }

    func openVideoFromSearch(_ video: VideoItem) {
        isSearchFieldFocused = false
        navigation.showVideo(video)
        DispatchQueue.main.async {
            searchViewModel.suspendResultsForNavigation()
        }
    }

    func openChannel(from video: VideoItem) {
        guard let channel = video.channelReference else { return }
        navigation.showChannel(channel)
    }

    func openChannelFromSearch(_ video: VideoItem) {
        isSearchFieldFocused = false
        openChannel(from: video)
        DispatchQueue.main.async {
            searchViewModel.suspendResultsForNavigation()
        }
    }

    func syncHistorySearchQuery() {
        guard toolbarSearchScope == .history else {
            historyViewModel.updateSearchQuery("")
            return
        }

        let query = searchViewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if SearchViewModel.extractVideoLink(from: query) != nil {
            historyViewModel.updateSearchQuery("")
        } else {
            historyViewModel.updateSearchQuery(query)
        }
    }

    func removeVideoFromHistory(_ video: VideoItem) {
        let previousItems = historyViewModel.items
        let previousFilteredItems = historyViewModel.filteredItems

        mutationCenter.submit(
            key: MutationQueueKey.watchHistory(videoID: video.id),
            successNotice: MutationNotice(
                title: "Removed from history",
                message: nil,
                symbol: "trash",
                accent: .green
            ),
            errorNotice: { error in
                MutationNotice(
                    title: "Couldn’t remove video",
                    message: error.localizedDescription,
                    symbol: "trash",
                    accent: .red
                )
            },
            optimistic: {
                historyViewModel.removeItemsLocally(ids: [video.id])
            },
            rollback: { _ in
                historyViewModel.restore(items: previousItems, filteredItems: previousFilteredItems)
            },
            execute: {
                _ = try await BackendClient.shared.removeWatchHistoryVideo(id: video.id)
            }
        )
    }

    func openOfficialHistoryControls() {
        guard let url = URL(string: "https://myactivity.google.com/product/youtube?hl=en&utm_medium=web&utm_source=youtube") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct ChannelPageScreen: View {
    let route: ChannelRoute

    @StateObject private var viewModel = ChannelPageViewModel()
    @StateObject private var playlistLibraryViewModel = PlaylistLibraryViewModel()
    @AppStorage("channelContentLayoutMode") private var contentLayoutModeRaw = ChannelContentLayoutMode.grid.rawValue
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var mutationCenter = AppMutationCenter.shared

    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var authSession: AuthSessionModel

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = max(proxy.size.width - 48, 0)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if viewModel.header == nil && viewModel.isLoading {
                        ChannelPageLoadingState(
                            route: route,
                            contentLayoutMode: contentLayoutMode,
                            columns: gridColumns(for: contentWidth)
                        )
                    } else {
                        if let header = viewModel.header {
                            ChannelHeaderView(
                                header: header,
                                selectedTab: route.tab,
                                tabs: visibleTabs,
                                searchQuery: route.searchQuery,
                                filterOptions: viewModel.filterOptions,
                                sortOptions: viewModel.sortOptions,
                                subscription: viewModel.subscription,
                                contentLayoutMode: contentLayoutMode,
                                onSelectTab: { tab in
                                    navigation.showChannel(route.channel, tab: tab)
                                },
                                onSelectControl: { option in
                                    viewModel.selectSortOption(option)
                                },
                                onClearFilters: {
                                    viewModel.clearSelectedFilters()
                                },
                                onChangeLayoutMode: { mode in
                                    contentLayoutModeRaw = mode.rawValue
                                },
                                onToggleSubscription: {
                                    viewModel.toggleSubscription()
                                }
                            )
                        }

                        if route.tab == .about {
                            ChannelAboutTabContent(
                                about: viewModel.about,
                                isLoading: viewModel.isLoadingAbout,
                                errorMessage: viewModel.aboutErrorMessage,
                                onRetry: {
                                    viewModel.reload(route: route)
                                }
                            )
                        } else if viewModel.items.isEmpty {
                            if let error = viewModel.errorMessage {
                                EmptyStateView(
                                    title: "Couldn’t load channel",
                                    message: error,
                                    actionTitle: "Try Again"
                                ) {
                                    viewModel.reload(route: route)
                                }
                            } else {
                                EmptyStateView(
                                    title: emptyStateTitle,
                                    message: emptyStateMessage,
                                    actionTitle: route.tab == .search ? "Search Again" : "Refresh"
                                ) {
                                    viewModel.reload(route: route)
                                }
                            }
                        } else if route.tab == .posts {
                            channelPostsContent(for: contentWidth)
                        } else {
                            channelBrowseContent(for: contentWidth)
                        }
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: route.id) {
            viewModel.load(route: route)
        }
        .task(id: authSession.status.authenticated) {
            if authSession.status.authenticated {
                playlistLibraryViewModel.loadInitial()
            }
        }
    }

    private var visibleTabs: [ChannelTabSummary] {
        let baseTabs = viewModel.tabs.filter { $0.kind != .search }
        guard viewModel.header?.aboutContinuationToken != nil else { return baseTabs }
        guard baseTabs.contains(where: { $0.kind == .about }) == false else { return baseTabs }
        return baseTabs + [ChannelTabSummary(kind: .about, title: ChannelTabKind.about.title)]
    }

    private var contentLayoutMode: ChannelContentLayoutMode {
        ChannelContentLayoutMode(rawValue: contentLayoutModeRaw) ?? .grid
    }

    private func gridColumns(for availableWidth: CGFloat) -> [GridItem] {
        let minimumCardWidth: CGFloat = 220
        let maximumColumns = max(1, Int((availableWidth + 20) / (minimumCardWidth + 20)))
        return browseGridColumns(count: min(settings.browseVideoGridPreset.columnCount, maximumColumns))
    }

    @ViewBuilder
    private func channelBrowseContent(for contentWidth: CGFloat) -> some View {
        if contentLayoutMode == .grid {
            LazyVGrid(columns: gridColumns(for: contentWidth), alignment: .leading, spacing: 20) {
                ForEach(viewModel.items, id: \.id) { item in
                    switch item {
                    case .video(let video):
                        VideoCard(
                            video: video,
                            onOpenChannel: {
                                guard let channel = video.channelReference else { return }
                                navigation.showChannel(channel)
                            }
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                        .onTapGesture {
                            navigation.showVideo(video)
                        }
                        .contextMenu {
                            ChannelVideoContextMenu(
                                video: video,
                                userPlaylists: userOwnedPlaylists,
                                isAuthenticated: authSession.status.authenticated,
                                onPlay: { navigation.showVideo(video) },
                                onAddToWatchLater: { queueAddToWatchLater(videoID: video.id) },
                                onSaveToPlaylist: { playlistID in
                                    queueSaveToPlaylist(videoID: video.id, playlistID: playlistID)
                                }
                            )
                        }
                        .onAppear {
                            viewModel.loadMoreIfNeeded(currentItem: item)
                        }
                    case .playlist(let playlist):
                        PlaylistCard(playlist: playlist)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(RoundedRectangle(cornerRadius: 18))
                            .onTapGesture {
                                navigation.showPlaylist(
                                    PlaylistReference(
                                        playlistId: playlist.playlistId,
                                        title: playlist.title,
                                        kind: .userPlaylist
                                    )
                                )
                            }
                            .onAppear {
                                viewModel.loadMoreIfNeeded(currentItem: item)
                            }
                    case .post:
                        EmptyView()
                    }
                }
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(viewModel.items, id: \.id) { item in
                    switch item {
                    case .video(let video):
                        ChannelVideoRow(
                            video: video,
                            onOpen: {
                                navigation.showVideo(video)
                            },
                            onOpenChannel: {
                                guard let channel = video.channelReference else { return }
                                navigation.showChannel(channel)
                            }
                        )
                        .contextMenu {
                            ChannelVideoContextMenu(
                                video: video,
                                userPlaylists: userOwnedPlaylists,
                                isAuthenticated: authSession.status.authenticated,
                                onPlay: { navigation.showVideo(video) },
                                onAddToWatchLater: { queueAddToWatchLater(videoID: video.id) },
                                onSaveToPlaylist: { playlistID in
                                    queueSaveToPlaylist(videoID: video.id, playlistID: playlistID)
                                }
                            )
                        }
                        .onAppear {
                            viewModel.loadMoreIfNeeded(currentItem: item)
                        }
                    case .playlist(let playlist):
                        ChannelPlaylistRow(
                            playlist: playlist,
                            onOpen: {
                                navigation.showPlaylist(
                                    PlaylistReference(
                                        playlistId: playlist.playlistId,
                                        title: playlist.title,
                                        kind: .userPlaylist
                                    )
                                )
                            }
                        )
                        .onAppear {
                            viewModel.loadMoreIfNeeded(currentItem: item)
                        }
                    case .post:
                        EmptyView()
                    }
                }
            }
        }

        if viewModel.isLoadingMore {
            LoadingMoreIndicator(text: "Loading more...")
                .padding(.top, 12)
        }
    }

    @ViewBuilder
    private func channelPostsContent(for contentWidth: CGFloat) -> some View {
        if contentLayoutMode == .grid {
            LazyVGrid(columns: gridColumns(for: contentWidth), alignment: .leading, spacing: 20) {
                ForEach(viewModel.items, id: \.id) { item in
                    if case .post(let post) = item {
                        ChannelPostCard(
                            post: post,
                            channelHeader: viewModel.header,
                            displayMode: .grid,
                            onOpenVideo: { video in
                                navigation.showVideo(video)
                            },
                            onOpenChannel: {
                                navigation.showChannel(route.channel)
                            }
                        )
                        .onAppear {
                            viewModel.loadMoreIfNeeded(currentItem: item)
                        }
                    }
                }
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(viewModel.items, id: \.id) { item in
                    if case .post(let post) = item {
                        ChannelPostCard(
                            post: post,
                            channelHeader: viewModel.header,
                            displayMode: .list,
                            onOpenVideo: { video in
                                navigation.showVideo(video)
                            },
                            onOpenChannel: {
                                navigation.showChannel(route.channel)
                            }
                        )
                        .onAppear {
                            viewModel.loadMoreIfNeeded(currentItem: item)
                        }
                    }
                }
            }
        }

        if viewModel.isLoadingMore {
            LoadingMoreIndicator(text: "Loading more posts...")
                .padding(.top, 8)
        }
    }

    private var emptyStateTitle: String {
        switch route.tab {
        case .about:
            return "No channel details"
        case .search:
            return "No results"
        case .playlists:
            return "No playlists yet"
        case .posts:
            return "No posts yet"
        default:
            return "Nothing here yet"
        }
    }

    private var userOwnedPlaylists: [PlaylistSummary] {
        playlistLibraryViewModel.playlists.filter {
            !["WL", "LL"].contains($0.playlistId)
        }
    }

    private func queueAddToWatchLater(videoID: String) {
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

    private func queueSaveToPlaylist(videoID: String, playlistID: String) {
        let playlistTitle = userOwnedPlaylists.first(where: { $0.playlistId == playlistID })?.title ?? "playlist"
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

    private var emptyStateMessage: String {
        switch route.tab {
        case .about:
            return "YouTube didn’t return this channel’s About details."
        case .search:
            let query = route.searchQuery ?? ""
            return "This channel didn’t return anything for \"\(query)\"."
        case .playlists:
            return "This channel doesn’t have visible playlists right now."
        case .posts:
            return "This channel doesn’t have visible posts right now."
        default:
            return "YouTube didn’t return any items for this tab."
        }
    }
}

private struct ChannelVideoContextMenu: View {
    let video: VideoItem
    let userPlaylists: [PlaylistSummary]
    let isAuthenticated: Bool
    let onPlay: () -> Void
    let onAddToWatchLater: () -> Void
    let onSaveToPlaylist: (String) -> Void

    var body: some View {
        VideoContextMenuContent(
            video: video,
            userPlaylists: userPlaylists,
            onPlay: onPlay,
            onPlayFromHere: nil,
            onAddToWatchLater: isAuthenticated ? onAddToWatchLater : nil,
            onSaveToPlaylist: isAuthenticated ? onSaveToPlaylist : nil,
            onMoveToPlaylist: nil,
            onMoveToWatchLater: nil,
            onRemoveFromCurrentPlaylist: nil,
            onMoveToTop: nil,
            onMoveToBottom: nil,
            onRemoveFromWatchHistory: nil
        )
    }
}

private struct ChannelPageLoadingState: View {
    let route: ChannelRoute
    let contentLayoutMode: ChannelContentLayoutMode
    let columns: [GridItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            RoundedRectangle(cornerRadius: 28)
                .fill(Color.white.opacity(0.08))
                .frame(height: 220)

            HStack(alignment: .top, spacing: 24) {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 140, height: 140)

                VStack(alignment: .leading, spacing: 14) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 280, height: 34)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.07))
                        .frame(width: 180, height: 20)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.06))
                        .frame(maxWidth: 420)
                        .frame(height: 18)
                    RoundedRectangle(cornerRadius: 999)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 128, height: 42)
                }
            }
            .redacted(reason: .placeholder)

            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 999)
                        .fill(Color.white.opacity(index == 0 ? 0.14 : 0.08))
                        .frame(width: index == 0 ? 128 : 104, height: 38)
                }
            }

            if route.tab == .about {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.07))
                            .frame(maxWidth: .infinity)
                            .frame(height: 18)
                    }
                }
                .redacted(reason: .placeholder)
            } else if contentLayoutMode == .grid {
                PlaceholderCardGrid(columns: columns)
            } else {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(0..<6, id: \.self) { _ in
                        HistoryVideoRowPlaceholder()
                    }
                }
            }
        }
        .redacted(reason: .placeholder)
    }
}

private struct ChannelHeaderView: View {
    @EnvironmentObject private var authSession: AuthSessionModel

    let header: ChannelHeader
    let selectedTab: ChannelTabKind
    let tabs: [ChannelTabSummary]
    let searchQuery: String?
    let filterOptions: [ChannelSortOption]
    let sortOptions: [ChannelSortOption]
    let subscription: SubscriptionState?
    let contentLayoutMode: ChannelContentLayoutMode
    let onSelectTab: (ChannelTabKind) -> Void
    let onSelectControl: (ChannelSortOption) -> Void
    let onClearFilters: () -> Void
    let onChangeLayoutMode: (ChannelContentLayoutMode) -> Void
    let onToggleSubscription: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let bannerURL = header.bannerURL {
                ChannelBannerView(url: bannerURL)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    channelAvatar(size: 160, iconSize: 40)
                    headerTextBlock(
                        titleSize: 44,
                        subtitleFont: .title3.weight(.semibold),
                        descriptionFont: .title3
                    )
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 18) {
                        channelAvatar(size: 116, iconSize: 28)
                        headerTextBlock(
                            titleSize: 34,
                            subtitleFont: .headline.weight(.semibold),
                            descriptionFont: .headline
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 18) {
                    channelAvatar(size: 96, iconSize: 24)
                    headerTextBlock(
                        titleSize: 30,
                        subtitleFont: .subheadline.weight(.semibold),
                        descriptionFont: .subheadline
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !tabs.isEmpty {
                ChannelTabStrip(
                    tabs: tabs,
                    selectedTab: selectedTab,
                    onSelectTab: onSelectTab
                )
            }

            if selectedTab == .search, let searchQuery, !searchQuery.isEmpty {
                Text("Search results for \"\(searchQuery)\"")
                    .font(.title3.weight(.semibold))
            }

            if selectedTab != .about {
                ChannelSortToolbar(
                    filterOptions: filterOptions,
                    options: sortOptions,
                    contentLayoutMode: contentLayoutMode,
                    onSelect: onSelectControl,
                    onClearFilters: onClearFilters,
                    onChangeLayoutMode: onChangeLayoutMode
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var identityLine: String {
        [header.handleText, header.subscriberCountText, header.videoCountText]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " • ")
    }

    private var subscribeButtonTitle: String {
        let title = subscription?.buttonText?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? header.subscribeButtonTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty == false ? title : nil) ?? "Subscribe"
    }

    private var isSubscribed: Bool {
        subscription?.subscribed ?? subscribeButtonTitle.lowercased().contains("subscribed")
    }

    @ViewBuilder
    private func channelAvatar(size: CGFloat, iconSize: CGFloat) -> some View {
        CachedAsyncImage(url: header.avatarURL, maxPixelSize: 960, contentMode: .fill) {
            Circle()
                .fill(Color.gray.opacity(0.22))
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                )
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    @ViewBuilder
    private func headerTextBlock(titleSize: CGFloat, subtitleFont: Font, descriptionFont: Font) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(header.channel.title ?? "Channel")
                .font(.system(size: titleSize, weight: .bold))
                .lineLimit(2)

            if !identityLine.isEmpty {
                Text(identityLine)
                    .font(subtitleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let preview = header.descriptionPreview, !preview.isEmpty {
                Text(preview)
                    .font(descriptionFont)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Button {
                if authSession.status.authenticated == false {
                    authSession.isSheetPresented = true
                } else {
                    onToggleSubscription()
                }
            } label: {
                Text(subscribeButtonTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(isSubscribed ? Color.primary : Color.black)
                    .padding(.horizontal, 22)
                    .frame(height: 46)
                    .background(
                        Capsule()
                            .fill(isSubscribed ? Color.white.opacity(0.14) : Color.white)
                    )
                    .overlay(
                        Capsule()
                            .stroke(isSubscribed ? Color.white.opacity(0.16) : Color.white.opacity(0.72), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(authSession.status.authenticated ? "Subscribe to this channel" : "Sign in to subscribe")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChannelBannerView: View {
    private static let desktopBannerAspectRatio: CGFloat = 2560.0 / 338.0

    let url: URL

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.24, blue: 0.34),
                            Color(red: 0.11, green: 0.14, blue: 0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            CachedAsyncImage(url: url, maxPixelSize: 4096, contentMode: .fill) {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(Self.desktopBannerAspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct ChannelTabStrip: View {
    let tabs: [ChannelTabSummary]
    let selectedTab: ChannelTabKind
    let onSelectTab: (ChannelTabKind) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 28) {
                ForEach(tabs) { tab in
                    Button {
                        onSelectTab(tab.kind)
                    } label: {
                        VStack(spacing: 12) {
                            Text(tab.title)
                                .font(.title3.weight(tab.kind == selectedTab ? .bold : .semibold))
                                .foregroundStyle(tab.kind == selectedTab ? Color.primary : Color.secondary)

                            Capsule()
                                .fill(tab.kind == selectedTab ? Color.white : Color.clear)
                                .frame(height: 3)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
        }
    }
}

private struct ChannelSortToolbar: View {
    let filterOptions: [ChannelSortOption]
    let options: [ChannelSortOption]
    let contentLayoutMode: ChannelContentLayoutMode
    let onSelect: (ChannelSortOption) -> Void
    let onClearFilters: () -> Void
    let onChangeLayoutMode: (ChannelContentLayoutMode) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                if !options.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(options) { option in
                            ChannelToolbarTextButton(
                                title: option.title,
                                isSelected: option.isSelected,
                                action: { onSelect(option) }
                            )
                        }
                    }
                }

                if !filterOptions.isEmpty && !options.isEmpty {
                    divider
                }

                if !filterOptions.isEmpty {
                    HStack(spacing: 10) {
                        ChannelToolbarTextButton(
                            title: "All",
                            isSelected: filterOptions.contains(where: \.isSelected) == false,
                            action: onClearFilters
                        )

                        ForEach(filterOptions) { option in
                            ChannelToolbarTextButton(
                                title: option.title,
                                isSelected: option.isSelected,
                                action: { onSelect(option) }
                            )
                        }
                    }
                }

                if !options.isEmpty || !filterOptions.isEmpty {
                    divider
                }

                HStack(spacing: 10) {
                    ChannelLayoutModeButton(
                        mode: .grid,
                        currentMode: contentLayoutMode,
                        onSelect: onChangeLayoutMode
                    )

                    ChannelLayoutModeButton(
                        mode: .list,
                        currentMode: contentLayoutMode,
                        onSelect: onChangeLayoutMode
                    )
                }
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 30)
    }
}

private struct ChannelLayoutModeButton: View {
    let mode: ChannelContentLayoutMode
    let currentMode: ChannelContentLayoutMode
    let onSelect: (ChannelContentLayoutMode) -> Void

    var body: some View {
        ChannelToolbarIconButton(
            symbolName: mode.symbolName,
            isSelected: currentMode == mode,
            accessibilityLabel: mode.accessibilityLabel,
            action: { onSelect(mode) }
        )
    }
}

struct ChannelToolbarTextButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
        }
        .buttonStyle(ChannelToolbarPillButtonStyle(isSelected: isSelected))
    }
}

struct ChannelToolbarIconButton: View {
    let symbolName: String
    let isSelected: Bool
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(ChannelToolbarPillButtonStyle(isSelected: isSelected, horizontalPadding: 12))
        .help(accessibilityLabel)
    }
}

struct ChannelToolbarPillButtonStyle: ButtonStyle {
    let isSelected: Bool
    var horizontalPadding: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isSelected ? Color.black : Color.white)
            .padding(.horizontal, horizontalPadding)
            .frame(height: 36)
            .background(
                Capsule()
                    .fill(isSelected ? Color.white : Color.white.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.white.opacity(0.75) : Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ChannelDescriptionText: View {
    let text: String
    let font: Font

    var body: some View {
        Text(linkifiedText)
            .font(font)
            .foregroundStyle(.primary)
            .tint(.blue)
            .textSelection(.enabled)
    }

    private var linkifiedText: AttributedString {
        makeLinkifiedAttributedString(text)
    }
}

private func makeLinkifiedAttributedString(_ value: String) -> AttributedString {
    var attributed = AttributedString(value)
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
        return attributed
    }

    let range = NSRange(value.startIndex..., in: value)
    for match in detector.matches(in: value, options: [], range: range) {
        guard let matchRange = Range(match.range, in: value),
              let attributedRange = Range(matchRange, in: attributed) else {
            continue
        }

        attributed[attributedRange].link = match.url
        attributed[attributedRange].foregroundColor = .blue
    }

    return attributed
}

private enum ChannelPostDisplayMode {
    case grid
    case list
}

private struct ChannelPostCard: View {
    let post: ChannelPost
    let channelHeader: ChannelHeader?
    let displayMode: ChannelPostDisplayMode
    let onOpenVideo: (VideoItem) -> Void
    let onOpenChannel: () -> Void

    @State private var isDetailPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: onOpenChannel) {
                    CachedAsyncImage(url: post.authorAvatarURL ?? channelHeader?.avatarURL, maxPixelSize: 160, contentMode: .fill) {
                        Circle()
                            .fill(Color.gray.opacity(0.2))
                            .overlay(
                                Image(systemName: "person.fill")
                                    .foregroundStyle(.secondary)
                            )
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Button(action: onOpenChannel) {
                        Text(post.author)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)

                    if let published = post.publishedTimeText, !published.isEmpty {
                        Text(published)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }

            Text(post.content)
                .font(.body)
                .lineLimit(displayMode == .grid ? compactTextLineLimit : nil)
                .fixedSize(horizontal: false, vertical: displayMode == .list)

            if let attachedVideo = post.attachedVideo {
                if displayMode == .grid {
                    CompactChannelPostVideoPreview(video: attachedVideo, onOpenVideo: onOpenVideo)
                } else {
                    VideoCard(video: attachedVideo, onOpenChannel: nil)
                        .frame(maxWidth: 460, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                        .onTapGesture {
                            onOpenVideo(attachedVideo)
                        }
                }
            }

            Spacer(minLength: displayMode == .grid ? 0 : nil)

            HStack(alignment: .center, spacing: 12) {
                let metrics = [post.likeCountText, post.commentCountText]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }

                if !metrics.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(metrics, id: \.self) { metric in
                            Text(metric)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 0)

                if displayMode == .grid {
                    Button("More") {
                        isDetailPresented = true
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.blue)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: displayMode == .grid ? 348 : nil, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .sheet(isPresented: $isDetailPresented) {
            ChannelPostDetailSheet(
                post: post,
                channelHeader: channelHeader,
                onOpenVideo: onOpenVideo,
                onOpenChannel: onOpenChannel
            )
        }
    }

    private var compactTextLineLimit: Int {
        post.attachedVideo == nil ? 8 : 4
    }
}

private struct CompactChannelPostVideoPreview: View {
    let video: VideoItem
    let onOpenVideo: (VideoItem) -> Void

    var body: some View {
        Button {
            onOpenVideo(video)
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    CachedAsyncImage(url: video.thumbnailURL, maxPixelSize: 640, contentMode: .fill) {
                        ThumbnailPlaceholder(iconSize: 24, cornerRadius: 18)
                    }
                    .frame(width: 156, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                    if let duration = video.durationText {
                        Text(duration)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.black.opacity(0.74)))
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(video.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if !video.tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(video.tags) { tag in
                                VideoTagBadgeView(tag: tag, font: .caption2)
                            }
                        }
                    }

                    let metadata = [video.channel, video.viewCountText, video.publishedTimeText]
                        .compactMap { value in
                            guard let value, !value.isEmpty else { return nil }
                            return value
                        }
                        .joined(separator: " • ")

                    if !metadata.isEmpty {
                        Text(metadata)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ChannelPostDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let post: ChannelPost
    let channelHeader: ChannelHeader?
    let onOpenVideo: (VideoItem) -> Void
    let onOpenChannel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                Text(post.author)
                    .font(.largeTitle.weight(.bold))

                Spacer(minLength: 0)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title2.weight(.semibold))
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 12) {
                        Button(action: onOpenChannel) {
                            CachedAsyncImage(url: post.authorAvatarURL ?? channelHeader?.avatarURL, maxPixelSize: 240, contentMode: .fill) {
                                Circle()
                                    .fill(Color.gray.opacity(0.2))
                                    .overlay(
                                        Image(systemName: "person.fill")
                                            .foregroundStyle(.secondary)
                                    )
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(Circle())
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 6) {
                            Button(action: onOpenChannel) {
                                Text(post.author)
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)

                            if let published = post.publishedTimeText, !published.isEmpty {
                                Text(published)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Text(post.content)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)

                    if let attachedVideo = post.attachedVideo {
                        VideoCard(video: attachedVideo, onOpenChannel: nil)
                            .frame(maxWidth: 520, alignment: .leading)
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                            .onTapGesture {
                                onOpenVideo(attachedVideo)
                            }
                    }

                    let metrics = [post.likeCountText, post.commentCountText]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                    if !metrics.isEmpty {
                        HStack(spacing: 12) {
                            ForEach(metrics, id: \.self) { metric in
                                Text(metric)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 440, alignment: .topLeading)
    }
}

private struct ChannelAboutTabContent: View {
    let about: ChannelAbout?
    let isLoading: Bool
    let errorMessage: String?
    let onRetry: () -> Void

    var body: some View {
        Group {
            if isLoading && about == nil {
                VStack(spacing: 18) {
                    LoadingStatusView(text: "Loading channel details...")
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.white.opacity(0.04))
                        .frame(height: 240)
                }
                .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
            } else if let errorMessage {
                EmptyStateView(
                    title: "Couldn’t load channel details",
                    message: errorMessage,
                    actionTitle: "Try Again"
                ) {
                    onRetry()
                }
            } else if let about {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 56) {
                        aboutPrimaryColumn(about)
                        aboutDetailsColumn(about)
                            .frame(width: 360, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 36) {
                        aboutPrimaryColumn(about)
                        aboutDetailsColumn(about)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No details available.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private func aboutPrimaryColumn(_ about: ChannelAbout) -> some View {
        VStack(alignment: .leading, spacing: 32) {
            if let description = about.description, !description.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Description")
                        .font(.title2.weight(.bold))

                    ChannelDescriptionText(text: description, font: .title3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !about.links.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text(about.linksLabel ?? "Links")
                        .font(.title2.weight(.bold))

                    ForEach(about.links) { link in
                        ChannelAboutLinkRow(link: link)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func aboutDetailsColumn(_ about: ChannelAbout) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Channel Details")
                .font(.title2.weight(.bold))

            if let businessEmailPrompt = about.businessEmailPrompt,
               let businessEmailURL = normalizedSheetURL(about.businessEmailURL) {
                Button {
                    NSWorkspace.shared.open(businessEmailURL)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "envelope")
                        Text(businessEmailPrompt)
                            .font(.headline.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 18)
                    .frame(height: 42)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }

            if let url = about.displayCanonicalChannelUrl ?? about.canonicalChannelUrl {
                ChannelAboutMetricRow(symbol: "link", text: url)
            }
            if let viewCountText = about.viewCountText {
                ChannelAboutMetricRow(symbol: "eye", text: viewCountText)
            }
            if let joinedDateText = about.joinedDateText {
                ChannelAboutMetricRow(symbol: "info.circle", text: joinedDateText)
            }
            if let country = about.country, !country.isEmpty {
                ChannelAboutMetricRow(symbol: "globe", text: country)
            }
            if let subscriberCountText = about.subscriberCountText {
                ChannelAboutMetricRow(symbol: "person.2.wave.2", text: subscriberCountText)
            }
            if let videoCountText = about.videoCountText {
                ChannelAboutMetricRow(symbol: "film", text: videoCountText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChannelAboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let about: ChannelAbout?
    let isLoading: Bool
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                Text(title)
                    .font(.largeTitle.weight(.bold))

                Spacer(minLength: 0)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title2.weight(.semibold))
                }
                .buttonStyle(.plain)
            }

            if isLoading && about == nil {
                Spacer()
                LoadingStatusView(text: "Loading details...")
                Spacer()
            } else if let errorMessage {
                Spacer()
                EmptyStateView(
                    title: "Couldn’t load details",
                    message: errorMessage,
                    actionTitle: "Close"
                ) {
                    dismiss()
                }
                Spacer()
            } else if let about {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let description = about.description, !description.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Description")
                                    .font(.title2.weight(.bold))
                                Text(description)
                                    .font(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !about.links.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(about.linksLabel ?? "Links")
                                    .font(.title2.weight(.bold))

                                ForEach(about.links) { link in
                                    ChannelAboutLinkRow(link: link)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("More Info")
                                .font(.title2.weight(.bold))

                            if let businessEmailPrompt = about.businessEmailPrompt,
                               let businessEmailURL = normalizedSheetURL(about.businessEmailURL) {
                                Button {
                                    NSWorkspace.shared.open(businessEmailURL)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "envelope")
                                        Text(businessEmailPrompt)
                                            .font(.headline.weight(.semibold))
                                    }
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 18)
                                    .frame(height: 42)
                                    .background(
                                        Capsule()
                                            .fill(Color.white.opacity(0.08))
                                    )
                                }
                                .buttonStyle(.plain)
                                .padding(.bottom, 4)
                            }

                            if let url = about.displayCanonicalChannelUrl ?? about.canonicalChannelUrl {
                                ChannelAboutMetricRow(symbol: "play.rectangle", text: url)
                            }
                            if let joinedDateText = about.joinedDateText {
                                ChannelAboutMetricRow(symbol: "info.circle", text: joinedDateText)
                            }
                            if let subscriberCountText = about.subscriberCountText {
                                ChannelAboutMetricRow(symbol: "person.2.wave.2", text: subscriberCountText)
                            }
                            if let videoCountText = about.videoCountText {
                                ChannelAboutMetricRow(symbol: "film", text: videoCountText)
                            }
                            if let viewCountText = about.viewCountText {
                                ChannelAboutMetricRow(symbol: "arrow.up.forward", text: viewCountText)
                            }
                            if let country = about.country, !country.isEmpty {
                                ChannelAboutMetricRow(symbol: "globe", text: country)
                            }
                        }
                    }
                }
            } else {
                Spacer()
                Text("No details available.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(28)
    }
}

private struct ChannelAboutLinkRow: View {
    let link: ChannelLink

    var body: some View {
        Button {
            guard let url = link.resolvedURL else { return }
            NSWorkspace.shared.open(url)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                CachedAsyncImage(url: link.faviconURL, maxPixelSize: 128, contentMode: .fit) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            Image(systemName: "globe")
                                .foregroundStyle(.secondary)
                        )
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(link.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    Text(link.displayURL)
                        .font(.body)
                        .foregroundStyle(Color.blue)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

private struct ChannelAboutMetricRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.secondary)

            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private func normalizedSheetURL(_ value: String?) -> URL? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false else {
        return nil
    }

    if let url = URL(string: value), url.scheme != nil {
        return url
    }

    if value.hasPrefix("/") {
        return URL(string: "https://www.youtube.com\(value)")
    }

    return URL(string: "https://\(value)")
}

private struct PlaceholderCardGrid: View {
    let columns: [GridItem]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(0..<8, id: \.self) { _ in
                PlaceholderCard()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct PlaylistLibraryScreen: View {
    @ObservedObject var viewModel: PlaylistLibraryViewModel
    @EnvironmentObject private var navigation: AppNavigationModel

    private let columns = [
        GridItem(.adaptive(minimum: 240), spacing: 20, alignment: .top)
    ]

    private var displayedPlaylists: [PlaylistSummary] {
        viewModel.playlists.filter { $0.referenceKind == .userPlaylist }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Playlists")
                    .font(.largeTitle.weight(.bold))

                content
            }
            .padding(.vertical, 24)
            .padding(.leading, 32)
            .padding(.trailing, 24)
        }
        .task {
            viewModel.loadInitial()
        }
    }

    @ViewBuilder
    private var content: some View {
        if displayedPlaylists.isEmpty {
            if viewModel.isLoading {
                PlaylistLibraryPlaceholderGrid(columns: columns)
            } else if let error = viewModel.errorMessage {
                EmptyStateView(
                    title: "Couldn’t load playlists",
                    message: error,
                    actionTitle: "Try Again"
                ) {
                    viewModel.reload()
                }
            } else {
                EmptyStateView(
                    title: "No playlists yet",
                    message: "Your user-created playlists library is empty.",
                    actionTitle: "Refresh"
                ) {
                    viewModel.reload()
                }
            }
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(displayedPlaylists) { playlist in
                    Button {
                        navigation.showPlaylist(
                            PlaylistReference(
                                playlistId: playlist.playlistId,
                                title: playlist.title,
                                kind: playlist.referenceKind
                            )
                        )
                    } label: {
                        PlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        guard playlist.id == displayedPlaylists.last?.id,
                              let lastLoadedPlaylist = viewModel.playlists.last else {
                            return
                        }
                        viewModel.loadMoreIfNeeded(currentPlaylist: lastLoadedPlaylist)
                    }
                }
            }

            if viewModel.isLoading {
                LoadingMoreIndicator(text: "Loading more playlists...")
                    .padding(.top, 16)
            }
        }
    }
}

private struct PlaylistFeedScreen: View {
    @StateObject private var viewModel: PlaylistFeedViewModel
    @ObservedObject private var mutationCenter = AppMutationCenter.shared
    @EnvironmentObject private var navigation: AppNavigationModel
    let libraryPlaylists: [PlaylistSummary]

    init(playlist: PlaylistReference, libraryPlaylists: [PlaylistSummary]) {
        self.libraryPlaylists = libraryPlaylists
        _viewModel = StateObject(wrappedValue: PlaylistFeedViewModel(playlist: playlist))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        summaryColumn
                            .frame(width: 312)
                        playlistList
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 24) {
                        summaryColumn
                        playlistList
                    }
                }
            }
            .padding(24)
        }
        .task {
            viewModel.loadInitial()
        }
        .onChange(of: viewModel.feed?.playlistId) { _, _ in
            syncNavigationSession()
        }
        .onChange(of: viewModel.items) { _, _ in
            syncNavigationSession()
        }
    }

    @ViewBuilder
    private var summaryColumn: some View {
        if viewModel.isLoading && viewModel.items.isEmpty {
            PlaylistFeedSummaryPlaceholder(title: viewModel.playlist.title)
        } else {
            let summaryPlaylist = libraryPlaylists.first(where: { $0.playlistId == viewModel.playlist.playlistId })
                ?? PlaylistSummary(
                    playlistId: viewModel.playlist.playlistId,
                    title: viewModel.feed?.title ?? viewModel.playlist.title,
                    privacy: viewModel.feed?.privacy,
                    itemCountText: viewModel.feed?.itemCountText,
                    updatedText: nil,
                    thumbnails: []
                )

            VStack(alignment: .leading, spacing: 18) {
                ZStack(alignment: .bottomTrailing) {
                    PlaylistFeedArtwork(playlist: summaryPlaylist)
                        .frame(
                            width: 312,
                            height: 312 / CGFloat(summaryPlaylist.artworkAspectRatio)
                        )

                    if let count = viewModel.feed?.itemCountText {
                        Text(count)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(14)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(viewModel.feed?.title ?? viewModel.playlist.title)
                        .font(.system(size: 34, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)

                    let details = [viewModel.feed?.ownerText, viewModel.feed?.privacy, viewModel.feed?.itemCountText]
                        .compactMap { $0 }
                    if !details.isEmpty {
                        Text(details.joined(separator: " • "))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        playPlaylist(startingWith: viewModel.items.first)
                    } label: {
                        Label("Play All", systemImage: "play.fill")
                            .font(.headline.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PlaylistPrimaryActionButtonStyle())
                    .disabled(viewModel.items.isEmpty)

                    Button {
                        if let randomVideo = viewModel.items.randomElement() {
                            navigation.showVideo(
                                randomVideo,
                                playlistContext: (reference: viewModel.playlist, feed: resolvedFeedForSession)
                            )
                            navigation.activePlaylistShuffleEnabled = true
                        }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.headline.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PlaylistPrimaryActionButtonStyle())
                    .disabled(viewModel.items.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var playlistList: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Videos")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.items.isEmpty {
                if viewModel.isLoading {
                    LazyVStack(spacing: 14) {
                        ForEach(0..<6, id: \.self) { _ in
                            PlaylistFeedPlaceholderRow()
                        }
                    }
                } else if let error = viewModel.errorMessage {
                    EmptyStateView(
                        title: "Couldn’t load playlist",
                        message: error,
                        actionTitle: "Try Again"
                    ) {
                        viewModel.reload()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    EmptyStateView(
                        title: "This playlist is empty",
                        message: "There are no videos here yet.",
                        actionTitle: "Refresh"
                    ) {
                        viewModel.reload()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                if #available(macOS 27.0, *) {
                    modernPlaylistList
                } else {
                    legacyPlaylistList
                }
            }
        }
    }

    @available(macOS 27.0, *)
    private var modernPlaylistList: some View {
        LazyVStack(spacing: 4) {
            ForEach(viewModel.items, id: \.playlistIdentity) { video in
                playlistRow(video, usesSystemReordering: true)
                    .staggeredFadeIn(
                        id: video.playlistIdentity,
                        index: viewModel.items.firstIndex(where: { $0.playlistIdentity == video.playlistIdentity }) ?? 0,
                        columns: 1
                    )
            }
            .reorderable()

            loadingMoreRows
        }
        .reorderContainer(for: VideoItem.self, itemID: \.playlistIdentity) { difference in
            viewModel.reorderItems(using: difference)
        }
    }

    private var legacyPlaylistList: some View {
        LazyVStack(spacing: 4) {
            ForEach(Array(viewModel.items.enumerated()), id: \.element.playlistIdentity) { index, video in
                PlaylistReorderDropZone {
                    viewModel.reorderItem(withID: $0, toInsertionIndex: index)
                }
                playlistRow(video, usesSystemReordering: false)
                    .staggeredFadeIn(
                        id: video.playlistIdentity,
                        index: index,
                        columns: 1
                    )
            }
            PlaylistReorderDropZone {
                viewModel.reorderItem(withID: $0, toInsertionIndex: viewModel.items.count)
            }

            loadingMoreRows
        }
    }

    @ViewBuilder
    private var loadingMoreRows: some View {
        if viewModel.isLoading {
            LoadingMoreIndicator(text: "Loading more videos...")
                .padding(.top, 8)
        }
    }

    private func playlistRow(_ video: VideoItem, usesSystemReordering: Bool) -> some View {
        PlaylistFeedDraggableRow(
            video: video,
            usesSystemReordering: usesSystemReordering,
            isCurrent: isCurrent(video),
            isMutating: viewModel.mutationIDs.contains(video.playlistSetVideoId ?? ""),
            onPlay: { playPlaylist(startingWith: video) },
            onOpenChannel: {
                guard let channel = video.channelReference else { return }
                navigation.showChannel(channel)
            }
        )
        .contextMenu {
            VideoContextMenuContent(
                video: video,
                userPlaylists: movableLibraryPlaylists(excluding: viewModel.playlist.playlistId),
                onPlay: { playPlaylist(startingWith: video) },
                onPlayFromHere: { playPlaylist(startingWith: video) },
                onAddToWatchLater: viewModel.playlist.kind == .watchLater ? nil : queueAddToWatchLater(videoID: video.id),
                onSaveToPlaylist: { playlistID in queueSaveToPlaylist(videoID: video.id, playlistID: playlistID) },
                onMoveToPlaylist: video.playlistCanRemove ? { playlistID in movePlaylistVideo(video, to: playlistID) } : nil,
                onMoveToWatchLater: viewModel.playlist.kind == .watchLater || !video.playlistCanRemove ? nil : {
                    viewModel.moveItemToWatchLater(video)
                },
                onRemoveFromCurrentPlaylist: video.playlistCanRemove ? { viewModel.removeItem(video) } : nil,
                onMoveToTop: video.playlistCanMoveToTop ? { viewModel.moveItemToTop(video) } : nil,
                onMoveToBottom: video.playlistCanMoveToBottom ? { viewModel.moveItemToBottom(video) } : nil,
                onRemoveFromWatchHistory: nil
            )
        }
        .onAppear {
            viewModel.loadMoreIfNeeded(currentVideo: video)
        }
    }

    private var resolvedFeedForSession: PlaylistFeed {
        let baseFeed = viewModel.feed ?? PlaylistFeed(
            playlistId: viewModel.playlist.playlistId,
            title: viewModel.playlist.title,
            ownerText: nil,
            privacy: nil,
            itemCountText: nil,
            items: viewModel.items,
            continuation: nil
        )
        let resolvedTitle = baseFeed.title == "Playlist" ? viewModel.playlist.title : baseFeed.title
        return baseFeed.with(title: resolvedTitle, items: viewModel.items)
    }

    private func queueAddToWatchLater(videoID: String) -> () -> Void {
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

    private func queueSaveToPlaylist(videoID: String, playlistID: String) {
        let playlistTitle = libraryPlaylists.first(where: { $0.playlistId == playlistID })?.title ?? "playlist"
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

    private func movePlaylistVideo(_ video: VideoItem, to playlistID: String) {
        let destinationTitle = libraryPlaylists.first(where: { $0.playlistId == playlistID })?.title ?? "playlist"
        viewModel.moveItem(video, to: playlistID, destinationTitle: destinationTitle)
    }

    private func syncNavigationSession() {
        navigation.syncActivePlaylistFeed(reference: viewModel.playlist, feed: resolvedFeedForSession)
    }

    private func playPlaylist(startingWith video: VideoItem?) {
        guard let video else { return }
        navigation.showVideo(
            video,
            playlistContext: (reference: viewModel.playlist, feed: resolvedFeedForSession)
        )
    }

    private func isCurrent(_ video: VideoItem) -> Bool {
        navigation.activePlaylistReference?.playlistId == viewModel.playlist.playlistId
            && navigation.activePlaylistCurrentVideoID == video.id
    }

    private func movableLibraryPlaylists(excluding playlistID: String) -> [PlaylistSummary] {
        libraryPlaylists.filter {
            !["WL", "LL", playlistID].contains($0.playlistId)
        }
    }
}

private struct PlaylistCard: View {
    @ObservedObject private var settings = AppSettings.shared
    let playlist: PlaylistSummary

    var body: some View {
        let cornerRadius = settings.thumbnailCornerStyle.radius(default: 18)

        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                PlaylistArtworkImage(
                    playlist: playlist,
                    cornerRadius: cornerRadius,
                    maxPixelSize: 640
                )
                .aspectRatio(CGFloat(playlist.artworkAspectRatio), contentMode: .fit)

                if playlist.hasSquareArtwork {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.78)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                    playlistDetails(foreground: .white, secondary: .white.opacity(0.72))
                        .padding(14)
                }

                countBadge
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)
            }

            if !playlist.hasSquareArtwork {
                playlistDetails(foreground: .primary, secondary: .secondary)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var countBadge: some View {
        if let count = playlist.itemCountText, !count.isEmpty {
            Text(count)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private func playlistDetails(foreground: Color, secondary: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(playlist.title)
                .font(.headline)
                .foregroundStyle(foreground)
                .lineLimit(2)

            let metadata = [playlist.privacy, playlist.updatedText]
                .compactMap { $0 }
                .joined(separator: " • ")
            if !metadata.isEmpty {
                Text(metadata)
                    .font(.subheadline)
                    .foregroundStyle(secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct PlaylistFeedArtwork: View {
    @ObservedObject private var settings = AppSettings.shared
    let playlist: PlaylistSummary

    var body: some View {
        PlaylistArtworkImage(
            playlist: playlist,
            cornerRadius: settings.thumbnailCornerStyle.radius(default: 28),
            maxPixelSize: 720
        )
    }
}

private struct PlaylistArtworkImage: View {
    let playlist: PlaylistSummary
    let cornerRadius: CGFloat
    let maxPixelSize: Int

    var body: some View {
        Group {
            if playlist.referenceKind == .userPlaylist {
                CachedAsyncImage(url: playlist.thumbnailURL, maxPixelSize: maxPixelSize, contentMode: .fill) {
                    placeholder
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            } else {
                LinearGradient(
                    colors: playlist.referenceKind == .watchLater
                        ? [Color(red: 0.20, green: 0.44, blue: 0.94), Color(red: 0.08, green: 0.16, blue: 0.36)]
                        : [BrandAssets.youtubeLightRed, BrandAssets.youtubeDarkRed],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: playlist.referenceKind == .watchLater ? "clock.fill" : "hand.thumbsup.fill")
                            .font(.system(size: 42, weight: .bold))
                        Text(playlist.title)
                            .font(.title3.weight(.bold))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .background(Color.gray.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Color(red: 0.24, green: 0.40, blue: 0.54), Color(red: 0.06, green: 0.13, blue: 0.20)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: "music.note.list")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
        )
    }
}

private struct PlaylistFeedPlaceholderRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 11)
                .fill(Color.white.opacity(0.08))
                .frame(width: 28, height: 28)
                .padding(.top, 50)

            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.08))
                .frame(width: 228, height: 128)

            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.08))
                    .frame(maxWidth: 360)
                    .frame(height: 24)
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.06))
                    .frame(maxWidth: 220)
                    .frame(height: 18)
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 170, height: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .redacted(reason: .placeholder)
    }
}

private struct PlaylistPrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.black.opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.42))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(
                        Color.white.opacity(
                            isEnabled
                                ? (configuration.isPressed ? 0.86 : 1)
                                : 0.24
                        )
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct PlaylistVideoRow: View {
    let video: VideoItem
    let isMutating: Bool
    let onOpenChannel: (() -> Void)?

    private var metadataChips: [String] {
        [video.viewCountText, video.publishedTimeText]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            InlineVideoThumbnail(
                video: video,
                width: 168,
                height: 95,
                cornerRadius: 10,
                maxPixelSize: 480,
                placeholderIconSize: 24
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(video.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                VideoChannelIdentityLine(
                    avatarURL: video.channelAvatarURL,
                    channelID: video.channelId,
                    channel: video.channel,
                    avatarSize: 20,
                    font: .system(size: 14, weight: .medium),
                    onOpenChannel: onOpenChannel
                )

                if !video.tags.isEmpty || metadataChips.isEmpty == false {
                    VideoMetadataChipRow(tags: video.tags, items: metadataChips)
                }

                if isMutating {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlaylistFeedDraggableRow: View {
    @ObservedObject private var settings = AppSettings.shared
    let video: VideoItem
    let usesSystemReordering: Bool
    let isCurrent: Bool
    let isMutating: Bool
    let onPlay: () -> Void
    let onOpenChannel: (() -> Void)?

    @State private var isHovered = false

    private var canReorder: Bool {
        video.playlistSetVideoId != nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Group {
                if usesSystemReordering {
                    rowHandle
                } else {
                    rowHandle.draggable(video.playlistIdentity)
                }
            }

            PlaylistVideoRow(
                video: video,
                isMutating: isMutating,
                onOpenChannel: onOpenChannel
            )

            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(
                    isCurrent
                        ? Color.accentColor.opacity(0.14)
                        : (isHovered ? settings.hoverCardBackgroundColor : .clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(
                    isCurrent
                        ? Color.accentColor.opacity(0.26)
                        : Color.white.opacity(isHovered ? 0.08 : 0),
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onTapGesture(perform: onPlay)
        .onHover { hovering in
            withAnimation(settings.hoverAnimationsEnabled ? .easeOut(duration: 0.14) : nil) {
                isHovered = hovering
            }
        }
    }

    private var rowHandle: some View {
        PlaylistRowHandle(
            isHovered: isHovered,
            canReorder: canReorder,
            fallbackText: video.playlistIndexText,
            isCurrent: isCurrent,
            fullHeight: 95
        )
    }
}

private struct PlaylistReorderDropZone: View {
    let onInsert: (String) -> Bool
    @State private var isTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 999, style: .continuous)
            .fill(isTargeted ? Color.blue.opacity(0.65) : .clear)
            .frame(height: isTargeted ? 5 : 10)
            .padding(.leading, 48)
            .padding(.trailing, 16)
            .animation(.easeOut(duration: 0.12), value: isTargeted)
            .dropDestination(for: String.self) { items, _ in
                guard let draggedID = items.first else { return false }
                return onInsert(draggedID)
            } isTargeted: { hovering in
                isTargeted = hovering
            }
    }
}

private struct PlaylistRowHandle: View {
    let isHovered: Bool
    let canReorder: Bool
    let fallbackText: String?
    let isCurrent: Bool
    let fullHeight: CGFloat

    var body: some View {
        Group {
            if isHovered && canReorder {
                Image(systemName: "line.3.horizontal")
                    .font(.title3.weight(.semibold))
            } else if let fallbackText {
                Text(fallbackText)
                    .font(.headline.monospacedDigit())
            } else if isCurrent {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
            } else {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .opacity(0)
            }
        }
        .foregroundStyle(isCurrent ? .blue : .secondary)
        .frame(width: 32, height: fullHeight, alignment: .center)
        .contentShape(Rectangle())
    }
}

private struct BrandToolbarLabel: View {
    var body: some View {
        HStack(spacing: 6) {
            if let logo = BrandAssets.logo {
                Image(nsImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
            }

            Text("SwiftTube")
                .fontWeight(.semibold)
        }
    }
}

private struct AuthToolbarLabel: View {
    let status: AuthStatusResponse

    var body: some View {
        Group {
            if status.authenticated {
                if let avatarURL = status.avatarURL {
                    CachedAsyncImage(url: avatarURL, maxPixelSize: 96) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .padding(1.5)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
        .contentShape(Circle())
    }
}

private struct PlaylistLibraryPlaceholderGrid: View {
    let columns: [GridItem]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.gray.opacity(0.18))
                        .aspectRatio(16 / 9, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.gray.opacity(0.22))
                        .frame(height: 18)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.16))
                        .frame(width: 160, height: 14)
                }
                .redacted(reason: .placeholder)
            }
        }
    }
}

private struct PlaylistFeedSummaryPlaceholder: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            RoundedRectangle(cornerRadius: 28)
                .fill(Color.white.opacity(0.08))
                .frame(width: 312, height: 312)

            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 190, height: 16)
            }
            .redacted(reason: .placeholder)

            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 999)
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 46)
                RoundedRectangle(cornerRadius: 999)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 46)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AuthConnectionSheet: View {
    @EnvironmentObject private var authSession: AuthSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var isWebSignInPresented = false

    var body: some View {
        VStack(spacing: 24) {
            Text("YouTube Account")
                .font(.title2.weight(.bold))

            if authSession.status.authenticated {
                HStack(spacing: 12) {
                    AccountAvatarImage(url: authSession.status.avatarURL, size: 48, fallbackSymbol: "person.crop.circle.badge.checkmark")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(authSession.status.displayName?.contentNilIfBlank ?? "Connected")
                            .font(.headline)
                        Text(authSession.status.accountIdentifier ?? authSession.status.browserLabel ?? "YouTube")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Disconnect") {
                        Task { await authSession.disconnect() }
                    }
                    .disabled(authSession.isWorking)
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.separator.opacity(0.9), lineWidth: 0.7)
                )
            } else {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(BrandAssets.swiftTubeBlue)

                VStack(spacing: 6) {
                    Text("Sign in to SwiftTube")
                        .font(.title3.weight(.semibold))
                    Text("Use Google in a secure session owned only by SwiftTube.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    authSession.clearError()
                    isWebSignInPresented = true
                } label: {
                    Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(authSession.isWorking)
            }

            if authSession.isWorking {
                LoadingStatusView(text: "Connecting...", spinnerSize: 20)
            }

            if let errorMessage = authSession.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 520)
        .sheet(isPresented: $isWebSignInPresented) {
            YouTubeWebLoginSheet {
                isWebSignInPresented = false
            }
            .environmentObject(authSession)
        }
        .onChange(of: authSession.status.authenticated) { _, authenticated in
            guard authenticated else { return }
            isWebSignInPresented = false
            dismiss()
        }
    }
}

private extension String {
    var contentNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct EmptyStateView: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(title)
                .font(.title2)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button(actionTitle) {
                action()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

private struct NoticeBanner: View {
    let text: String
    let actionTitle: String?
    let action: () -> Void

    init(text: String, actionTitle: String? = nil, action: @escaping () -> Void = {}) {
        self.text = text
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle")
                .foregroundColor(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

private struct AppCommandHandler: NSViewRepresentable {
    let onRefresh: () -> Void
    let onSelectNumberedTab: (Int) -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.updateActions(from: self)
    }

    func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator {
        private final class CommandActions: @unchecked Sendable {
            let onRefresh: () -> Void
            let onSelectNumberedTab: (Int) -> Void
            let onEscape: () -> Void

            @MainActor
            init(from parent: AppCommandHandler) {
                onRefresh = parent.onRefresh
                onSelectNumberedTab = parent.onSelectNumberedTab
                onEscape = parent.onEscape
            }
        }

        // NSEvent local monitors execute on the main thread, although AppKit's callback
        // signature does not encode that guarantee. The sendable box keeps actor-bound
        // callbacks out of the event bridge until `MainActor.assumeIsolated` invokes them.
        nonisolated(unsafe) private var actions: CommandActions
        private var monitor: Any?

        @MainActor
        init(parent: AppCommandHandler) {
            actions = CommandActions(from: parent)
        }

        @MainActor
        func updateActions(from parent: AppCommandHandler) {
            actions = CommandActions(from: parent)
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let actions = self.actions

                if flags == .command, event.keyCode == 15 {
                    MainActor.assumeIsolated { actions.onRefresh() }
                    return nil
                }

                if flags == .command, let number = Self.commandNumber(from: event) {
                    MainActor.assumeIsolated { actions.onSelectNumberedTab(number) }
                    return nil
                }

                if flags.isEmpty, event.keyCode == 53 {
                    MainActor.assumeIsolated { actions.onEscape() }
                }

                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }

        private static func commandNumber(from event: NSEvent) -> Int? {
            switch event.keyCode {
            case 18: return 1
            case 19: return 2
            case 20: return 3
            case 21: return 4
            case 23: return 5
            case 22: return 6
            case 26: return 7
            case 28: return 8
            case 25: return 9
            default: return nil
            }
        }
    }
}

struct PlaceholderCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LoadingPlaceholderBlock(cornerRadius: 12)
                .aspectRatio(16 / 9, contentMode: .fit)
            LoadingPlaceholderBlock(cornerRadius: 6)
                .frame(height: 16)
            LoadingPlaceholderBlock(cornerRadius: 6)
                .frame(height: 12)
            LoadingPlaceholderBlock(cornerRadius: 6)
                .frame(height: 12)
                .padding(.trailing, 80)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppSettings.shared.cardBackgroundColor)
        )
        .redacted(reason: .placeholder)
    }
}

private struct SearchAssistPanel: View {
    let state: SearchAssistState
    let selectedSuggestionIndex: Int
    let onSelectSuggestion: (String) -> Void
    let onOpenLink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .hidden:
                EmptyView()
            case .link(let linkPreview):
                SearchLinkDetectedCard(linkPreview: linkPreview, onOpen: onOpenLink)
                    .transition(.scale(scale: 0.98).combined(with: .opacity))
            case .loading:
                LoadingStatusView(text: "Finding suggestions...", spinnerSize: 18)
                .padding(14)
                .transition(.move(edge: .top).combined(with: .opacity))
            case .suggestions(let suggestions):
                ForEach(Array(suggestions.enumerated()), id: \.element) { index, suggestion in
                    SearchSuggestionRow(
                        suggestion: suggestion,
                        isSelected: index == selectedSuggestionIndex,
                        onSelect: { onSelectSuggestion(suggestion) }
                    )
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.snappy(duration: 0.2, extraBounce: 0), value: state)
    }
}

private struct SearchSuggestionRow: View {
    let suggestion: String
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isHovered || isSelected ? .primary : .secondary)
                    .scaleEffect(isHovered || isSelected ? 1.06 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isHovered || isSelected ? Color.white.opacity(0.09) : .clear)
            )
            .scaleEffect(isHovered || isSelected ? 1.012 : 1)
            .shadow(
                color: .black.opacity(isHovered || isSelected ? 0.18 : 0),
                radius: isHovered || isSelected ? 10 : 0,
                y: isHovered || isSelected ? 4 : 0
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 8)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }
}

private struct SearchLinkDetectedCard: View {
    let linkPreview: SearchViewModel.LinkPreview
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 18) {
                SearchLinkArtwork(linkPreview: linkPreview)

                VStack(alignment: .leading, spacing: 4) {
                    Text("YouTube Link Detected")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(linkPreview.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text(linkDetailLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                    Image(systemName: "arrow.right")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(isHovered ? Color.white.opacity(0.07) : Color.white.opacity(0.025))
            )
            .scaleEffect(isHovered ? 1.008 : 1)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .animation(.snappy(duration: 0.2, extraBounce: 0), value: linkPreview.thumbnailURL)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }

    private var linkDetailLine: String {
        var parts: [String] = []
        if let channel = linkPreview.channel, !channel.isEmpty {
            parts.append(channel)
        }
        if linkPreview.startTime > 0 {
            parts.append("Starts at \(formatTime(linkPreview.startTime))")
        }
        return parts.isEmpty ? "Open video" : parts.joined(separator: " • ")
    }

    private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds.rounded(.down))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainder = totalSeconds % 60

        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", remainder))"
        }
        return "\(minutes):\(String(format: "%02d", remainder))"
    }
}

private struct SearchLinkArtwork: View {
    let linkPreview: SearchViewModel.LinkPreview

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white.opacity(0.05))

            CachedAsyncImage(url: linkPreview.thumbnailURL, maxPixelSize: 720, contentMode: .fill) {
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.12, blue: 0.14),
                                Color(red: 0.07, green: 0.07, blue: 0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        if let youtubeMark = BrandAssets.youtubeMark {
                            Image(nsImage: youtubeMark)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 62, height: 44)
                        } else {
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .frame(width: 192, height: 108)
    }
}

private struct HistoryActionPanel: View {
    let isFiltering: Bool
    let onRefresh: () -> Void
    let onOpenOfficialControls: () -> Void

    var body: some View {
        HistoryPanelCard(title: "History Actions", icon: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    isFiltering
                        ? "Toolbar search is using YouTube's real history search, so older matches can still surface."
                        : "Refresh here, then use Google's official delete controls for range-based cleanup."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Divider()
                    .overlay(Color.white.opacity(0.08))

                HistoryActionButton(
                    title: "Refresh History",
                    subtitle: "Pull the newest watch activity from YouTube.",
                    systemImage: "arrow.clockwise",
                    isBusy: false,
                    action: onRefresh
                )

                HistoryActionButton(
                    title: "Open Google My Activity",
                    subtitle: "Use YouTube's official Delete today, custom range, or all time controls in the browser.",
                    systemImage: "safari",
                    isBusy: false,
                    action: onOpenOfficialControls
                )
            }
        }
    }
}

private struct HistoryPanelCard<Content: View>: View {
    @ObservedObject private var settings = AppSettings.shared
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.headline.weight(.semibold))

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(settings.cardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(settings.preferredColorScheme == .dark ? 0.06 : 0.16), lineWidth: 1)
        )
    }
}

private struct HistoryActionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isBusy: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.white.opacity(0.035))
            )
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }
}

private struct ChannelVideoRow: View {
    @ObservedObject private var settings = AppSettings.shared
    let video: VideoItem
    let onOpen: () -> Void
    let onOpenChannel: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HistoryVideoThumbnail(video: video)

            VStack(alignment: .leading, spacing: 8) {
                Text(video.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                VideoChannelIdentityLine(
                    avatarURL: video.channelAvatarURL,
                    channelID: video.channelId,
                    channel: video.channel,
                    avatarSize: 20,
                    font: .system(size: 14, weight: .medium),
                    onOpenChannel: onOpenChannel
                )

                if !video.tags.isEmpty || metadataChips.isEmpty == false {
                    VideoMetadataChipRow(tags: video.tags, items: metadataChips)
                }
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(isHovered ? settings.hoverCardBackgroundColor : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(isHovered ? (settings.preferredColorScheme == .dark ? 0.10 : 0.18) : 0), lineWidth: 1)
        )
        .shadow(color: .black.opacity(isHovered ? 0.10 : 0), radius: isHovered ? 14 : 0, y: isHovered ? 8 : 0)
        .scaleEffect(isHovered ? 1.004 : 1)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onTapGesture(perform: onOpen)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var metadataChips: [String] {
        [video.viewCountText, video.publishedTimeText]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
    }
}

private struct ChannelPlaylistRow: View {
    @ObservedObject private var settings = AppSettings.shared
    let playlist: PlaylistSummary
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ChannelPlaylistThumbnail(playlist: playlist)

            VStack(alignment: .leading, spacing: 8) {
                Text(playlist.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if metadataChips.isEmpty == false {
                    FlexibleChipRow(items: metadataChips)
                }
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(isHovered ? settings.hoverCardBackgroundColor : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(isHovered ? (settings.preferredColorScheme == .dark ? 0.10 : 0.18) : 0), lineWidth: 1)
        )
        .shadow(color: .black.opacity(isHovered ? 0.10 : 0), radius: isHovered ? 14 : 0, y: isHovered ? 8 : 0)
        .scaleEffect(isHovered ? 1.004 : 1)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onTapGesture(perform: onOpen)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var metadataChips: [String] {
        [playlist.itemCountText, playlist.privacy, playlist.updatedText]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
    }
}

private struct ChannelPlaylistThumbnail: View {
    let playlist: PlaylistSummary

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.gray.opacity(0.16))
                .overlay {
                    ZStack {
                        if playlist.referenceKind == .userPlaylist {
                            CachedAsyncImage(url: playlist.thumbnailURL, maxPixelSize: 640, contentMode: .fill) {
                                RoundedRectangle(cornerRadius: 22)
                                    .fill(Color.gray.opacity(0.22))
                                    .overlay(
                                        Image(systemName: "music.note.list")
                                            .font(.system(size: 26))
                                            .foregroundStyle(.secondary)
                                    )
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                        } else {
                            LinearGradient(
                                colors: playlist.referenceKind == .watchLater
                                    ? [Color(red: 0.20, green: 0.44, blue: 0.94), Color(red: 0.08, green: 0.16, blue: 0.36)]
                                    : [BrandAssets.youtubeLightRed, BrandAssets.youtubeDarkRed],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .overlay {
                                VStack(spacing: 10) {
                                    Image(systemName: playlist.referenceKind == .watchLater ? "clock.fill" : "hand.thumbsup.fill")
                                        .font(.system(size: 30, weight: .bold))
                                    Text(playlist.title)
                                        .font(.headline.weight(.bold))
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 14)
                                        .lineLimit(2)
                                }
                                .foregroundStyle(.white)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )

            if let count = playlist.itemCountText, !count.isEmpty {
                Text(count)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(10)
            }
        }
        .frame(width: 228, height: 128)
    }
}

private struct HistoryVideoRow: View {
    @ObservedObject private var settings = AppSettings.shared
    let video: VideoItem
    let isDeleting: Bool
    let onOpen: () -> Void
    let onOpenChannel: (() -> Void)?
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var isDeleteHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HistoryVideoThumbnail(video: video)

            VStack(alignment: .leading, spacing: 8) {
                Text(video.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                VideoChannelIdentityLine(
                    avatarURL: video.channelAvatarURL,
                    channelID: video.channelId,
                    channel: video.channel,
                    avatarSize: 20,
                    font: .system(size: 14, weight: .medium),
                    onOpenChannel: onOpenChannel
                )

                if !video.tags.isEmpty || metadataChips.isEmpty == false {
                    VideoMetadataChipRow(tags: video.tags, items: metadataChips)
                }

                if let localProgressLine {
                    Label(localProgressLine, systemImage: "sparkles.tv")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(red: 0.39, green: 0.78, blue: 1.0))
                }

                if let youtubeLine {
                    Label(youtubeLine, systemImage: "rectangle.bottomthird.inset.filled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                HStack {
                    if isHovered || isDeleting {
                        Button(action: onDelete) {
                            Group {
                                if isDeleting {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "trash")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(isDeleteHovered ? Color(red: 0.93, green: 0.13, blue: 0.13) : .secondary)
                                }
                            }
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(isDeleteHovered ? Color(red: 0.93, green: 0.13, blue: 0.13).opacity(0.14) : Color.white.opacity(0.08))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeleting)
                        .help("Delete from history")
                        .onHover { hovering in
                            withAnimation(.easeOut(duration: 0.12)) {
                                isDeleteHovered = hovering
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }

                HStack {
                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 28)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(isHovered ? settings.hoverCardBackgroundColor : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(isHovered ? (settings.preferredColorScheme == .dark ? 0.10 : 0.18) : 0), lineWidth: 1)
        )
        .shadow(color: .black.opacity(isHovered ? 0.10 : 0), radius: isHovered ? 14 : 0, y: isHovered ? 8 : 0)
        .scaleEffect(isHovered ? 1.004 : 1)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onTapGesture(perform: onOpen)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var metadataChips: [String] {
        [video.viewCountText, video.publishedTimeText]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
    }

    private var localProgressLine: String? {
        guard !video.isLive else { return nil }
        guard let progress = video.progress else { return nil }
        if progress.localCompleted {
            return "SwiftTube tracked this as watched through"
        }
        if let seconds = progress.localElapsedSeconds {
            return "SwiftTube exact resume: \(formatTime(seconds))"
        }
        return nil
    }

    private var youtubeLine: String? {
        guard !video.isLive else { return nil }
        guard let progress = video.progress,
              let fraction = progress.normalizedYouTubeFraction,
              fraction > 0 else {
            return nil
        }

        let percentage = Int((fraction * 100).rounded())
        if let youtubeSeconds = progress.youtubeResumeSeconds {
            return "YouTube remembers \(percentage)% (\(formatTime(youtubeSeconds)))"
        }
        return "YouTube remembers \(percentage)%"
    }

    private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds.rounded(.down))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainder = totalSeconds % 60

        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", remainder))"
        }
        return "\(minutes):\(String(format: "%02d", remainder))"
    }
}

private struct HistoryVideoRowPlaceholder: View {
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.white.opacity(0.08))
                .frame(width: 228, height: 128)

            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.08))
                    .frame(maxWidth: 340)
                    .frame(height: 22)
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 150, height: 16)
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 210, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.05))
                .frame(width: 26, height: 26)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .redacted(reason: .placeholder)
    }
}

private struct HistoryVideoThumbnail: View {
    let video: VideoItem

    var body: some View {
        InlineVideoThumbnail(
            video: video,
            width: 228,
            height: 128,
            cornerRadius: 22,
            maxPixelSize: 640,
            placeholderIconSize: 24
        )
        .frame(width: 228, height: 128)
    }
}

private struct FlexibleChipRow: View {
    let items: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { item in
                HistoryMetadataChip(text: item)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct VideoMetadataChipRow: View {
    let tags: [VideoTag]
    let items: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tags) { tag in
                VideoTagBadgeView(tag: tag, font: .caption)
            }

            ForEach(items, id: \.self) { item in
                HistoryMetadataChip(text: item)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HistoryMetadataChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
    }
}
