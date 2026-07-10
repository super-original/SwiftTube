import SwiftUI

private enum SearchResultLayout: String {
    case grid
    case list
}

struct SearchScreen: View {
    @ObservedObject var viewModel: SearchViewModel
    @Binding var isSearchFocused: Bool
    let onOpenVideo: (VideoItem) -> Void
    let onOpenChannel: (ChannelReference) -> Void
    let onOpenPlaylist: (PlaylistSummary) -> Void
    let onRetry: () -> Void
    let onSubmit: () -> Void
    let onClear: () -> Void
    let onFocusChange: (Bool) -> Void
    let onMoveSuggestion: (Int) -> Bool
    let onAcceptAssist: () -> Bool

    @AppStorage("searchResultLayout") private var layoutRawValue = SearchResultLayout.grid.rawValue
    @ObservedObject private var settings = AppSettings.shared

    private var layout: SearchResultLayout {
        SearchResultLayout(rawValue: layoutRawValue) ?? .grid
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !viewModel.lastQuery.isEmpty {
                        resultsHeader
                    }

                    if !viewModel.filterGroups.isEmpty {
                        SearchFilterBar(
                            groups: viewModel.filterGroups,
                            layout: layout,
                            onSelect: viewModel.applyFilter,
                            onClear: viewModel.clearFilters,
                            onChangeLayout: { layoutRawValue = $0.rawValue }
                        )
                    }

                    results

                    if viewModel.isSearching, viewModel.hasResults {
                        LoadingMoreIndicator(text: "Loading more videos...")
                            .padding(.vertical, 14)
                    }

                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            guard viewModel.hasResults else { return }
                            viewModel.loadMoreResults()
                        }
                }
                .padding(.horizontal, 24)
                .padding(.top, 92)
                .padding(.bottom, 24)
            }
            .scrollEdgeEffectHidden(true, for: .top)

            searchHeader
                .zIndex(1)
        }
        .onAppear {
            if viewModel.lastQuery.isEmpty {
                isSearchFocused = true
            }
        }
    }

    private var searchHeader: some View {
        SearchPageField(
                text: $viewModel.query,
                isFocused: $isSearchFocused,
                placeholder: "Search or paste YouTube URL",
                onSubmit: onSubmit,
                onClear: onClear,
                onFocusChange: onFocusChange,
                onMoveSuggestion: onMoveSuggestion,
                onAcceptAssist: onAcceptAssist
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.clear)
    }

    private var resultsHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Results for “\(viewModel.lastQuery)”")
                .font(.title2.weight(.bold))

            Text(resultSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var resultSummary: String {
        let counts = [
            viewModel.results.isEmpty ? nil : "\(viewModel.results.count) videos",
            viewModel.channels.isEmpty ? nil : "\(viewModel.channels.count) channels",
            viewModel.playlists.isEmpty ? nil : "\(viewModel.playlists.count) playlists"
        ].compactMap { $0 }
        return counts.isEmpty ? "YouTube search" : counts.joined(separator: " · ")
    }

    @ViewBuilder
    private var results: some View {
        if viewModel.lastQuery.isEmpty {
            SearchPrompt(onFocusSearch: { isSearchFocused = true })
        } else if !viewModel.hasResults {
            if viewModel.isSearching {
                SearchResultPlaceholders(layout: layout)
            } else if let error = viewModel.errorMessage {
                SearchEmptyState(
                    symbol: "exclamationmark.magnifyingglass",
                    title: "Search failed",
                    message: error,
                    actionTitle: "Try Again",
                    action: onRetry
                )
            } else {
                SearchEmptyState(
                    symbol: "magnifyingglass",
                    title: "No results",
                    message: "Try another phrase or clear a filter.",
                    actionTitle: "Clear Filters",
                    action: viewModel.clearFilters
                )
            }
        } else {
            if !viewModel.channels.isEmpty {
                SearchResultSection(title: "Channels") {
                    searchChannels
                }
            }

            if !viewModel.playlists.isEmpty {
                SearchResultSection(title: "Playlists") {
                    searchPlaylists
                }
            }

            if !viewModel.results.isEmpty {
                SearchResultSection(title: "Videos") {
                    searchVideos
                }
            }
        }
    }

    @ViewBuilder
    private var searchVideos: some View {
        if layout == .grid {
            LazyVGrid(
                columns: browseGridColumns(count: settings.browseVideoGridPreset.columnCount),
                alignment: .leading,
                spacing: 20
            ) {
                ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, video in
                    VideoCard(
                        video: video,
                        onOpenChannel: video.channelReference.map { channel in
                            { onOpenChannel(channel) }
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                    .onTapGesture { onOpenVideo(video) }
                    .staggeredFadeIn(
                        id: video.id,
                        index: index,
                        columns: settings.browseVideoGridPreset.columnCount
                    )
                }
            }
        } else {
            LazyVStack(spacing: 6) {
                ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, video in
                    SearchVideoListItem(video: video, onOpen: { onOpenVideo(video) })
                        .staggeredFadeIn(id: video.id, index: index, columns: 1)
                }
            }
        }
    }

    @ViewBuilder
    private var searchChannels: some View {
        if layout == .grid {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(Array(viewModel.channels.enumerated()), id: \.element.id) { index, channel in
                    SearchChannelItemView(channel: channel, compact: false) {
                        onOpenChannel(channel.reference)
                    }
                    .staggeredFadeIn(id: channel.id, index: index, columns: 4)
                }
            }
        } else {
            LazyVStack(spacing: 6) {
                ForEach(Array(viewModel.channels.enumerated()), id: \.element.id) { index, channel in
                    SearchChannelItemView(channel: channel, compact: true) {
                        onOpenChannel(channel.reference)
                    }
                    .staggeredFadeIn(id: channel.id, index: index, columns: 1)
                }
            }
        }
    }

    @ViewBuilder
    private var searchPlaylists: some View {
        if layout == .grid {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16, alignment: .top)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(Array(viewModel.playlists.enumerated()), id: \.element.id) { index, playlist in
                    SearchPlaylistItemView(playlist: playlist, compact: false) {
                        onOpenPlaylist(playlist)
                    }
                    .staggeredFadeIn(id: playlist.id, index: index, columns: 5)
                }
            }
        } else {
            LazyVStack(spacing: 6) {
                ForEach(Array(viewModel.playlists.enumerated()), id: \.element.id) { index, playlist in
                    SearchPlaylistItemView(playlist: playlist, compact: true) {
                        onOpenPlaylist(playlist)
                    }
                    .staggeredFadeIn(id: playlist.id, index: index, columns: 1)
                }
            }
        }
    }
}

private struct SearchPageField: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let onSubmit: () -> Void
    let onClear: () -> Void
    let onFocusChange: (Bool) -> Void
    let onMoveSuggestion: (Int) -> Bool
    let onAcceptAssist: () -> Bool

    @FocusState private var fieldIsFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($fieldIsFocused)
                .onSubmit {
                    if !onAcceptAssist() {
                        onSubmit()
                    }
                }
                .onKeyPress(.downArrow) {
                    onMoveSuggestion(1) ? .handled : .ignored
                }
                .onKeyPress(.upArrow) {
                    onMoveSuggestion(-1) ? .handled : .ignored
                }
                .onKeyPress(.escape) {
                    if text.isEmpty {
                        fieldIsFocused = false
                    } else {
                        text = ""
                        onClear()
                    }
                    return .handled
                }

            if !text.isEmpty {
                Button {
                    text = ""
                    onClear()
                    fieldIsFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .glassEffect(.regular.interactive(), in: Capsule())
        .contentShape(Capsule())
        .onAppear {
            fieldIsFocused = isFocused
        }
        .onChange(of: isFocused) { _, shouldFocus in
            if fieldIsFocused != shouldFocus {
                fieldIsFocused = shouldFocus
            }
        }
        .onChange(of: fieldIsFocused) { _, focused in
            if isFocused != focused {
                isFocused = focused
            }
            onFocusChange(focused)
        }
    }
}

private struct SearchFilterBar: View {
    let groups: [SearchFilterGroup]
    let layout: SearchResultLayout
    let onSelect: (SearchFilterOption) -> Void
    let onClear: () -> Void
    let onChangeLayout: (SearchResultLayout) -> Void

    private var hasSelectedFilter: Bool {
        groups.contains { $0.options.contains(where: \.selected) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                HStack(spacing: 10) {
                    ForEach(groups) { group in
                        Menu {
                            ForEach(group.options) { option in
                                Button {
                                    onSelect(option)
                                } label: {
                                    if option.selected {
                                        Label(option.title, systemImage: "checkmark")
                                    } else {
                                        Text(option.title)
                                    }
                                }
                                .disabled(option.selected || option.params == nil)
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Text(group.options.first(where: \.selected)?.title ?? group.title)
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.bold))
                            }
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .buttonStyle(
                            ChannelToolbarPillButtonStyle(
                                isSelected: group.options.contains(where: \.selected)
                            )
                        )
                    }

                    if hasSelectedFilter {
                        Button {
                            onClear()
                        } label: {
                            Label("Clear", systemImage: "xmark")
                        }
                        .buttonStyle(ChannelToolbarPillButtonStyle(isSelected: false))
                    }
                }

                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1, height: 30)

                HStack(spacing: 10) {
                    SearchLayoutModeButton(
                        layout: .grid,
                        currentLayout: layout,
                        onSelect: onChangeLayout
                    )
                    SearchLayoutModeButton(
                        layout: .list,
                        currentLayout: layout,
                        onSelect: onChangeLayout
                    )
                }
            }
        }
    }
}

private struct SearchLayoutModeButton: View {
    let layout: SearchResultLayout
    let currentLayout: SearchResultLayout
    let onSelect: (SearchResultLayout) -> Void

    var body: some View {
        ChannelToolbarIconButton(
            symbolName: layout == .grid ? "square.grid.2x2" : "list.bullet",
            isSelected: layout == currentLayout,
            accessibilityLabel: layout == .grid ? "Grid View" : "List View",
            action: { onSelect(layout) }
        )
    }
}

private struct SearchResultSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            content
        }
    }
}

private struct SearchVideoListItem: View {
    @ObservedObject private var settings = AppSettings.shared
    let video: VideoItem
    let onOpen: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                InlineVideoThumbnail(
                    video: video,
                    width: 184,
                    height: 104,
                    cornerRadius: 10,
                    maxPixelSize: 480,
                    placeholderIconSize: 24
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(video.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(video.channel ?? "YouTube")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text([video.viewCountText, video.publishedTimeText].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isHovered ? settings.hoverCardBackgroundColor : .clear)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.004 : 1)
        .onHover { hovering in
            withAnimation(settings.hoverAnimationsEnabled ? .easeOut(duration: 0.12) : nil) {
                isHovered = hovering
            }
        }
    }
}

private struct SearchChannelItemView: View {
    let channel: SearchChannelItem
    let compact: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                CachedAsyncImage(url: channel.avatarURL, maxPixelSize: 192) {
                    Circle()
                        .fill(.quaternary)
                        .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
                }
                .frame(width: compact ? 52 : 64, height: compact ? 52 : 64)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text([channel.handle, channel.subscriberCountText].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !compact, let description = channel.descriptionText {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

private struct SearchPlaylistItemView: View {
    let playlist: PlaylistSummary
    let compact: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            if compact {
                HStack(spacing: 14) {
                    artwork
                        .frame(width: 132, height: playlist.hasSquareArtwork ? 132 : 74)
                    details
                }
                .padding(8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    artwork
                        .aspectRatio(CGFloat(playlist.artworkAspectRatio), contentMode: .fit)
                    details
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var artwork: some View {
        CachedAsyncImage(url: playlist.thumbnailURL, maxPixelSize: 640) {
            ThumbnailPlaceholder(systemImage: "music.note.list", iconSize: 24, cornerRadius: 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(playlist.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text([playlist.itemCountText, playlist.updatedText, playlist.privacy].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SearchPrompt: View {
    let onFocusSearch: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Search for something to watch", systemImage: "magnifyingglass")
        } description: {
            Text("Find videos, channels, and playlists")
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocusSearch)
        .frame(maxWidth: .infinity, minHeight: 360)
    }
}

private struct SearchEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            Button(actionTitle, action: action)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

private struct SearchResultPlaceholders: View {
    let layout: SearchResultLayout

    var body: some View {
        if layout == .grid {
            LazyVGrid(columns: browseGridColumns(count: AppSettings.shared.browseVideoGridPreset.columnCount), spacing: 20) {
                ForEach(0..<8, id: \.self) { _ in
                    PlaceholderCard()
                }
            }
        } else {
            VStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { _ in
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 10).fill(.quaternary).frame(width: 184, height: 104)
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(height: 14)
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 180, height: 11)
                        }
                    }
                }
            }
        }
    }
}
