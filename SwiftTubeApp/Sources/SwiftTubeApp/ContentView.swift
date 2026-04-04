import AppKit
import SwiftUI

private enum SearchAssistState: Equatable {
    case hidden
    case loading
    case suggestions([String])
    case link(SearchViewModel.LinkPreview)

    var isVisible: Bool {
        self != .hidden
    }
}

struct ContentView: View {
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var historyViewModel = WatchHistoryViewModel()
    @StateObject private var searchViewModel = SearchViewModel()
    @StateObject private var playlistLibraryViewModel = PlaylistLibraryViewModel()
    @State private var deletingHistoryVideoIDs = Set<String>()
    @State private var isSearchFieldFocused = false
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var backend: BackendManager
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var authSession: AuthSessionModel

    private let columns = [
        GridItem(.adaptive(minimum: 240), spacing: 20, alignment: .top)
    ]
    private let searchChromeWidth: CGFloat = 300
    private let searchAssistWidth: CGFloat = 680

    var body: some View {
        ZStack(alignment: .topLeading) {
            backgroundView

            if shouldShowSidebar {
                NavigationSplitView {
                    sidebar
                } detail: {
                    currentScreenContainer
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                currentScreenContainer
            }
        }
        .overlay(backendOverlay)
        .sheet(isPresented: $authSession.isSheetPresented) {
            AuthConnectionSheet()
                .environmentObject(authSession)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    searchViewModel.clear()
                    navigation.showHome()
                } label: {
                    BrandToolbarLabel()
                }
                .buttonStyle(.plain)
            }

            ToolbarSpacer(.fixed)

            ToolbarItemGroup(placement: .navigation) {
                Button(action: navigation.goBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(!navigation.canGoBack)

                Button(action: navigation.goForward) {
                    Label("Forward", systemImage: "chevron.right")
                }
                .disabled(!navigation.canGoForward)
            }

            ToolbarItem(placement: .principal) {
                ToolbarSearchField(
                    text: $searchViewModel.query,
                    isFocused: $isSearchFieldFocused,
                    placeholder: toolbarSearchPlaceholder,
                    onSubmit: handleToolbarSubmit,
                    onClear: handleToolbarClear,
                    onFocusChange: handleSearchFieldFocusChange
                )
                .frame(width: searchChromeWidth)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    authSession.isSheetPresented = true
                } label: {
                    AuthToolbarLabel(status: authSession.status)
                }
                .disabled(!backend.isRunning)

                Button(action: refreshCurrentRoute) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!backend.isRunning)

                BackendToolbarStatus(state: backend.state)
            }
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
            guard backend.isRunning else { return }
            viewModel.reload()
            historyViewModel.reload()
            playlistLibraryViewModel.reload()
        }
        .onAppear {
            navigation.ensureValidSidebarSelection(visibleItems: visibleSidebarItems)
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
    }
}

private extension ContentView {
    @ViewBuilder
    var currentScreenContainer: some View {
        ZStack(alignment: .top) {
            currentScreen

            if searchAssistState.isVisible {
                searchAssistOverlay
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
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

    var shouldShowSidebar: Bool {
        visibleSidebarItems.count > 1
    }

    var toolbarSearchScope: SearchViewModel.Scope {
        return navigation.currentRoute == .watchHistory ? .history : .global
    }

    var toolbarSearchPlaceholder: String {
        toolbarSearchScope == .history ? "Search history" : "Search or paste YouTube URL"
    }

    var searchAssistState: SearchAssistState {
        guard isSearchFieldFocused else {
            return .hidden
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
        settings.windowBackgroundColor
            .ignoresSafeArea()
    }

    @ViewBuilder
    var currentScreen: some View {
        if searchViewModel.isActive {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    searchContentView
                }
                .padding(24)
            }
        } else {
            switch navigation.currentRoute {
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
            case .video(let video):
                PlayerScreen(
                    video: video,
                    libraryPlaylists: playlistLibraryViewModel.playlists
                )
                    .id("\(video.id)-\(navigation.routeRefreshID.uuidString)")
            }
        }
    }

    var homeScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let notice = viewModel.notice {
                    NoticeBanner(text: notice)
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

                Text("Your full YouTube watch stack, with official history search plus SwiftTube's exact resume tracking layered on top.")
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
        List(selection: Binding(
            get: { Optional(navigation.selectedSidebarItem) },
            set: { if let item = $0 { navigation.selectSidebarItem(item) } }
        )) {
            ForEach(visibleSidebarItems) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
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
                ForEach(viewModel.videos, id: \.id) { video in
                    Button {
                        navigation.showVideo(video)
                    } label: {
                        VideoCard(video: video)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contextMenu {
                        VideoContextMenuContent(
                            video: video,
                            userPlaylists: userOwnedPlaylists,
                            onPlay: { navigation.showVideo(video) },
                            onPlayFromHere: nil,
                            onAddToWatchLater: authSession.status.authenticated
                                ? runDetachedAction {
                                    _ = try await BackendClient.shared.updateWatchLater(id: video.id, saved: true)
                                }
                                : nil,
                            onSaveToPlaylist: authSession.status.authenticated ? { playlistID in
                                runDetachedAction {
                                    _ = try await BackendClient.shared.updatePlaylist(
                                        id: video.id,
                                        playlistId: playlistID,
                                        saved: true
                                    )
                                }()
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
                }
            }

            if viewModel.isLoading {
                ProgressView("Loading more...")
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity)
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

    @ViewBuilder
    var searchContentView: some View {
        Text("Results for \"\(searchViewModel.lastQuery)\"")
            .font(.title3.weight(.semibold))

        if searchViewModel.results.isEmpty {
            if searchViewModel.isSearching {
                placeholderGrid
            } else if let error = searchViewModel.errorMessage {
                EmptyStateView(
                    title: "Search failed",
                    message: error,
                    actionTitle: "Try Again"
                ) {
                    handleToolbarSubmit()
                }
            } else {
                EmptyStateView(
                    title: "No results",
                    message: "No videos found for \"\(searchViewModel.lastQuery)\".",
                    actionTitle: "Clear Search"
                ) {
                    handleToolbarClear()
                }
            }
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(searchViewModel.results, id: \.id) { video in
                    Button {
                        openVideoFromSearch(video)
                    } label: {
                        VideoCard(video: video)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contextMenu {
                        VideoContextMenuContent(
                            video: video,
                            userPlaylists: userOwnedPlaylists,
                            onPlay: { openVideoFromSearch(video) },
                            onPlayFromHere: nil,
                            onAddToWatchLater: authSession.status.authenticated
                                ? runDetachedAction {
                                    _ = try await BackendClient.shared.updateWatchLater(id: video.id, saved: true)
                                }
                                : nil,
                            onSaveToPlaylist: authSession.status.authenticated ? { playlistID in
                                runDetachedAction {
                                    _ = try await BackendClient.shared.updatePlaylist(
                                        id: video.id,
                                        playlistId: playlistID,
                                        saved: true
                                    )
                                }()
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
                        searchViewModel.loadMoreIfNeeded(currentVideo: video)
                    }
                }
            }

            if searchViewModel.isSearching {
                ProgressView("Loading more...")
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity)
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
        case .home:
            viewModel.reload()
        case .watchHistory:
            historyViewModel.reload()
        case .playlistLibrary:
            playlistLibraryViewModel.reload()
        case .playlistFeed:
            navigation.refreshCurrentRoute()
        case .video:
            navigation.refreshCurrentRoute()
        }
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
                    ProgressView()
                    Text(backend.statusMessage)
                        .font(.headline)
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

    func runDetachedAction(_ operation: @escaping @Sendable () async throws -> Void) -> (() -> Void) {
        {
            Task {
                do {
                    try await operation()
                } catch {
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = "Action Failed"
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .warning
                        alert.runModal()
                    }
                }
            }
        }
    }

    var searchAssistOverlay: some View {
        SearchAssistPanel(
            state: searchAssistState,
            onSelectSuggestion: { suggestion in
                searchViewModel.applySuggestion(suggestion)
                handleToolbarSubmit()
            },
            onOpenLink: handleToolbarSubmit
        )
        .frame(width: searchAssistPanelWidth)
        .shadow(color: .black.opacity(0.22), radius: 20, y: 10)
    }

    @ViewBuilder
    var historyVideoStack: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(historyViewModel.hasActiveFilter ? "History Search Results" : "Recently Watched")
                        .font(.title2.weight(.bold))

                    Text(historySummaryLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if historyViewModel.filteredItems.isEmpty {
                if historyViewModel.isLoading && historyViewModel.items.isEmpty {
                    LazyVStack(spacing: 14) {
                        ForEach(0..<6, id: \.self) { _ in
                            PlaylistFeedPlaceholderRow()
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
                    ForEach(historyViewModel.filteredItems, id: \.id) { video in
                        HistoryVideoRow(
                            video: video,
                            isDeleting: deletingHistoryVideoIDs.contains(video.id),
                            onOpen: { navigation.showVideo(video) },
                            onDelete: { removeVideoFromHistory(video) }
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            VideoContextMenuContent(
                                video: video,
                                userPlaylists: userOwnedPlaylists,
                                onPlay: { navigation.showVideo(video) },
                                onPlayFromHere: nil,
                                onAddToWatchLater: authSession.status.authenticated
                                    ? runDetachedAction {
                                        _ = try await BackendClient.shared.updateWatchLater(id: video.id, saved: true)
                                    }
                                    : nil,
                                onSaveToPlaylist: authSession.status.authenticated ? { playlistID in
                                    runDetachedAction {
                                        _ = try await BackendClient.shared.updatePlaylist(
                                            id: video.id,
                                            playlistId: playlistID,
                                            saved: true
                                        )
                                    }()
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
                    }
                }

                if historyViewModel.isLoading {
                    ProgressView("Loading more history...")
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity)
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

    var searchAssistPanelWidth: CGFloat {
        switch searchAssistState {
        case .link:
            return searchAssistWidth
        case .loading, .suggestions:
            return searchChromeWidth
        case .hidden:
            return searchChromeWidth
        }
    }

    func handleToolbarSubmit() {
        isSearchFieldFocused = false
        let outcome = searchViewModel.submit(navigation: navigation, scope: toolbarSearchScope)
        searchViewModel.dismissAssist()
        if outcome == .openedVideoLink {
            searchViewModel.dismissResults()
        }
    }

    func handleToolbarClear() {
        searchViewModel.clearToolbarInput()
        syncHistorySearchQuery()
    }

    func handleToolbarQueryChange() {
        searchViewModel.handleQueryChange(scope: toolbarSearchScope)
        syncHistorySearchQuery()
    }

    func handleSearchFieldFocusChange(_ focused: Bool) {
        isSearchFieldFocused = focused
        if !focused {
            searchViewModel.dismissAssist()
        }
    }

    func openVideoFromSearch(_ video: VideoItem) {
        isSearchFieldFocused = false
        searchViewModel.dismissAssist()
        searchViewModel.dismissResults()
        navigation.showVideo(video)
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
        guard deletingHistoryVideoIDs.contains(video.id) == false else { return }
        deletingHistoryVideoIDs.insert(video.id)

        Task {
            defer {
                Task { @MainActor in
                    deletingHistoryVideoIDs.remove(video.id)
                }
            }

            do {
                let response = try await BackendClient.shared.removeWatchHistoryVideo(id: video.id)
                await MainActor.run {
                    historyViewModel.removeItemsLocally(ids: response.removedVideoIDs)
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t remove video"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    func openOfficialHistoryControls() {
        guard let url = URL(string: "https://myactivity.google.com/product/youtube?hl=en&utm_medium=web&utm_source=youtube") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct PlaylistLibraryScreen: View {
    @ObservedObject var viewModel: PlaylistLibraryViewModel
    @EnvironmentObject private var navigation: AppNavigationModel

    private let columns = [
        GridItem(.adaptive(minimum: 240), spacing: 20, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Playlists")
                    .font(.largeTitle.weight(.bold))

                content
            }
            .padding(24)
        }
        .task {
            viewModel.loadInitial()
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.playlists.isEmpty {
            if viewModel.isLoading {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(0..<6, id: \.self) { _ in
                        PlaceholderCard()
                    }
                }
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
                    message: "Your YouTube playlist library is empty.",
                    actionTitle: "Refresh"
                ) {
                    viewModel.reload()
                }
            }
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(viewModel.playlists) { playlist in
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
                        viewModel.loadMoreIfNeeded(currentPlaylist: playlist)
                    }
                }
            }

            if viewModel.isLoading {
                ProgressView("Loading more...")
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct PlaylistFeedScreen: View {
    @StateObject private var viewModel: PlaylistFeedViewModel
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
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .bottomTrailing) {
                if viewModel.playlist.kind == .userPlaylist {
                    CachedAsyncImage(url: viewModel.items.first?.thumbnailURL, maxPixelSize: 720) {
                        RoundedRectangle(cornerRadius: 28)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.24, green: 0.40, blue: 0.54),
                                        Color(red: 0.06, green: 0.13, blue: 0.20)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 42, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.86))
                            )
                    }
                    .frame(width: 312, height: 312)
                    .clipShape(RoundedRectangle(cornerRadius: 28))
                } else {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(
                            LinearGradient(
                                colors: viewModel.playlist.kind == .watchLater
                                    ? [Color(red: 0.20, green: 0.44, blue: 0.94), Color(red: 0.08, green: 0.16, blue: 0.36)]
                                    : [Color(red: 0.92, green: 0.40, blue: 0.48), Color(red: 0.38, green: 0.11, blue: 0.23)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            VStack(spacing: 14) {
                                Image(systemName: viewModel.playlist.kind == .watchLater ? "clock.fill" : "hand.thumbsup.fill")
                                    .font(.system(size: 50, weight: .bold))
                                Text(viewModel.playlist.title)
                                    .font(.system(size: 28, weight: .bold))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 28)
                            }
                            .foregroundStyle(.white)
                        }
                        .frame(width: 312, height: 312)
                }

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
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.items.enumerated()), id: \.element) { index, video in
                        PlaylistReorderDropZone {
                            viewModel.reorderItem(withID: $0, toInsertionIndex: index)
                        }

                        PlaylistFeedDraggableRow(
                            video: video,
                            isCurrent: isCurrent(video),
                            isMutating: viewModel.mutationIDs.contains(video.playlistSetVideoId ?? ""),
                            onPlay: { playPlaylist(startingWith: video) }
                        )
                        .contextMenu {
                            VideoContextMenuContent(
                                video: video,
                                userPlaylists: movableLibraryPlaylists(excluding: viewModel.playlist.playlistId),
                                onPlay: { playPlaylist(startingWith: video) },
                                onPlayFromHere: { playPlaylist(startingWith: video) },
                                onAddToWatchLater: viewModel.playlist.kind == .watchLater ? nil : {
                                    _ = Task<Void, Never> {
                                        do {
                                            _ = try await BackendClient.shared.updateWatchLater(id: video.id, saved: true)
                                        } catch {
                                            viewModel.errorMessage = error.localizedDescription
                                        }
                                    }
                                },
                                onSaveToPlaylist: { playlistID in
                                    _ = Task<Void, Never> {
                                        do {
                                            _ = try await BackendClient.shared.updatePlaylist(
                                                id: video.id,
                                                playlistId: playlistID,
                                                saved: true
                                            )
                                        } catch {
                                            viewModel.errorMessage = error.localizedDescription
                                        }
                                    }
                                },
                                onMoveToPlaylist: video.playlistCanRemove ? { playlistID in
                                    _ = Task<Void, Never> {
                                        do {
                                            _ = try await BackendClient.shared.updatePlaylist(
                                                id: video.id,
                                                playlistId: playlistID,
                                                saved: true
                                            )
                                            viewModel.removeItem(video)
                                        } catch {
                                            viewModel.errorMessage = error.localizedDescription
                                        }
                                    }
                                } : nil,
                                onMoveToWatchLater: viewModel.playlist.kind == .watchLater || !video.playlistCanRemove ? nil : {
                                    _ = Task<Void, Never> {
                                        do {
                                            _ = try await BackendClient.shared.updateWatchLater(id: video.id, saved: true)
                                            viewModel.removeItem(video)
                                        } catch {
                                            viewModel.errorMessage = error.localizedDescription
                                        }
                                    }
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
                        .padding(.bottom, 14)
                    }

                    PlaylistReorderDropZone {
                        viewModel.reorderItem(withID: $0, toInsertionIndex: viewModel.items.count)
                    }

                    if viewModel.isLoading {
                        ProgressView("Loading more...")
                            .padding(.top, 8)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
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
    let playlist: PlaylistSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.gray.opacity(0.16))
                    .overlay {
                        ZStack {
                            if playlist.referenceKind == .userPlaylist {
                                CachedAsyncImage(url: playlist.thumbnailURL, maxPixelSize: 640, contentMode: .fill) {
                                    RoundedRectangle(cornerRadius: 18)
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
                                        : [Color(red: 0.92, green: 0.40, blue: 0.48), Color(red: 0.38, green: 0.11, blue: 0.23)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .overlay {
                                    VStack(spacing: 10) {
                                        Image(systemName: playlist.referenceKind == .watchLater ? "clock.fill" : "hand.thumbsup.fill")
                                            .font(.system(size: 34, weight: .bold))
                                        Text(playlist.title)
                                            .font(.headline.weight(.bold))
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 18)
                                    }
                                    .foregroundStyle(.white)
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)

                if let count = playlist.itemCountText, !count.isEmpty {
                    Text(count)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(12)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(playlist.title)
                    .font(.headline)
                    .lineLimit(2)

                let metadata = [playlist.privacy, playlist.updatedText]
                    .compactMap { $0 }
                    .joined(separator: " • ")

                if !metadata.isEmpty {
                    Text(metadata)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlaylistFeedPlaceholderRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 11)
                .fill(Color.white.opacity(0.08))
                .frame(width: 22, height: 22)
                .padding(.top, 22)

            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.08))
                .frame(width: 232, height: 130.5)

            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.08))
                    .frame(maxWidth: 320)
                    .frame(height: 22)
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.06))
                    .frame(maxWidth: 240)
                    .frame(height: 15)
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 86, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(NSColor.controlBackgroundColor))
        )
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
    let isCurrent: Bool
    let isMutating: Bool
    var showLeadingAccessory: Bool = true
    var showsBackground: Bool = true

    private var metadataLine: String {
        [video.channel, video.viewCountText, video.publishedTimeText]
            .compactMap { $0 }
            .joined(separator: " • ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if showLeadingAccessory {
                Group {
                    if video.playlistCanMoveToTop || video.playlistCanMoveToBottom {
                        Image(systemName: "line.3.horizontal")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else if let indexText = video.playlistIndexText {
                        Text(indexText)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 22, height: 130.5, alignment: .center)
            }

            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: video.thumbnailURL, maxPixelSize: 640) {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.gray.opacity(0.18))
                        .overlay(
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.secondary)
                        )
                }
                .frame(width: 232, height: 130.5)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(alignment: .bottom) {
                    VideoThumbnailProgressBars(progress: video.progress, cornerRadius: 18)
                }

                if let duration = video.durationText {
                    Text(duration)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.74)))
                        .foregroundStyle(.white)
                        .padding(10)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(video.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)

                if !metadataLine.isEmpty {
                    Text(metadataLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    if isCurrent {
                        Label("Now Playing", systemImage: "play.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.blue)
                    } else if let indexText = video.playlistIndexText {
                        Text("Video \(indexText)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    if isMutating {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(backgroundShape.fill(showsBackground ? (isCurrent ? Color.blue.opacity(0.12) : Color(NSColor.controlBackgroundColor)) : .clear))
        .overlay(backgroundShape.stroke(showsBackground ? (isCurrent ? Color.blue.opacity(0.36) : Color.white.opacity(0.06)) : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 22))
    }

    private var backgroundShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22)
    }
}

private struct PlaylistFeedDraggableRow: View {
    let video: VideoItem
    let isCurrent: Bool
    let isMutating: Bool
    let onPlay: () -> Void

    @State private var isHovered = false

    private var canReorder: Bool {
        video.playlistSetVideoId != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PlaylistRowHandle(
                isHovered: isHovered,
                canReorder: canReorder,
                fallbackText: video.playlistIndexText,
                isCurrent: isCurrent,
                fullHeight: 130.5
            )
            .draggable(video.id)

            Button(action: onPlay) {
                PlaylistVideoRow(
                    video: video,
                    isCurrent: isCurrent,
                    isMutating: isMutating,
                    showLeadingAccessory: false,
                    showsBackground: false
                )
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(isCurrent ? Color.blue.opacity(0.12) : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(isCurrent ? Color.blue.opacity(0.36) : Color.white.opacity(0.06), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onHover { hovering in
            isHovered = hovering
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
        .frame(width: 22, height: fullHeight, alignment: .center)
        .contentShape(Rectangle())
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

private struct BrandToolbarLabel: View {
    var body: some View {
        HStack(spacing: 8) {
            if let logo = BrandAssets.logo {
                Image(nsImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 20)
            }

            Text("SwiftTube")
                .font(.headline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundStyle(.primary)
        .contentShape(Capsule())
    }
}

private struct BackendToolbarStatus: View {
    let state: BackendState

    private var label: String {
        switch state {
        case .running:
            return "Online"
        case .failed:
            return "Error"
        case .installing:
            return "Installing"
        case .starting:
            return "Starting"
        case .preparing:
            return "Preparing"
        case .idle:
            return "Idle"
        }
    }

    private var color: Color {
        switch state {
        case .running:
            return Color.green
        case .failed:
            return Color.red
        default:
            return Color.orange
        }
    }

    var body: some View {
        Label(label, systemImage: "circle.fill")
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(color, .secondary)
    }
}

private struct AuthToolbarLabel: View {
    let status: AuthStatusResponse

    var body: some View {
        Label {
            Text(status.authenticated ? (status.browserLabel ?? "YouTube") : "Connect YouTube")
        } icon: {
            Image(systemName: status.authenticated ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus")
        }
        .font(.caption)
    }
}

private struct AuthConnectionSheet: View {
    @EnvironmentObject private var authSession: AuthSessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect Your YouTube Session")
                    .font(.title2.weight(.bold))
                Text("SwiftTube uses the browser session you already have on this Mac. Your Google password never goes through the app.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(BrowserLoginOption.allCases) { browser in
                    Button {
                        Task {
                            let connected = await authSession.connect(using: browser)
                            if connected {
                                dismiss()
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(browser.title)
                                .font(.headline)
                            Text(browser.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(authSession.isWorking)
                }
            }

            if authSession.isWorking {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting your YouTube session...")
                        .foregroundStyle(.secondary)
                }
            }

            if authSession.status.authenticated {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Connected via \(authSession.status.browserLabel ?? "your browser")", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let message = authSession.status.message {
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(NSColor.controlBackgroundColor))
                )

                Button("Disconnect") {
                    Task {
                        await authSession.disconnect()
                    }
                }
                .disabled(authSession.isWorking)
            }

            if let errorMessage = authSession.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            Text("If the import fails, make sure you are signed into YouTube in that browser and then try again.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 480)
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle")
                .foregroundColor(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

private struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    var onSubmit: () -> Void
    var onClear: () -> Void
    var onFocusChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = ResignableSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.focusRingType = .default
        field.bezelStyle = .roundedBezel
        field.controlSize = .regular
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        field.usesSingleLineMode = true
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
        let isActuallyFocused = nsView.currentEditor() != nil
        if isFocused == false, isActuallyFocused {
            nsView.window?.makeFirstResponder(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// NSSearchField subclass that resigns first responder when
    /// clicking outside, matching native macOS search bar behaviour.
    final class ResignableSearchField: NSSearchField {
        private nonisolated(unsafe) var clickMonitor: Any?

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result { installClickOutsideMonitor() }
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            removeClickOutsideMonitor()
            return result
        }

        private func installClickOutsideMonitor() {
            guard clickMonitor == nil else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let fieldEditor = self.currentEditor() else { return event }
                let locationInField = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(locationInField) {
                    // Also check the field editor (which might be slightly different)
                    let locationInEditor = fieldEditor.convert(event.locationInWindow, from: nil)
                    if !fieldEditor.bounds.contains(locationInEditor) {
                        self.window?.makeFirstResponder(nil)
                    }
                }
                return event
            }
        }

        private func removeClickOutsideMonitor() {
            if let monitor = clickMonitor {
                NSEvent.removeMonitor(monitor)
                clickMonitor = nil
            }
        }

        deinit {
            if let monitor = clickMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ToolbarSearchField

        init(_ parent: ToolbarSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
            if field.stringValue.isEmpty {
                parent.onClear()
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
            parent.onFocusChange(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
            parent.onFocusChange(false)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                parent.isFocused = false
                parent.onFocusChange(false)
                control.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if control.stringValue.isEmpty {
                    // Empty field: just deselect
                    parent.isFocused = false
                    parent.onFocusChange(false)
                    control.window?.makeFirstResponder(nil)
                } else {
                    // Has text: clear it and the search results
                    parent.text = ""
                    (control as? NSSearchField)?.stringValue = ""
                    parent.onClear()
                }
                return true
            }
            return false
        }
    }
}

private struct PlaceholderCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.2))
                .aspectRatio(16 / 9, contentMode: .fit)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.25))
                .frame(height: 16)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.18))
                .frame(height: 12)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.18))
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
    @ObservedObject private var settings = AppSettings.shared
    let state: SearchAssistState
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
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finding suggestions...")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .padding(14)
                .transition(.move(edge: .top).combined(with: .opacity))
            case .suggestions(let suggestions):
                ForEach(suggestions, id: \.self) { suggestion in
                    SearchSuggestionRow(
                        suggestion: suggestion,
                        onSelect: { onSelectSuggestion(suggestion) }
                    )
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(settings.cardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(settings.preferredColorScheme == .dark ? 0.06 : 0.18), lineWidth: 1)
        )
        .animation(.snappy(duration: 0.2, extraBounce: 0), value: state)
    }
}

private struct SearchSuggestionRow: View {
    let suggestion: String
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .scaleEffect(isHovered ? 1.06 : 1)
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
                    .fill(isHovered ? Color.white.opacity(0.08) : .clear)
            )
            .offset(x: isHovered ? 3 : 0)
            .scaleEffect(isHovered ? 1.008 : 1)
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

private struct HistoryVideoRow: View {
    @ObservedObject private var settings = AppSettings.shared
    let video: VideoItem
    let isDeleting: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

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
                    font: .system(size: 14, weight: .medium)
                )

                if metadataChips.isEmpty == false {
                    FlexibleChipRow(items: metadataChips)
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
                                }
                            }
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.08))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeleting)
                        .help("Delete from history")
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
        [video.viewCountText, video.publishedTimeText, video.durationText]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
    }

    private var localProgressLine: String? {
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

private struct HistoryVideoThumbnail: View {
    let video: VideoItem

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            CachedAsyncImage(url: video.thumbnailURL, maxPixelSize: 640) {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color.gray.opacity(0.18))
                    .overlay(
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                    )
            }
            .frame(width: 228, height: 128)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(alignment: .bottom) {
                VideoThumbnailProgressBars(progress: video.progress, cornerRadius: 22)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )

            if let duration = video.durationText {
                Text(duration)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.74)))
                    .foregroundStyle(.white)
                    .padding(10)
            }
        }
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
