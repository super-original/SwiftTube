import AppKit
import SwiftUI

private enum SidebarSelectionValue: Hashable {
    case item(SidebarItemKind)
    case playlist(String)
}

struct ContentView: View {
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var searchViewModel = SearchViewModel()
    @StateObject private var playlistLibraryViewModel = PlaylistLibraryViewModel()
    @ObservedObject private var settings = AppSettings.shared
    @State private var isEditingSidebar = false
    @State private var isPlaylistSectionExpanded = true
    @EnvironmentObject private var backend: BackendManager
    @EnvironmentObject private var navigation: AppNavigationModel
    @EnvironmentObject private var authSession: AuthSessionModel

    private let columns = [
        GridItem(.adaptive(minimum: 240), spacing: 20, alignment: .top)
    ]
    private let searchChromeWidth: CGFloat = 300

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
                    placeholder: "Search or paste YouTube URL",
                    onSubmit: { searchViewModel.submit(navigation: navigation) },
                    onClear: { searchViewModel.clear() }
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
                playlistLibraryViewModel.reload()
            }
        }
        .task(id: authSession.contentRefreshID) {
            guard backend.isRunning else { return }
            viewModel.reload()
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
            searchViewModel.handleQueryChange()
        }
    }
}

private extension ContentView {
    @ViewBuilder
    var currentScreenContainer: some View {
        ZStack(alignment: .top) {
            currentScreen

            if shouldShowSearchAssist {
                searchAssistOverlay
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    var visibleSidebarItems: [SidebarItemKind] {
        settings.visibleSidebarItems(isAuthenticated: authSession.status.authenticated)
    }

    var userOwnedPlaylists: [PlaylistSummary] {
        playlistLibraryViewModel.playlists.filter {
            !["WL", "LL"].contains($0.playlistId)
        }
    }

    var orderedSidebarPlaylists: [PlaylistSummary] {
        settings.orderedSidebarPlaylists(userOwnedPlaylists)
    }

    var visibleSidebarPlaylists: [PlaylistSummary] {
        orderedSidebarPlaylists.filter { settings.isSidebarPlaylistVisible($0.playlistId) }
    }

    var shouldShowPlaylistSection: Bool {
        authSession.status.authenticated
            && (settings.isSidebarItemVisible(.playlists) || !visibleSidebarPlaylists.isEmpty)
    }

    var shouldShowSidebar: Bool {
        true
    }

    var shouldShowSearchAssist: Bool {
        !searchViewModel.isActive
            && (
                searchViewModel.linkPreview != nil
                || searchViewModel.isLoadingSuggestions
                || !searchViewModel.suggestions.isEmpty
            )
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

    var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isEditingSidebar.toggle()
                    }
                } label: {
                    Image(systemName: isEditingSidebar ? "checkmark" : "pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isEditingSidebar ? Color.accentColor : .secondary)
                .background(
                    Circle()
                        .fill(isEditingSidebar ? Color.accentColor.opacity(0.14) : Color.clear)
                )
                .contentShape(Circle())
                .help(isEditingSidebar ? "Done Editing Sidebar" : "Edit Sidebar")
            }

            normalSidebar
        }
        .padding(.top, 8)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
    }

    var normalSidebar: some View {
        List {
            ForEach(visibleSidebarItems.filter { $0 != .playlists }) { item in
                SidebarActionRow(
                    title: item.title,
                    icon: {
                        switch item {
                        case .watchLater:
                            PlaylistSpecialIcon(
                                symbol: "clock.fill",
                                colors: [Color(red: 0.16, green: 0.34, blue: 0.82), Color(red: 0.11, green: 0.17, blue: 0.40)]
                            )
                        case .likedVideos:
                            PlaylistSpecialIcon(
                                symbol: "hand.thumbsup.fill",
                                colors: [Color(red: 0.90, green: 0.36, blue: 0.44), Color(red: 0.43, green: 0.11, blue: 0.22)]
                            )
                        default:
                            Image(systemName: item.systemImage)
                        }
                    },
                    isSelected: sidebarSelectionValue == .item(item),
                    isEditing: isEditingSidebar,
                    isVisible: settings.isSidebarItemVisible(item),
                    isLocked: item == .home,
                    canMoveUp: canMoveSidebarItem(item, direction: -1),
                    canMoveDown: canMoveSidebarItem(item, direction: 1),
                    indent: 0,
                    action: {
                        navigation.selectSidebarItem(item)
                    },
                    onVisibilityChanged: { visible in
                        settings.setSidebarItem(item, visible: visible)
                    },
                    onMoveUp: {
                        settings.moveSidebarItem(item, direction: -1)
                    },
                    onMoveDown: {
                        settings.moveSidebarItem(item, direction: 1)
                    }
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
            }

            if shouldShowPlaylistSection {
                Section {
                    DisclosureGroup("Playlists", isExpanded: $isPlaylistSectionExpanded) {
                        if settings.isSidebarItemVisible(.playlists) {
                            SidebarActionRow(
                                title: "All Playlists",
                                icon: {
                                    Image(systemName: "square.grid.2x2")
                                },
                                isSelected: sidebarSelectionValue == .item(.playlists),
                                isEditing: isEditingSidebar,
                                isVisible: settings.isSidebarItemVisible(.playlists),
                                isLocked: false,
                                canMoveUp: false,
                                canMoveDown: false,
                                indent: 18,
                                action: {
                                    navigation.showPlaylistLibrary()
                                },
                                onVisibilityChanged: { visible in
                                    settings.setSidebarItem(.playlists, visible: visible)
                                },
                                onMoveUp: nil,
                                onMoveDown: nil
                            )
                        }

                        ForEach(visibleSidebarPlaylists) { playlist in
                            SidebarActionRow(
                                title: playlist.title,
                                icon: {
                                    PlaylistSidebarIcon(playlist: playlist)
                                },
                                isSelected: sidebarSelectionValue == .playlist(playlist.playlistId),
                                isEditing: isEditingSidebar,
                                isVisible: settings.isSidebarPlaylistVisible(playlist.playlistId),
                                isLocked: false,
                                canMoveUp: canMoveSidebarPlaylist(playlist, direction: -1),
                                canMoveDown: canMoveSidebarPlaylist(playlist, direction: 1),
                                indent: 18,
                                action: {
                                    navigation.showPlaylist(
                                        PlaylistReference(
                                            playlistId: playlist.playlistId,
                                            title: playlist.title,
                                            kind: .userPlaylist
                                        )
                                    )
                                },
                                onVisibilityChanged: { visible in
                                    settings.setSidebarPlaylist(playlist.playlistId, visible: visible)
                                },
                                onMoveUp: {
                                    settings.moveSidebarPlaylist(
                                        playlist.playlistId,
                                        direction: -1,
                                        availablePlaylists: orderedSidebarPlaylists
                                    )
                                },
                                onMoveDown: {
                                    settings.moveSidebarPlaylist(
                                        playlist.playlistId,
                                        direction: 1,
                                        availablePlaylists: orderedSidebarPlaylists
                                    )
                                }
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    var sidebarSelectionValue: SidebarSelectionValue {
        switch navigation.currentRoute {
        case .home:
            return .item(.home)
        case .playlistLibrary:
            return .item(.playlists)
        case .playlistFeed(let playlist):
            switch playlist.kind {
            case .watchLater:
                return .item(.watchLater)
            case .likedVideos:
                return .item(.likedVideos)
            case .userPlaylist:
                return .playlist(playlist.playlistId)
            }
        case .video:
            if let activePlaylist = navigation.activePlaylistReference {
                switch activePlaylist.kind {
                case .watchLater:
                    return .item(.watchLater)
                case .likedVideos:
                    return .item(.likedVideos)
                case .userPlaylist:
                    return .playlist(activePlaylist.playlistId)
                }
            }
            return .item(navigation.selectedSidebarItem)
        }
    }

    func canMoveSidebarItem(_ item: SidebarItemKind, direction: Int) -> Bool {
        guard let index = settings.sidebarItemOrder.firstIndex(of: item) else { return false }
        return settings.sidebarItemOrder.indices.contains(index + direction)
    }

    func canMoveSidebarPlaylist(_ playlist: PlaylistSummary, direction: Int) -> Bool {
        let ordered = orderedSidebarPlaylists
        guard let index = ordered.firstIndex(where: { $0.playlistId == playlist.playlistId }) else { return false }
        return ordered.indices.contains(index + direction)
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
                            onMoveToBottom: nil
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
            }
        }
    }

    @ViewBuilder
    var searchContentView: some View {
        HStack {
            Text("Results for \"\(searchViewModel.lastQuery)\"")
                .font(.title3.weight(.semibold))
            Spacer()
            Button("Clear") {
                searchViewModel.clear()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }

        if searchViewModel.results.isEmpty {
            if searchViewModel.isSearching {
                placeholderGrid
            } else if let error = searchViewModel.errorMessage {
                EmptyStateView(
                    title: "Search failed",
                    message: error,
                    actionTitle: "Try Again"
                ) {
                    searchViewModel.submit(navigation: navigation)
                }
            } else {
                EmptyStateView(
                    title: "No results",
                    message: "No videos found for \"\(searchViewModel.query)\".",
                    actionTitle: "Clear Search"
                ) {
                    searchViewModel.clear()
                }
            }
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(searchViewModel.results, id: \.id) { video in
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
                            onMoveToBottom: nil
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
            searchViewModel.submit(navigation: navigation)
            return
        }

        switch navigation.currentRoute {
        case .home:
            viewModel.reload()
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
            suggestions: searchViewModel.suggestions,
            linkPreview: searchViewModel.linkPreview,
            isLoading: searchViewModel.isLoadingSuggestions,
            onSelectSuggestion: { suggestion in
                searchViewModel.applySuggestion(suggestion)
                searchViewModel.submit(navigation: navigation)
            },
            onOpenLink: {
                searchViewModel.submit(navigation: navigation)
            }
        )
        .frame(width: searchChromeWidth)
        .shadow(color: .black.opacity(0.22), radius: 20, y: 10)
    }
}

private struct SidebarActionRow<Icon: View>: View {
    let title: String
    @ViewBuilder let icon: () -> Icon
    let isSelected: Bool
    let isEditing: Bool
    let isVisible: Bool
    let isLocked: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let indent: CGFloat
    let action: () -> Void
    let onVisibilityChanged: (Bool) -> Void
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon()
                    .frame(width: 18, height: 18)
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isEditing {
                    HStack(spacing: 6) {
                        if let onMoveUp {
                            Button(action: onMoveUp) {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.plain)
                            .disabled(!canMoveUp)
                            .foregroundStyle(canMoveUp ? Color.secondary : Color.secondary.opacity(0.35))
                        }

                        if let onMoveDown {
                            Button(action: onMoveDown) {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.plain)
                            .disabled(!canMoveDown)
                            .foregroundStyle(canMoveDown ? Color.secondary : Color.secondary.opacity(0.35))
                        }

                        Button {
                            onVisibilityChanged(!isVisible)
                        } label: {
                            Image(systemName: isVisible ? "eye" : "eye.slash")
                        }
                        .buttonStyle(.plain)
                        .disabled(isLocked)
                        .foregroundStyle(isLocked ? Color.secondary.opacity(0.35) : .secondary)
                    }
                }
            }
            .padding(.leading, indent)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.20) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor.opacity(0.25) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .opacity(isVisible || isLocked ? 1 : 0.60)
    }
}

private struct PlaylistSidebarIcon: View {
    let playlist: PlaylistSummary

    var body: some View {
        switch playlist.referenceKind {
        case .watchLater:
            PlaylistSpecialIcon(
                symbol: "clock.fill",
                colors: [Color(red: 0.16, green: 0.34, blue: 0.82), Color(red: 0.11, green: 0.17, blue: 0.40)]
            )
        case .likedVideos:
            PlaylistSpecialIcon(
                symbol: "hand.thumbsup.fill",
                colors: [Color(red: 0.90, green: 0.36, blue: 0.44), Color(red: 0.43, green: 0.11, blue: 0.22)]
            )
        case .userPlaylist:
            Image(systemName: "music.note.list")
                .foregroundStyle(.secondary)
        }
    }
}

private struct PlaylistSpecialIcon: View {
    let symbol: String
    let colors: [Color]

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 18, height: 18)
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
                content
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
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
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
                .buttonStyle(.bordered)
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

            LazyVStack(spacing: 14) {
                ForEach(viewModel.items, id: \.self) { video in
                    Button {
                        playPlaylist(startingWith: video)
                    } label: {
                        PlaylistVideoRow(
                            video: video,
                            isCurrent: isCurrent(video),
                            isMutating: viewModel.mutationIDs.contains(video.playlistSetVideoId ?? "")
                        )
                    }
                    .buttonStyle(.plain)
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
                            onMoveToBottom: video.playlistCanMoveToBottom ? { viewModel.moveItemToBottom(video) } : nil
                        )
                    }
                    .onAppear {
                        viewModel.loadMoreIfNeeded(currentVideo: video)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.items.isEmpty {
            if viewModel.isLoading {
                VStack(spacing: 12) {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .frame(height: 98)
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
            } else {
                EmptyStateView(
                    title: "This playlist is empty",
                    message: "There are no videos here yet.",
                    actionTitle: "Refresh"
                ) {
                    viewModel.reload()
                }
            }
        } else if viewModel.isLoading {
            ProgressView("Loading more...")
                .padding(.top, 8)
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
                if playlist.referenceKind == .userPlaylist {
                    CachedAsyncImage(url: playlist.thumbnailURL, maxPixelSize: 640) {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.gray.opacity(0.22))
                            .overlay(
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 26))
                                    .foregroundStyle(.secondary)
                            )
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                } else {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(
                            LinearGradient(
                                colors: playlist.referenceKind == .watchLater
                                    ? [Color(red: 0.20, green: 0.44, blue: 0.94), Color(red: 0.08, green: 0.16, blue: 0.36)]
                                    : [Color(red: 0.92, green: 0.40, blue: 0.48), Color(red: 0.38, green: 0.11, blue: 0.23)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
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
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16 / 9, contentMode: .fit)
                }

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

private struct PlaylistVideoRow: View {
    let video: VideoItem
    let isCurrent: Bool
    let isMutating: Bool

    private var metadataLine: String {
        [video.channel, video.viewCountText, video.publishedTimeText]
            .compactMap { $0 }
            .joined(separator: " • ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
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
            .frame(width: 22, alignment: .center)
            .padding(.top, 24)

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
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(isCurrent ? Color.blue.opacity(0.12) : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(isCurrent ? Color.blue.opacity(0.36) : Color.white.opacity(0.06), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 22))
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
    var placeholder: String
    var onSubmit: () -> Void
    var onClear: () -> Void

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

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if control.stringValue.isEmpty {
                    // Empty field: just deselect
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
    let suggestions: [String]
    let linkPreview: SearchViewModel.LinkPreview?
    let isLoading: Bool
    let onSelectSuggestion: (String) -> Void
    let onOpenLink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let linkPreview {
                SearchLinkDetectedCard(linkPreview: linkPreview, onOpen: onOpenLink)
                    .transition(.scale(scale: 0.98).combined(with: .opacity))
            } else if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finding suggestions...")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .padding(14)
            } else if !suggestions.isEmpty {
                ForEach(suggestions, id: \.self) { suggestion in
                    SearchSuggestionRow(
                        suggestion: suggestion,
                        onSelect: { onSelectSuggestion(suggestion) }
                    )
                }
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
        .animation(.snappy(duration: 0.18, extraBounce: 0), value: suggestions)
        .animation(.snappy(duration: 0.18, extraBounce: 0), value: linkPreview)
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
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [Color.red.opacity(0.95), Color.orange.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 68, height: 56)
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("YouTube Link Detected")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(linkPreview.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(linkDetailLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "arrow.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(isHovered ? Color.white.opacity(0.06) : .clear)
            )
            .scaleEffect(isHovered ? 1.008 : 1)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
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
