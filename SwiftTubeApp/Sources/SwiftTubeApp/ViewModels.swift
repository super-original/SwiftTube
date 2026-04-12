import Foundation

private let paginationDuplicateHopLimit = 3

private func appendUniqueItems<Item, ID: Hashable>(
    existing: [Item],
    incoming: [Item],
    id: KeyPath<Item, ID>
) -> (items: [Item], appendedCount: Int) {
    var seen = Set(existing.map { $0[keyPath: id] })
    var merged = existing
    var appendedCount = 0

    for item in incoming {
        let itemID = item[keyPath: id]
        if seen.insert(itemID).inserted {
            merged.append(item)
            appendedCount += 1
        }
    }

    return (merged, appendedCount)
}

private func deduplicatedItems<Item, ID: Hashable>(
    _ items: [Item],
    id: KeyPath<Item, ID>
) -> [Item] {
    appendUniqueItems(existing: [], incoming: items, id: id).items
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var videos: [VideoItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var notice: String? = nil

    private var continuation: String? = nil
    private var hasLoadedInitial = false

    func loadInitial() {
        guard !hasLoadedInitial else { return }
        hasLoadedInitial = true
        Task { await fetchRecommendations(reset: true) }
    }

    func reload() {
        hasLoadedInitial = false
        loadInitial()
    }

    func loadMoreIfNeeded(currentVideo: VideoItem) {
        guard let last = videos.last, last == currentVideo else { return }
        guard !isLoading, continuation != nil else { return }
        Task { await fetchRecommendations(reset: false) }
    }

    func applyLocalProgress(_ progress: VideoProgress, to videoID: String) {
        videos = videos.map { item in
            guard item.id == videoID else { return item }
            var updated = item
            updated.progress = (item.progress ?? progress).mergingLocal(progress)
            return updated
        }
    }

    private func fetchRecommendations(reset: Bool) async {
        isLoading = true
        defer { isLoading = false }

        if reset {
            continuation = nil
            videos = []
            notice = nil
        }

        do {
            var mergedVideos = reset ? [] : videos
            var nextContinuation = continuation
            var remainingDuplicatePages = paginationDuplicateHopLimit
            var latestNote = notice

            while true {
                let response = try await BackendClient.shared.fetchRecommendations(continuation: nextContinuation)
                let mergeResult = appendUniqueItems(existing: mergedVideos, incoming: response.items, id: \.id)
                mergedVideos = mergeResult.items
                latestNote = response.note

                let shouldAdvance = mergeResult.appendedCount == 0
                    && response.continuation != nil
                    && response.continuation != nextContinuation
                    && remainingDuplicatePages > 0
                if !shouldAdvance {
                    continuation = response.continuation
                    videos = mergedVideos
                    notice = latestNote
                    break
                }

                nextContinuation = response.continuation
                remainingDuplicatePages -= 1
            }

            errorMessage = nil
        } catch {
            errorMessage = "Failed to load recommendations."
        }
    }
}

@MainActor
final class WatchHistoryViewModel: ObservableObject {
    @Published private(set) var items: [VideoItem] = []
    @Published private(set) var filteredItems: [VideoItem] = []
    @Published private(set) var searchQuery: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String? = nil

    private var continuation: String? = nil
    private var hasLoadedInitial = false
    private var searchTask: Task<Void, Never>? = nil

    var hasActiveFilter: Bool {
        !trimmedSearchQuery.isEmpty
    }

    var totalItemCount: Int {
        items.count
    }

    func loadInitial() {
        guard !hasLoadedInitial else { return }
        hasLoadedInitial = true
        Task { await fetch(reset: true) }
    }

    func reload() {
        searchTask?.cancel()
        hasLoadedInitial = false
        loadInitial()
    }

    func updateSearchQuery(_ query: String) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery != searchQuery else { return }

        searchQuery = normalizedQuery
        searchTask?.cancel()

        guard hasLoadedInitial else {
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            await self?.fetch(reset: true, queryOverride: normalizedQuery)
        }
    }

    func loadMoreIfNeeded(currentVideo: VideoItem) {
        guard continuation != nil, !isLoading else { return }
        guard filteredItems.last == currentVideo else { return }
        Task { await fetch(reset: false) }
    }

    func removeItemsLocally(ids videoIDs: [String]) {
        guard videoIDs.isEmpty == false else { return }
        let idSet = Set(videoIDs)
        items.removeAll { idSet.contains($0.id) }
        filteredItems.removeAll { idSet.contains($0.id) }
    }

    func applyLocalProgress(_ progress: VideoProgress, to videoID: String) {
        let patch: (VideoItem) -> VideoItem = { item in
            guard item.id == videoID else { return item }
            var updated = item
            updated.progress = (item.progress ?? progress).mergingLocal(progress)
            return updated
        }
        items = items.map(patch)
        filteredItems = filteredItems.map(patch)
    }

    func restore(items: [VideoItem], filteredItems: [VideoItem]) {
        self.items = items
        self.filteredItems = filteredItems
    }

    private func fetch(reset: Bool, queryOverride: String? = nil) async {
        let requestQuery = (queryOverride ?? trimmedSearchQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        isLoading = true
        defer { isLoading = false }

        if reset {
            continuation = nil
            items = []
            filteredItems = []
        }

        do {
            let response = try await BackendClient.shared.fetchWatchHistory(
                query: requestQuery.isEmpty ? nil : requestQuery,
                continuation: reset ? nil : continuation
            )
            guard requestQuery == trimmedSearchQuery else { return }
            if reset {
                items = response.items
            } else {
                items = appendUniqueItems(existing: items, incoming: response.items, id: \.id).items
            }
            continuation = response.continuation
            filteredItems = items
            errorMessage = nil
        } catch {
            guard requestQuery == trimmedSearchQuery else { return }
            errorMessage = error.localizedDescription
        }
    }

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

@MainActor
final class SearchViewModel: ObservableObject {
    enum Scope: Equatable {
        case global
        case history
        case channel(ChannelReference)
    }

    struct ParsedVideoLink: Equatable {
        let videoID: String
        let startTime: Double
    }

    struct LinkPreview: Equatable {
        let videoID: String
        let title: String
        let channel: String?
        let startTime: Double
        let thumbnailURL: URL?
    }

    @Published var query: String = ""
    @Published private(set) var results: [VideoItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String? = nil
    @Published private(set) var isActive = false
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var linkPreview: LinkPreview? = nil
    @Published private(set) var isLoadingSuggestions = false
    @Published private(set) var hasSuspendedResults = false

    private var continuation: String? = nil
    @Published private(set) var lastQuery: String = ""
    private var suggestionTask: Task<Void, Never>? = nil
    private var linkPreviewTask: Task<Void, Never>? = nil

    enum SubmitOutcome {
        case none
        case search
        case channelSearch
        case openedVideoLink
    }

    func submit(navigation: AppNavigationModel, scope: Scope) -> SubmitOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        if let parsedLink = Self.extractVideoLink(from: trimmed) {
            let placeholder = VideoItem(
                id: parsedLink.videoID,
                title: "Loading...",
                channel: nil,
                channelId: nil,
                channelAvatarUrl: nil,
                viewCountText: nil,
                publishedTimeText: nil,
                durationText: nil,
                thumbnails: []
            )
            navigation.showVideo(placeholder, startTime: parsedLink.startTime)
            return .openedVideoLink
        }

        switch scope {
        case .global:
            performSearch(query: trimmed, reset: true)
            return .search
        case .channel(let channel):
            navigation.showChannel(channel, tab: .search, searchQuery: trimmed)
            return .channelSearch
        case .history:
            return .none
        }
    }

    func clear() {
        suggestionTask?.cancel()
        linkPreviewTask?.cancel()
        query = ""
        results = []
        isActive = false
        errorMessage = nil
        continuation = nil
        lastQuery = ""
        suggestions = []
        linkPreview = nil
        isLoadingSuggestions = false
        hasSuspendedResults = false
    }

    func clearToolbarInput() {
        suggestionTask?.cancel()
        linkPreviewTask?.cancel()
        query = ""
        suggestions = []
        linkPreview = nil
        isLoadingSuggestions = false
        errorMessage = nil
    }

    func handleQueryChange(scope: Scope) {
        suggestionTask?.cancel()
        linkPreviewTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestions = []
            linkPreview = nil
            isLoadingSuggestions = false
            return
        }

        if let parsedLink = Self.extractVideoLink(from: trimmed) {
            suggestions = []
            isLoadingSuggestions = false
            linkPreview = LinkPreview(
                videoID: parsedLink.videoID,
                title: "YouTube link detected",
                channel: nil,
                startTime: parsedLink.startTime,
                thumbnailURL: nil
            )

            linkPreviewTask = Task {
                do {
                    let playback = try await BackendClient.shared.fetchVideo(id: parsedLink.videoID)
                    guard !Task.isCancelled else { return }
                    linkPreview = LinkPreview(
                        videoID: parsedLink.videoID,
                        title: playback.title ?? "YouTube link detected",
                        channel: playback.channel,
                        startTime: parsedLink.startTime,
                        thumbnailURL: Self.thumbnailURL(for: parsedLink.videoID)
                    )
                } catch {
                    guard !Task.isCancelled else { return }
                }
            }
            return
        }

        guard scope == .global else {
            suggestions = []
            linkPreview = nil
            isLoadingSuggestions = false
            return
        }

        linkPreview = nil
        isLoadingSuggestions = true

        suggestionTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }

            do {
                let response = try await BackendClient.shared.fetchSearchSuggestions(query: trimmed)
                guard !Task.isCancelled else { return }
                suggestions = response.suggestions
            } catch {
                guard !Task.isCancelled else { return }
                suggestions = []
            }
            isLoadingSuggestions = false
        }
    }

    func applySuggestion(_ suggestion: String) {
        query = suggestion
        suggestions = []
        linkPreview = nil
    }

    func dismissAssist() {
        suggestionTask?.cancel()
        linkPreviewTask?.cancel()
        suggestions = []
        linkPreview = nil
        isLoadingSuggestions = false
    }

    func dismissResults() {
        dismissAssist()
        isActive = false
        hasSuspendedResults = false
    }

    func suspendResultsForNavigation() {
        guard isActive, !results.isEmpty else { return }
        dismissAssist()
        isActive = false
        hasSuspendedResults = true
    }

    func resumeSuspendedResultsIfNeeded() {
        guard hasSuspendedResults, !results.isEmpty else { return }
        isActive = true
        hasSuspendedResults = false
    }

    func loadMoreIfNeeded(currentVideo: VideoItem) {
        guard let last = results.last, last == currentVideo else { return }
        guard !isSearching, continuation != nil else { return }
        performSearch(query: lastQuery, reset: false)
    }

    func applyLocalProgress(_ progress: VideoProgress, to videoID: String) {
        results = results.map { item in
            guard item.id == videoID else { return item }
            var updated = item
            updated.progress = (item.progress ?? progress).mergingLocal(progress)
            return updated
        }
    }

    private func performSearch(query: String, reset: Bool) {
        let searchQuery = query
        if reset {
            results = []
            continuation = nil
            lastQuery = searchQuery
        }
        isActive = true
        isSearching = true
        errorMessage = nil
        suggestions = []
        linkPreview = nil

        Task {
            defer { isSearching = false }
            do {
                var mergedResults = reset ? [] : results
                var nextContinuation = reset ? nil : continuation
                var remainingDuplicatePages = paginationDuplicateHopLimit

                while true {
                    let response = try await BackendClient.shared.fetchSearch(
                        query: searchQuery,
                        continuation: nextContinuation
                    )
                    let mergeResult = appendUniqueItems(existing: mergedResults, incoming: response.items, id: \.id)
                    mergedResults = mergeResult.items

                    let shouldAdvance = mergeResult.appendedCount == 0
                        && response.continuation != nil
                        && response.continuation != nextContinuation
                        && remainingDuplicatePages > 0
                    if !shouldAdvance {
                        continuation = response.continuation
                        results = mergedResults
                        break
                    }

                    nextContinuation = response.continuation
                    remainingDuplicatePages -= 1
                }
            } catch {
                errorMessage = "Search failed. Please try again."
            }
        }
    }

    private static func thumbnailURL(for videoID: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/hq720.jpg")
    }

    static func extractVideoLink(from input: String) -> ParsedVideoLink? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Normalize: add scheme if missing so URL parsing works
        if !text.contains("://") {
            text = "https://" + text
        }

        guard let url = URL(string: text),
              let host = url.host?.lowercased() else {
            return nil
        }

        // youtu.be/VIDEO_ID
        if host == "youtu.be" || host == "www.youtu.be" {
            let videoID = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let validID = videoID.isEmpty ? nil : validVideoID(videoID) else { return nil }
            return ParsedVideoLink(videoID: validID, startTime: timestamp(from: url))
        }

        // youtube.com or m.youtube.com or www.youtube.com
        let youtubeHosts = ["youtube.com", "www.youtube.com", "m.youtube.com"]
        guard youtubeHosts.contains(host) else { return nil }

        // /watch?v=VIDEO_ID
        if url.path == "/watch" || url.path == "/watch/" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let videoID = components?.queryItems?.first(where: { $0.name == "v" })?.value {
                guard let validID = validVideoID(videoID) else { return nil }
                return ParsedVideoLink(videoID: validID, startTime: timestamp(from: url))
            }
        }

        // /shorts/VIDEO_ID or /embed/VIDEO_ID or /v/VIDEO_ID or /live/VIDEO_ID
        let prefixes = ["/shorts/", "/embed/", "/v/", "/live/"]
        for prefix in prefixes {
            if url.path.hasPrefix(prefix) {
                let videoID = String(url.path.dropFirst(prefix.count)).components(separatedBy: "/").first ?? ""
                if !videoID.isEmpty {
                    guard let validID = validVideoID(videoID) else { return nil }
                    return ParsedVideoLink(videoID: validID, startTime: timestamp(from: url))
                }
            }
        }

        return nil
    }

    private static func validVideoID(_ id: String) -> String? {
        // YouTube video IDs are 11 characters, alphanumeric plus - and _
        let cleaned = id.components(separatedBy: CharacterSet.urlQueryAllowed.inverted).first ?? id
        guard cleaned.count == 11 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard cleaned.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return cleaned
    }

    private static func timestamp(from url: URL) -> Double {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        if let rawTimestamp = queryItems.first(where: { ["t", "start", "time_continue"].contains($0.name) })?.value,
           let parsed = parseTimestamp(rawTimestamp) {
            return parsed
        }

        if let fragment = components?.fragment {
            let fragmentValue = fragment
                .components(separatedBy: "&")
                .first(where: { $0.hasPrefix("t=") || $0.hasPrefix("start=") })?
                .components(separatedBy: "=")
                .dropFirst()
                .joined(separator: "=")

            if let fragmentValue, let parsed = parseTimestamp(fragmentValue) {
                return parsed
            }
        }

        return 0
    }

    private static func parseTimestamp(_ rawValue: String) -> Double? {
        let cleaned = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return nil }

        if let seconds = Double(cleaned.replacingOccurrences(of: "s", with: "")),
           cleaned.range(of: #"^\d+s?$"#, options: .regularExpression) != nil {
            return seconds
        }

        let pattern = #"(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) else {
            return nil
        }

        func component(at index: Int) -> Double {
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: cleaned) else { return 0 }
            return Double(cleaned[swiftRange]) ?? 0
        }

        let totalSeconds = (component(at: 1) * 3600) + (component(at: 2) * 60) + component(at: 3)
        return totalSeconds > 0 ? totalSeconds : nil
    }
}

@MainActor
final class ChannelPageViewModel: ObservableObject {
    @Published private(set) var header: ChannelHeader? = nil
    @Published private(set) var tabs: [ChannelTabSummary] = []
    @Published private(set) var items: [ChannelContentItem] = []
    @Published private(set) var sortOptions: [ChannelSortOption] = []
    @Published private(set) var filterOptions: [ChannelSortOption] = []
    @Published private(set) var about: ChannelAbout? = nil
    @Published private(set) var subscription: SubscriptionState? = nil
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var isLoadingAbout = false
    @Published var errorMessage: String? = nil
    @Published var aboutErrorMessage: String? = nil

    private var continuation: String? = nil
    private var currentRoute: ChannelRoute?
    private var currentChannelID: String? = nil
    private var subscriptionCommands: [String: InnerTubeCommand?] = [:]
    private let mutationCenter = AppMutationCenter.shared

    func load(route: ChannelRoute) {
        Task { await fetchInitial(route: route) }
    }

    func reload(route: ChannelRoute) {
        Task { await fetchInitial(route: route, force: true) }
    }

    func loadMoreIfNeeded(currentItem: ChannelContentItem) {
        guard let last = items.last, last.id == currentItem.id else { return }
        guard let continuation, !continuation.isEmpty, !isLoadingMore else { return }
        Task { await fetchContinuation(token: continuation) }
    }

    func selectSortOption(_ option: ChannelSortOption) {
        guard !option.isSelected, !option.continuationToken.isEmpty, !isLoading else { return }
        Task { await fetchSorted(token: option.continuationToken) }
    }

    func clearSelectedFilters() {
        guard filterOptions.contains(where: \.isSelected),
              !isLoading,
              let currentRoute else {
            return
        }
        Task { await fetchInitial(route: currentRoute, force: true) }
    }

    func loadAboutIfNeeded() {
        guard about == nil,
              let token = header?.aboutContinuationToken,
              !token.isEmpty,
              !isLoadingAbout else {
            return
        }
        isLoadingAbout = true
        aboutErrorMessage = nil

        Task {
            defer { isLoadingAbout = false }
            do {
                about = try await BackendClient.shared.fetchChannelAbout(token: token).about
            } catch {
                aboutErrorMessage = error.localizedDescription
            }
        }
    }

    func toggleSubscription() {
        guard let header else {
            return
        }

        let subscription = subscription ?? SubscriptionState(
            channelId: header.channel.channelId,
            buttonText: header.subscribeButtonTitle ?? "Subscribe",
            subscribed: (header.subscribeButtonTitle ?? "").lowercased().contains("subscribed"),
            enabled: true,
            subscriberCountText: header.subscriberCountText
        )
        let previousSubscription = self.subscription
        let targetSubscribed = !subscription.subscribed
        let optimisticSubscription = SubscriptionState(
            channelId: subscription.channelId,
            buttonText: subscription.subscribed ? "Subscribe" : "Subscribed",
            subscribed: targetSubscribed,
            enabled: subscription.enabled,
            subscriberCountText: subscription.subscriberCountText
        )
        let commandSnapshot = subscriptionCommands
        let fallbackVideoIDSnapshot = firstChannelVideoID
        self.subscription = optimisticSubscription

        mutationCenter.submit(
            key: MutationQueueKey.subscription(videoID: header.channel.channelId),
            successNotice: MutationNotice(
                title: optimisticSubscription.subscribed ? "Subscribed" : "Unsubscribed",
                message: nil,
                symbol: optimisticSubscription.subscribed ? "person.badge.plus" : "person.badge.minus",
                accent: .green
            ),
            errorNotice: { error in
                MutationNotice(
                    title: "Couldn’t update subscription",
                    message: error.localizedDescription,
                    symbol: "person.badge.plus",
                    accent: .red
                )
            },
            optimistic: {},
            rollback: { [weak self] _ in
                self?.subscription = previousSubscription
            },
            execute: {
                if commandSnapshot.values.compactMap({ $0 }).isEmpty == false {
                    return try await BackendClient.shared.updateChannelSubscription(
                        channelID: header.channel.channelId,
                        subscribed: !subscription.subscribed,
                        commands: commandSnapshot
                    )
                }

                var fallbackVideoID = fallbackVideoIDSnapshot
                if fallbackVideoID == nil {
                    let page = try await BackendClient.shared.fetchChannelPage(
                        channelID: header.channel.channelId,
                        tab: .videos
                    )
                    fallbackVideoID = page.items.lazy.compactMap { item -> String? in
                        if case .video(let video) = item {
                            return video.id
                        }
                        return nil
                    }.first
                }
                guard let fallbackVideoID else {
                    throw BackendClientError(message: "This channel doesn’t expose a subscribe action right now.")
                }

                return try await BackendClient.shared.updateSubscription(
                    id: fallbackVideoID,
                    subscribed: !subscription.subscribed
                )
            },
            applySuccess: { [weak self] response in
                self?.subscription = self?.resolvedSubscriptionState(
                    incoming: response.subscription,
                    previous: previousSubscription,
                    optimistic: optimisticSubscription,
                    targetSubscribed: targetSubscribed
                ) ?? optimisticSubscription
            }
        )
    }

    private func fetchInitial(route: ChannelRoute, force: Bool = false) async {
        let requestedRoute = normalizedContentRoute(for: route)
        let channelChanged = currentChannelID != route.channel.channelId

        if route.tab == .about, channelChanged == false, header != nil {
            if about == nil || channelChanged {
                loadAboutIfNeeded()
            }
            return
        }

        if route.tab == .about {
            if about == nil || channelChanged {
                loadAboutIfNeeded()
            }
        }

        if force == false, currentRoute == requestedRoute, header != nil {
            if route.tab == .about, about == nil {
                loadAboutIfNeeded()
            }
            return
        }

        currentChannelID = route.channel.channelId
        currentRoute = requestedRoute
        isLoading = true
        errorMessage = nil
        continuation = nil
        items = []
        sortOptions = []
        filterOptions = []
        if channelChanged {
            about = nil
            aboutErrorMessage = nil
            subscription = nil
        }

        defer { isLoading = false }

        do {
            let response = try await BackendClient.shared.fetchChannelPage(
                channelID: requestedRoute.channel.channelId,
                tab: requestedRoute.tab,
                searchQuery: requestedRoute.searchQuery
            )
            header = response.header
            tabs = response.tabs
            items = applyChannelDefaults(to: response.items, header: response.header)
            sortOptions = response.sortOptions
            filterOptions = response.filterOptions
            continuation = response.continuation
            subscription = resolvedFetchedSubscriptionState(
                incoming: response.subscription,
                previous: channelChanged ? nil : subscription
            )
            subscriptionCommands = response.subscriptionCommands
            errorMessage = nil

            if route.tab == .about {
                loadAboutIfNeeded()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fetchSorted(token: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await BackendClient.shared.fetchChannelContinuation(token: token)
            items = applyChannelDefaults(to: response.items, header: header)
            sortOptions = response.sortOptions
            filterOptions = response.filterOptions
            continuation = response.continuation
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fetchContinuation(token: String) async {
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let response = try await BackendClient.shared.fetchChannelContinuation(token: token)
            let normalizedIncoming = applyChannelDefaults(to: response.items, header: header)
            let mergeResult = appendUniqueItems(existing: items, incoming: normalizedIncoming, id: \.id)
            items = mergeResult.items
            if !response.sortOptions.isEmpty {
                sortOptions = response.sortOptions
            }
            if !response.filterOptions.isEmpty {
                filterOptions = response.filterOptions
            }
            continuation = response.continuation
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func normalizedContentRoute(for route: ChannelRoute) -> ChannelRoute {
        guard route.tab == .about else { return route }
        return ChannelRoute(channel: route.channel, tab: .videos, searchQuery: nil)
    }

    private var firstChannelVideoID: String? {
        for item in items {
            if case .video(let video) = item {
                return video.id
            }
        }
        return nil
    }

    private func resolvedSubscriptionState(
        incoming: SubscriptionState?,
        previous: SubscriptionState?,
        optimistic: SubscriptionState,
        targetSubscribed: Bool
    ) -> SubscriptionState {
        guard let incoming else {
            return optimistic
        }

        guard incoming.subscribed == targetSubscribed else {
            if let previous, incoming.enabled == false, previous.channelId == optimistic.channelId {
                return SubscriptionState(
                    channelId: previous.channelId,
                    buttonText: optimistic.buttonText,
                    subscribed: targetSubscribed,
                    enabled: true,
                    subscriberCountText: incoming.subscriberCountText ?? previous.subscriberCountText
                )
            }
            return optimistic
        }

        return SubscriptionState(
            channelId: incoming.channelId,
            buttonText: incoming.buttonText ?? optimistic.buttonText,
            subscribed: incoming.subscribed,
            enabled: incoming.enabled || optimistic.enabled,
            subscriberCountText: incoming.subscriberCountText ?? optimistic.subscriberCountText
        )
    }

    private func resolvedFetchedSubscriptionState(
        incoming: SubscriptionState?,
        previous: SubscriptionState?
    ) -> SubscriptionState? {
        guard let incoming else { return previous }

        if let previous,
           previous.channelId == incoming.channelId,
           previous.enabled,
           incoming.enabled == false {
            return SubscriptionState(
                channelId: previous.channelId,
                buttonText: previous.buttonText ?? incoming.buttonText,
                subscribed: previous.subscribed,
                enabled: true,
                subscriberCountText: incoming.subscriberCountText ?? previous.subscriberCountText
            )
        }

        return incoming
    }

    private func applyChannelDefaults(
        to items: [ChannelContentItem],
        header: ChannelHeader?
    ) -> [ChannelContentItem] {
        guard let header else { return items }
        return items.map { item in
            switch item {
            case .video(var video):
                if video.channel == nil {
                    video = VideoItem(
                        id: video.id,
                        title: video.title,
                        channel: header.channel.title,
                        channelId: video.channelId ?? header.channel.channelId,
                        channelAvatarUrl: video.channelAvatarUrl ?? header.avatarUrl,
                        viewCountText: video.viewCountText,
                        publishedTimeText: video.publishedTimeText,
                        durationText: video.durationText,
                        thumbnails: video.thumbnails,
                        playlistSetVideoId: video.playlistSetVideoId,
                        playlistIndexText: video.playlistIndexText,
                        playlistSelected: video.playlistSelected,
                        playlistCanRemove: video.playlistCanRemove,
                        playlistCanMoveToTop: video.playlistCanMoveToTop,
                        playlistCanMoveToBottom: video.playlistCanMoveToBottom,
                        progress: video.progress,
                        tags: video.tags
                    )
                }
                return .video(video)
            default:
                return item
            }
        }
    }
}

@MainActor
final class PlaylistLibraryViewModel: ObservableObject {
    @Published private(set) var playlists: [PlaylistSummary] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String? = nil

    private var continuation: String? = nil
    private var hasLoadedInitial = false

    func loadInitial() {
        guard !hasLoadedInitial else { return }
        hasLoadedInitial = true
        Task { await fetch(reset: true) }
    }

    func reload() {
        hasLoadedInitial = false
        loadInitial()
    }

    func loadMoreIfNeeded(currentPlaylist: PlaylistSummary) {
        guard let last = playlists.last, last == currentPlaylist else { return }
        guard !isLoading, continuation != nil else { return }
        Task { await fetch(reset: false) }
    }

    private func fetch(reset: Bool) async {
        isLoading = true
        defer { isLoading = false }

        if reset {
            continuation = nil
            playlists = []
            errorMessage = nil
        }

        do {
            var mergedPlaylists = reset ? [] : playlists
            var nextContinuation = continuation
            var remainingDuplicatePages = paginationDuplicateHopLimit

            while true {
                let response = try await BackendClient.shared.fetchPlaylistLibrary(continuation: nextContinuation)
                let mergeResult = appendUniqueItems(existing: mergedPlaylists, incoming: response.items, id: \.playlistId)
                mergedPlaylists = mergeResult.items

                let shouldAdvance = mergeResult.appendedCount == 0
                    && response.continuation != nil
                    && response.continuation != nextContinuation
                    && remainingDuplicatePages > 0
                if !shouldAdvance {
                    continuation = response.continuation
                    playlists = mergedPlaylists
                    break
                }

                nextContinuation = response.continuation
                remainingDuplicatePages -= 1
            }

            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class PlaylistFeedViewModel: ObservableObject {
    @Published private(set) var feed: PlaylistFeed? = nil
    @Published private(set) var items: [VideoItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var mutationIDs: Set<String> = []
    @Published var errorMessage: String? = nil

    let playlist: PlaylistReference
    private var continuation: String? = nil
    private var hasLoadedInitial = false
    private var isReordering = false
    private let mutationCenter = AppMutationCenter.shared

    init(playlist: PlaylistReference) {
        self.playlist = playlist
    }

    func loadInitial() {
        guard !hasLoadedInitial else { return }
        hasLoadedInitial = true
        Task { await fetch(reset: true) }
    }

    func reload() {
        hasLoadedInitial = false
        loadInitial()
    }

    func loadMoreIfNeeded(currentVideo: VideoItem) {
        guard !isLoading, continuation != nil else { return }
        guard let currentIndex = items.firstIndex(of: currentVideo) else { return }
        let thresholdIndex = max(items.count - 5, 0)
        guard currentIndex >= thresholdIndex else { return }
        Task { await fetch(reset: false) }
    }

    private func fetch(reset: Bool) async {
        isLoading = true
        defer { isLoading = false }

        if reset {
            continuation = nil
            feed = nil
            items = []
            errorMessage = nil
        }

        do {
            var mergedItems = reset ? [] : items
            var nextContinuation = continuation
            var remainingDuplicatePages = paginationDuplicateHopLimit

            while true {
                let response = try await BackendClient.shared.fetchPlaylistFeed(
                    id: playlist.playlistId,
                    continuation: nextContinuation
                )
                let resolvedTitle = response.title == "Playlist"
                    ? (feed?.title ?? playlist.title)
                    : response.title
                let resolvedFeed = response.with(title: resolvedTitle)
                if reset || feed == nil {
                    feed = resolvedFeed
                }

                let mergeResult = appendUniqueItems(existing: mergedItems, incoming: response.items, id: \.id)
                mergedItems = mergeResult.items

                let shouldAdvance = mergeResult.appendedCount == 0
                    && response.continuation != nil
                    && response.continuation != nextContinuation
                    && remainingDuplicatePages > 0
                if !shouldAdvance {
                    continuation = response.continuation
                    items = mergedItems
                    break
                }

                nextContinuation = response.continuation
                remainingDuplicatePages -= 1
            }

            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveItemToTop(_ video: VideoItem) {
        guard let setVideoId = video.playlistSetVideoId,
              video.playlistCanMoveToTop else { return }

        let playlistID = playlist.playlistId
        let previousItems = items
        items = move(video, in: items, toTop: true)
        mutationIDs.insert(setVideoId)

        mutationCenter.submit(
            key: MutationQueueKey.playlistPosition(playlistID: playlist.playlistId, setVideoID: setVideoId),
            successNotice: MutationNotice(
                title: "Moved to top",
                message: nil,
                symbol: "arrow.up.to.line",
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
            optimistic: {},
            rollback: { [weak self] error in
                guard let self else { return }
                self.items = previousItems
                self.mutationIDs.remove(setVideoId)
                self.errorMessage = error.localizedDescription
            },
            execute: {
                _ = try await BackendClient.shared.reorderPlaylistItem(
                    playlistId: playlistID,
                    setVideoId: setVideoId,
                    position: "top"
                )
            },
            applySuccess: { [weak self] (_: Void) in
                self?.mutationIDs.remove(setVideoId)
                self?.errorMessage = nil
            }
        )
    }

    func moveItemToBottom(_ video: VideoItem) {
        guard let setVideoId = video.playlistSetVideoId,
              video.playlistCanMoveToBottom else { return }

        let playlistID = playlist.playlistId
        let previousItems = items
        items = move(video, in: items, toTop: false)
        mutationIDs.insert(setVideoId)

        mutationCenter.submit(
            key: MutationQueueKey.playlistPosition(playlistID: playlist.playlistId, setVideoID: setVideoId),
            successNotice: MutationNotice(
                title: "Moved to bottom",
                message: nil,
                symbol: "arrow.down.to.line",
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
            optimistic: {},
            rollback: { [weak self] error in
                guard let self else { return }
                self.items = previousItems
                self.mutationIDs.remove(setVideoId)
                self.errorMessage = error.localizedDescription
            },
            execute: {
                _ = try await BackendClient.shared.reorderPlaylistItem(
                    playlistId: playlistID,
                    setVideoId: setVideoId,
                    position: "bottom"
                )
            },
            applySuccess: { [weak self] (_: Void) in
                self?.mutationIDs.remove(setVideoId)
                self?.errorMessage = nil
            }
        )
    }

    func removeItem(_ video: VideoItem) {
        guard let setVideoId = video.playlistSetVideoId,
              video.playlistCanRemove else { return }

        let playlistID = playlist.playlistId
        let previousItems = items
        items.removeAll { $0.playlistSetVideoId == setVideoId }
        if let feed {
            let newCount = max(previousItems.count - 1, 0)
            self.feed = feed.with(
                itemCountText: newCount > 0 ? "\(newCount) videos" : feed.itemCountText,
                items: items
            )
        }
        mutationIDs.insert(setVideoId)

        mutationCenter.submit(
            key: MutationQueueKey.playlistMembership(playlistID: playlist.playlistId, setVideoID: setVideoId),
            successNotice: MutationNotice(
                title: "Removed from \(playlist.title)",
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
            optimistic: {},
            rollback: { [weak self] error in
                guard let self else { return }
                self.items = previousItems
                self.mutationIDs.remove(setVideoId)
                if let feed {
                    self.feed = feed.with(items: previousItems)
                }
                self.errorMessage = error.localizedDescription
            },
            execute: {
                _ = try await BackendClient.shared.removePlaylistItem(
                    playlistId: playlistID,
                    setVideoId: setVideoId
                )
            },
            applySuccess: { [weak self] (_: Void) in
                self?.mutationIDs.remove(setVideoId)
                self?.errorMessage = nil
            }
        )
    }

    func moveItem(_ video: VideoItem, to playlistID: String, destinationTitle: String) {
        guard let setVideoId = video.playlistSetVideoId,
              video.playlistCanRemove else { return }

        let previousItems = items
        items.removeAll { $0.playlistSetVideoId == setVideoId }
        if let feed {
            self.feed = feed.with(items: items)
        }
        mutationIDs.insert(setVideoId)

        mutationCenter.submit(
            key: MutationQueueKey.playlistMembership(playlistID: playlist.playlistId, setVideoID: setVideoId),
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
            optimistic: {},
            rollback: { [weak self] error in
                guard let self else { return }
                self.items = previousItems
                self.mutationIDs.remove(setVideoId)
                if let feed {
                    self.feed = feed.with(items: previousItems)
                }
                self.errorMessage = error.localizedDescription
            },
            execute: {
                _ = try await BackendClient.shared.updatePlaylist(
                    id: video.id,
                    playlistId: playlistID,
                    saved: true
                )
                _ = try await BackendClient.shared.removePlaylistItem(
                    playlistId: self.playlist.playlistId,
                    setVideoId: setVideoId
                )
            },
            applySuccess: { [weak self] (_: Void) in
                self?.mutationIDs.remove(setVideoId)
                self?.errorMessage = nil
            }
        )
    }

    func moveItemToWatchLater(_ video: VideoItem) {
        guard let setVideoId = video.playlistSetVideoId,
              video.playlistCanRemove else { return }

        let previousItems = items
        items.removeAll { $0.playlistSetVideoId == setVideoId }
        if let feed {
            self.feed = feed.with(items: items)
        }
        mutationIDs.insert(setVideoId)

        mutationCenter.submit(
            key: MutationQueueKey.playlistMembership(playlistID: playlist.playlistId, setVideoID: setVideoId),
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
            optimistic: {},
            rollback: { [weak self] error in
                guard let self else { return }
                self.items = previousItems
                self.mutationIDs.remove(setVideoId)
                if let feed {
                    self.feed = feed.with(items: previousItems)
                }
                self.errorMessage = error.localizedDescription
            },
            execute: {
                _ = try await BackendClient.shared.updateWatchLater(id: video.id, saved: true)
                _ = try await BackendClient.shared.removePlaylistItem(
                    playlistId: self.playlist.playlistId,
                    setVideoId: setVideoId
                )
            },
            applySuccess: { [weak self] (_: Void) in
                self?.mutationIDs.remove(setVideoId)
                self?.errorMessage = nil
            }
        )
    }

    func reorderItem(withID draggedID: String, toInsertionIndex insertionIndex: Int) -> Bool {
        guard !isReordering,
              let sourceIndex = items.firstIndex(where: { $0.id == draggedID }) else {
            return false
        }

        let clampedIndex = max(0, min(insertionIndex, items.count))
        let updated = reorderedItems(items, sourceIndex: sourceIndex, insertionIndex: clampedIndex)
        guard updated != items else { return false }

        let previousItems = items
        items = updated
        if let feed {
            self.feed = feed.with(items: updated)
        }

        isReordering = true
        mutationCenter.submit(
            key: MutationQueueKey.playlistOrder(playlistID: playlist.playlistId),
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
            optimistic: {},
            rollback: { [weak self] error in
                guard let self else { return }
                self.items = previousItems
                if let feed {
                    self.feed = feed.with(items: previousItems)
                }
                self.isReordering = false
                self.errorMessage = error.localizedDescription
            },
            execute: {
                try await self.syncPlaylistOrder(updated)
            },
            applySuccess: { [weak self] (_: Void) in
                self?.isReordering = false
                self?.errorMessage = nil
            }
        )

        return true
    }

    private func move(_ video: VideoItem, in items: [VideoItem], toTop: Bool) -> [VideoItem] {
        guard let currentIndex = items.firstIndex(where: { $0.playlistSetVideoId == video.playlistSetVideoId }) else {
            return items
        }

        var updated = items
        let item = updated.remove(at: currentIndex)
        if toTop {
            updated.insert(item, at: 0)
        } else {
            updated.append(item)
        }
        return updated
    }

    private func reorderedItems(_ items: [VideoItem], sourceIndex: Int, insertionIndex: Int) -> [VideoItem] {
        guard items.indices.contains(sourceIndex) else { return items }

        var updated = items
        let moved = updated.remove(at: sourceIndex)
        let targetIndex = sourceIndex < insertionIndex ? max(insertionIndex - 1, 0) : insertionIndex
        updated.insert(moved, at: min(max(targetIndex, 0), updated.count))
        return updated
    }

    private func syncPlaylistOrder(_ items: [VideoItem]) async throws {
        for item in items.reversed() {
            guard let setVideoId = item.playlistSetVideoId else { continue }
            _ = try await BackendClient.shared.reorderPlaylistItem(
                playlistId: playlist.playlistId,
                setVideoId: setVideoId,
                position: "top"
            )
        }
    }
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var playback: VideoPlayback? = nil
    @Published var isLoading = true
    @Published var errorMessage: String? = nil
    @Published private(set) var recommendations: [VideoItem] = []
    @Published private(set) var comments: [CommentItem] = []
    @Published private(set) var commentCountText: String? = nil
    @Published private(set) var isLoadingComments = false
    @Published private(set) var isLoadingRecommendations = false
    @Published private(set) var liveChatMessages: [LiveChatMessage] = []
    @Published private(set) var liveChatComposer: LiveChatComposer? = nil
    @Published private(set) var liveChatMode: LiveChatMode = .top
    @Published private(set) var isLoadingLiveChat = false
    @Published private(set) var liveChatErrorMessage: String? = nil
    @Published private(set) var transcriptSegments: [TranscriptSegment] = []
    @Published private(set) var transcriptTrack: SubtitleTrack? = nil
    @Published private(set) var isLoadingTranscript = false
    @Published private(set) var transcriptErrorMessage: String? = nil
    @Published private(set) var playbackLoadID = UUID()
    @Published private(set) var playlistOptions: [PlaylistOption] = []
    @Published private(set) var isLoadingPlaylistOptions = false

    let video: VideoItem
    private var loadTask: Task<Void, Never>? = nil
    private var commentsTask: Task<Void, Never>? = nil
    private var sponsorSegmentsTask: Task<Void, Never>? = nil
    private var liveChatTask: Task<Void, Never>? = nil
    private var liveChatPollTask: Task<Void, Never>? = nil
    private var transcriptTask: Task<Void, Never>? = nil
    private var lastReplaySyncOffsetMs: Int? = nil
    private var commentsContinuation: String? = nil
    private var recommendationsContinuation: String? = nil
    private let mutationCenter = AppMutationCenter.shared

    init(video: VideoItem) {
        self.video = video
    }

    func load() {
        loadTask?.cancel()
        commentsTask?.cancel()
        sponsorSegmentsTask?.cancel()
        liveChatTask?.cancel()
        liveChatPollTask?.cancel()
        transcriptTask?.cancel()
        loadTask = Task {
            await fetchPlayback()
        }
    }

    func stop() {
        loadTask?.cancel()
        commentsTask?.cancel()
        sponsorSegmentsTask?.cancel()
        liveChatTask?.cancel()
        liveChatPollTask?.cancel()
        transcriptTask?.cancel()
    }

    func reportPlaybackProgress(
        currentTime: Double,
        duration: Double,
        didFinish: Bool
    ) {
        guard playback?.isLive != true else { return }
        guard currentTime > 0 || didFinish else { return }

        Task {
            do {
                let response = try await BackendClient.shared.recordPlaybackProgress(
                    id: video.id,
                    currentTime: currentTime,
                    duration: duration > 0 ? duration : nil,
                    didFinish: didFinish
                )
                if let updatedProgress = response.progress {
                    updatePlayback { current in
                        current.with(
                            progress: updatedProgress,
                            resumeStartTimeSeconds: updatedProgress.bestResumeSeconds
                        )
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    private func fetchPlayback() async {
        isLoading = true
        errorMessage = nil
        playback = nil
        playbackLoadID = UUID()
        comments = []
        recommendations = []
        commentCountText = nil
        isLoadingComments = false
        isLoadingRecommendations = false
        sponsorSegmentsTask?.cancel()
        liveChatTask?.cancel()
        liveChatPollTask?.cancel()
        transcriptTask?.cancel()
        liveChatMessages = []
        liveChatComposer = nil
        liveChatMode = .top
        isLoadingLiveChat = false
        liveChatErrorMessage = nil
        transcriptSegments = []
        transcriptTrack = nil
        isLoadingTranscript = false
        transcriptErrorMessage = nil
        commentsContinuation = nil
        recommendationsContinuation = nil
        lastReplaySyncOffsetMs = nil
        playlistOptions = []
        isLoadingPlaylistOptions = false

        do {
            let playback = try await BackendClient.shared.fetchVideo(id: video.id)
            guard !Task.isCancelled else { return }
            self.playback = playback
            self.comments = []
            self.recommendations = deduplicatedItems(playback.recommendations, id: \.id)
            self.commentCountText = playback.commentCountText
            self.isLoadingComments = false
            self.recommendationsContinuation = playback.recommendationsContinuation
            self.liveChatMode = playback.liveChat?.defaultMode ?? .top
            isLoading = false
            playbackLoadID = UUID()
            loadSponsorSegments(for: playback)
            startCommentsLoad()
            startLiveChatLoadIfAvailable(for: playback)
            startTranscriptLoad(for: playback)
        } catch {
            guard !Task.isCancelled else { return }
            playback = nil
            comments = []
            recommendations = []
            commentCountText = nil
            isLoadingComments = false
            liveChatMessages = []
            liveChatComposer = nil
            liveChatErrorMessage = nil
            transcriptSegments = []
            transcriptTrack = nil
            transcriptErrorMessage = nil
            errorMessage = "Failed to load video."
            isLoading = false
            playbackLoadID = UUID()
        }
    }

    private func startCommentsLoad() {
        commentsTask?.cancel()
        commentsTask = Task { [weak self] in
            await self?.fetchComments()
        }
    }

    private func loadSponsorSegments(for playback: VideoPlayback) {
        sponsorSegmentsTask?.cancel()
        sponsorSegmentsTask = Task { [weak self] in
            guard let self else { return }
            let segments = await SponsorBlockClient.shared.fetchSegments(
                videoID: self.video.id,
                duration: playback.progress?.durationSeconds
            )
            guard !Task.isCancelled else { return }
            self.updatePlayback { current in
                current.with(sponsorSegments: segments)
            }
        }
    }

    private func fetchComments() async {
        isLoadingComments = true
        defer { isLoadingComments = false }

        do {
            let response = try await BackendClient.shared.fetchComments(id: video.id)
            guard !Task.isCancelled else { return }
            comments = deduplicatedItems(response.comments, id: \.id)
            commentCountText = response.commentCountText ?? commentCountText
            commentsContinuation = response.continuation
        } catch {
            guard !Task.isCancelled else { return }
        }
    }

    func loadMoreCommentsIfNeeded(currentComment: CommentItem) {
        guard !isLoadingComments, commentsContinuation != nil else { return }
        guard let currentIndex = comments.firstIndex(of: currentComment) else { return }
        let thresholdIndex = max(comments.count - 5, 0)
        guard currentIndex >= thresholdIndex else { return }

        Task {
            await fetchMoreComments()
        }
    }

    private func fetchMoreComments() async {
        guard let commentsContinuation else { return }
        isLoadingComments = true
        defer { isLoadingComments = false }

        do {
            var mergedComments = comments
            var nextContinuation: String? = commentsContinuation
            var remainingDuplicatePages = paginationDuplicateHopLimit

            while true {
                let response = try await BackendClient.shared.fetchComments(
                    id: video.id,
                    continuation: nextContinuation
                )
                guard !Task.isCancelled else { return }

                let mergeResult = appendUniqueItems(existing: mergedComments, incoming: response.comments, id: \.id)
                mergedComments = mergeResult.items
                if let count = response.commentCountText {
                    commentCountText = count
                }

                let shouldAdvance = mergeResult.appendedCount == 0
                    && response.continuation != nil
                    && response.continuation != nextContinuation
                    && remainingDuplicatePages > 0
                if !shouldAdvance {
                    comments = mergedComments
                    self.commentsContinuation = response.continuation
                    break
                }

                nextContinuation = response.continuation
                remainingDuplicatePages -= 1
            }
        } catch {
            guard !Task.isCancelled else { return }
        }
    }

    func loadMoreRecommendationsIfNeeded(currentVideo: VideoItem) {
        guard !isLoadingRecommendations, recommendationsContinuation != nil else { return }
        guard let currentIndex = recommendations.firstIndex(of: currentVideo) else { return }
        let thresholdIndex = max(recommendations.count - 5, 0)
        guard currentIndex >= thresholdIndex else { return }

        Task {
            await fetchMoreRecommendations()
        }
    }

    private func fetchMoreRecommendations() async {
        guard let recommendationsContinuation else { return }
        isLoadingRecommendations = true
        defer { isLoadingRecommendations = false }

        do {
            var mergedRecommendations = recommendations
            var nextContinuation: String? = recommendationsContinuation
            var remainingDuplicatePages = paginationDuplicateHopLimit

            while true {
                let response = try await BackendClient.shared.fetchRelatedVideos(
                    id: video.id,
                    continuation: nextContinuation
                )
                guard !Task.isCancelled else { return }

                let mergeResult = appendUniqueItems(existing: mergedRecommendations, incoming: response.items, id: \.id)
                mergedRecommendations = mergeResult.items

                let shouldAdvance = mergeResult.appendedCount == 0
                    && response.continuation != nil
                    && response.continuation != nextContinuation
                    && remainingDuplicatePages > 0
                if !shouldAdvance {
                    recommendations = mergedRecommendations
                    self.recommendationsContinuation = response.continuation
                    break
                }

                nextContinuation = response.continuation
                remainingDuplicatePages -= 1
            }
        } catch {
            guard !Task.isCancelled else { return }
        }
    }

    func selectLiveChatMode(_ mode: LiveChatMode) {
        guard liveChatMode != mode else { return }
        liveChatMode = mode
        liveChatMessages = []
        liveChatErrorMessage = nil
        liveChatTask?.cancel()
        liveChatPollTask?.cancel()
        liveChatTask = Task { [weak self] in
            await self?.fetchLiveChat()
        }
    }

    func sendLiveChatMessage(_ text: String) {
        guard let composer = liveChatComposer,
              let sendParams = composer.sendParams else {
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        let optimisticMessage = LiveChatMessage(
            id: "local-\(UUID().uuidString)",
            kind: .text,
            author: composer.authorName,
            authorChannelId: nil,
            avatarUrl: nil,
            fragments: optimisticLiveChatFragments(for: trimmed),
            timestampUsec: String(Int64(Date().timeIntervalSince1970 * 1_000_000)),
            purchaseAmountText: nil,
            isVerified: false,
            isOwner: false,
            isModerator: false,
            isMember: false,
            isPending: true
        )

        liveChatMessages.append(optimisticMessage)
        trimLiveChatMessageWindow()
        liveChatErrorMessage = nil

        Task {
            do {
                try await BackendClient.shared.sendLiveChatMessage(
                    message: trimmed,
                    params: sendParams,
                    clientIdPrefix: composer.clientIdPrefix
                )
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.liveChatMessages.removeAll { $0.id == optimisticMessage.id }
                    self.liveChatErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func startLiveChatLoadIfAvailable(for playback: VideoPlayback) {
        guard playback.liveChat != nil else { return }
        liveChatTask?.cancel()
        liveChatPollTask?.cancel()
        liveChatTask = Task { [weak self] in
            await self?.fetchLiveChat()
        }
    }

    private func fetchLiveChat(continuation: String? = nil, replayOffsetMs: Int? = nil) async {
        guard let session = playback?.liveChat else { return }

        if continuation == nil {
            isLoadingLiveChat = true
            liveChatErrorMessage = nil
        }

        defer {
            if continuation == nil {
                isLoadingLiveChat = false
            }
        }

        do {
            let response = try await BackendClient.shared.fetchLiveChat(
                id: video.id,
                mode: liveChatMode,
                continuation: continuation,
                isReplay: session.isReplay,
                replayOffsetMs: continuation == nil ? replayOffsetMs : nil
            )
            guard !Task.isCancelled else { return }

            if continuation == nil {
                liveChatMessages = []
            }
            applyLiveChat(response)

            if continuation == nil {
                startLiveChatPolling(
                    initialContinuation: response.continuation,
                    delayMs: response.timeoutMs ?? 5_000
                )
            }
        } catch {
            guard !Task.isCancelled else { return }
            if continuation == nil {
                liveChatErrorMessage = error.localizedDescription
            }
        }
    }

    private func startLiveChatPolling(initialContinuation: String?, delayMs: Int) {
        liveChatPollTask?.cancel()
        guard let initialContinuation else { return }

        liveChatPollTask = Task { [weak self] in
            guard let self else { return }

            var continuation: String? = initialContinuation
            var nextDelayMs = max(delayMs, 1_500)

            while !Task.isCancelled, let activeContinuation = continuation {
                try? await Task.sleep(nanoseconds: UInt64(nextDelayMs) * 1_000_000)
                guard !Task.isCancelled else { return }

                do {
                    let response = try await BackendClient.shared.fetchLiveChat(
                        id: self.video.id,
                        mode: self.liveChatMode,
                        continuation: activeContinuation,
                        isReplay: self.playback?.liveChat?.isReplay == true
                    )
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.applyLiveChat(response)
                    }
                    continuation = response.continuation
                    nextDelayMs = max(response.timeoutMs ?? nextDelayMs, 1_500)
                } catch {
                    guard !Task.isCancelled else { return }
                    nextDelayMs = 5_000
                }
            }
        }
    }

    func syncReplayChat(to seconds: Double, force: Bool = false) {
        guard let session = playback?.liveChat, session.isReplay else { return }

        let offsetMs = max(Int(seconds * 1_000), 0)
        if !force, let lastReplaySyncOffsetMs, abs(lastReplaySyncOffsetMs - offsetMs) < 8_000 {
            return
        }

        lastReplaySyncOffsetMs = offsetMs
        liveChatTask?.cancel()
        liveChatPollTask?.cancel()
        liveChatErrorMessage = nil
        isLoadingLiveChat = true
        liveChatTask = Task { [weak self] in
            await self?.fetchLiveChat(replayOffsetMs: offsetMs)
        }
    }

    private func applyLiveChat(_ response: LiveChatResponse) {
        liveChatComposer = response.composer ?? liveChatComposer
        liveChatErrorMessage = nil

        var merged = liveChatMessages
        let pendingMessages = merged.filter(\.isPending)
        let remoteMessages = response.replacedMessages + response.messages
        merged.removeAll { message in
            response.removedMessageIDs.contains(message.id)
        }

        for message in response.replacedMessages {
            if let index = merged.firstIndex(where: { $0.id == message.id }) {
                merged[index] = message
            } else {
                merged.append(message)
            }
        }

        for message in response.messages {
            if let index = merged.firstIndex(where: { $0.id == message.id }) {
                merged[index] = message
            } else {
                merged.append(message)
            }
        }

        let remoteFingerprints = Set(remoteMessages.map(\.plainText))
        let retainedPending = pendingMessages.filter { pending in
            remoteFingerprints.contains(pending.plainText) == false
        }

        merged.removeAll { $0.isPending }
        merged.append(contentsOf: retainedPending)
        liveChatMessages = merged
        trimLiveChatMessageWindow()
    }

    private func trimLiveChatMessageWindow() {
        let maximumMessages = 250
        if liveChatMessages.count > maximumMessages {
            liveChatMessages = Array(liveChatMessages.suffix(maximumMessages))
        }
    }

    private func startTranscriptLoad(for playback: VideoPlayback) {
        transcriptTask?.cancel()
        transcriptTask = Task { [weak self] in
            await self?.fetchTranscript(for: playback)
        }
    }

    private func fetchTranscript(for playback: VideoPlayback) async {
        let track = preferredTranscriptTrack(from: playback)
        transcriptTrack = track

        guard let track else {
            transcriptSegments = []
            transcriptErrorMessage = nil
            return
        }

        isLoadingTranscript = true
        transcriptErrorMessage = nil
        defer { isLoadingTranscript = false }

        do {
            let response = try await BackendClient.shared.fetchTranscript(track: track)
            guard !Task.isCancelled else { return }
            transcriptTrack = response.track
            transcriptSegments = response.segments
        } catch {
            guard !Task.isCancelled else { return }
            transcriptSegments = []
            transcriptErrorMessage = error.localizedDescription
        }
    }

    private func preferredTranscriptTrack(from playback: VideoPlayback) -> SubtitleTrack? {
        let subtitles = playback.subtitles ?? []
        if subtitles.isEmpty { return nil }

        return subtitles.first(where: { $0.isAutoGenerated == false && $0.language.lowercased().hasPrefix("en") })
            ?? subtitles.first(where: { $0.language.lowercased().hasPrefix("en") })
            ?? subtitles.first(where: { $0.isAutoGenerated == false })
            ?? subtitles.first
    }

    private func optimisticLiveChatFragments(for message: String) -> [LiveChatMessageFragment] {
        let parts = message.split(separator: " ", omittingEmptySubsequences: false)
        return parts.enumerated().map { index, part in
            let text = String(part)
            let kind: LiveChatMessageFragmentKind = text.hasPrefix("@") ? .mention : .text
            let suffix = index < parts.count - 1 ? " " : ""
            return LiveChatMessageFragment(
                id: "local-\(index)",
                text: text + suffix,
                kind: kind,
                url: nil,
                emojiImageUrl: nil
            )
        }
    }

    func loadPlaylistOptions() {
        guard playback?.playlistSaveEnabled == true, !isLoadingPlaylistOptions else { return }

        Task {
            isLoadingPlaylistOptions = true
            defer { isLoadingPlaylistOptions = false }

            do {
                let response = try await BackendClient.shared.fetchPlaylistOptions(id: video.id)
                let watchLater = response.options.first(where: { $0.playlistId == "WL" })
                updatePlaybackWatchLater(watchLater)
                playlistOptions = response.options.filter { $0.playlistId != "WL" }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func toggleSubscription() {
        guard let subscription = playback?.subscription else { return }
        let previousPlayback = playback
        let optimisticSubscription = SubscriptionState(
            channelId: subscription.channelId,
            buttonText: subscription.subscribed ? "Subscribe" : "Subscribed",
            subscribed: !subscription.subscribed,
            enabled: subscription.enabled,
            subscriberCountText: subscription.subscriberCountText
        )

        updatePlayback { current in
            current.with(
                subscriberCountText: optimisticSubscription.subscriberCountText,
                subscription: optimisticSubscription
            )
        }
        let videoID = video.id

        mutationCenter.submit(
            key: MutationQueueKey.subscription(videoID: videoID),
            successNotice: MutationNotice(
                title: optimisticSubscription.subscribed ? "Subscribed" : "Unsubscribed",
                message: nil,
                symbol: optimisticSubscription.subscribed ? "person.badge.plus" : "person.badge.minus",
                accent: .green
            ),
            errorNotice: { error in
                MutationNotice(
                    title: "Couldn’t update subscription",
                    message: error.localizedDescription,
                    symbol: "person.badge.plus",
                    accent: .red
                )
            },
            optimistic: {},
            rollback: { [weak self] _ in
                self?.playback = previousPlayback
            },
            execute: {
                try await BackendClient.shared.updateSubscription(
                    id: videoID,
                    subscribed: !subscription.subscribed
                )
            },
            applySuccess: { [weak self] response in
                guard let self else { return }
                self.updatePlayback { current in
                    current.with(
                        subscriberCountText: response.subscription?.subscriberCountText,
                        subscription: optimisticSubscription
                    )
                }
            }
        )
    }

    func toggleRating(_ target: String) {
        guard let rating = playback?.rating else { return }
        let previousPlayback = playback
        let backendAction: String = {
            switch target {
            case "like" where rating.status == "LIKE":
                return "none"
            case "dislike" where rating.status == "DISLIKE":
                return "none"
            default:
                return target
            }
        }()
        let optimisticStatus: String = {
            switch target {
            case "like":
                return rating.status == "LIKE" ? "INDIFFERENT" : "LIKE"
            case "dislike":
                return rating.status == "DISLIKE" ? "INDIFFERENT" : "DISLIKE"
            default:
                return "INDIFFERENT"
            }
        }()
        let optimisticRating = RatingState(
            status: optimisticStatus,
            likeCountText: rating.likeCountText
        )

        updatePlayback { current in
            current.with(
                likeCountText: optimisticRating.likeCountText,
                rating: optimisticRating
            )
        }
        let videoID = video.id

        mutationCenter.submit(
            key: MutationQueueKey.rating(videoID: videoID),
            successNotice: MutationNotice(
                title: ratingNoticeTitle(for: optimisticStatus),
                message: nil,
                symbol: ratingNoticeSymbol(for: optimisticStatus),
                accent: .green
            ),
            errorNotice: { error in
                MutationNotice(
                    title: "Couldn’t update rating",
                    message: error.localizedDescription,
                    symbol: "hand.thumbsup",
                    accent: .red
                )
            },
            optimistic: {},
            rollback: { [weak self] _ in
                self?.playback = previousPlayback
            },
            execute: {
                try await BackendClient.shared.updateRating(id: videoID, action: backendAction)
            },
            applySuccess: { [weak self] response in
                guard let self else { return }
                self.updatePlayback { current in
                    current.with(
                        likeCountText: response.rating?.likeCountText,
                        rating: optimisticRating
                    )
                }
            }
        )
    }

    func toggleWatchLater() {
        guard let watchLater = playback?.watchLater else { return }
        let previousPlayback = playback
        let optimisticWatchLater = PlaylistOption(
            playlistId: watchLater.playlistId,
            title: watchLater.title,
            privacy: watchLater.privacy,
            containsSelectedVideos: !watchLater.saved ? "ALL" : "NONE",
            saved: !watchLater.saved
        )

        updatePlayback { current in
            current.with(watchLater: optimisticWatchLater)
        }
        let videoID = video.id

        mutationCenter.submit(
            key: MutationQueueKey.watchLater(videoID: videoID),
            successNotice: MutationNotice(
                title: optimisticWatchLater.saved ? "Added to Watch Later" : "Removed from Watch Later",
                message: nil,
                symbol: optimisticWatchLater.saved ? "clock.fill" : "clock",
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
            rollback: { [weak self] _ in
                self?.playback = previousPlayback
            },
            execute: {
                try await BackendClient.shared.updateWatchLater(
                    id: videoID,
                    saved: !watchLater.saved
                )
            },
            applySuccess: { [weak self] response in
                guard let self else { return }
                if let updated = response.watchLater {
                    self.playlistOptions = self.playlistOptions.map { item in
                        item.playlistId == updated.playlistId
                            ? PlaylistOption(
                                playlistId: updated.playlistId,
                                title: updated.title,
                                privacy: updated.privacy,
                                containsSelectedVideos: optimisticWatchLater.containsSelectedVideos,
                                saved: optimisticWatchLater.saved
                            )
                            : item
                    }
                }
                self.updatePlaybackWatchLater(optimisticWatchLater)
            }
        )
    }

    func togglePlaylist(_ option: PlaylistOption) {
        let previousOptions = playlistOptions
        let optimisticOption = PlaylistOption(
            playlistId: option.playlistId,
            title: option.title,
            privacy: option.privacy,
            containsSelectedVideos: option.saved ? "NONE" : "ALL",
            saved: !option.saved
        )

        playlistOptions = playlistOptions.map { item in
            item.playlistId == option.playlistId ? optimisticOption : item
        }
        let videoID = video.id
        mutationCenter.submit(
            key: MutationQueueKey.playlist(videoID: videoID, playlistID: option.playlistId),
            successNotice: MutationNotice(
                title: optimisticOption.saved ? "Saved to \(option.title)" : "Removed from \(option.title)",
                message: nil,
                symbol: optimisticOption.saved ? "music.note.list" : "music.note.list",
                accent: .green
            ),
            errorNotice: { error in
                MutationNotice(
                    title: "Couldn’t update \(option.title)",
                    message: error.localizedDescription,
                    symbol: "music.note.list",
                    accent: .red
                )
            },
            optimistic: {},
            rollback: { [weak self] _ in
                self?.playlistOptions = previousOptions
            },
            execute: {
                try await BackendClient.shared.updatePlaylist(
                    id: videoID,
                    playlistId: option.playlistId,
                    saved: !option.saved
                )
            },
            applySuccess: { [weak self] response in
                guard let self else { return }
                if let updated = response.playlist {
                    self.playlistOptions = self.playlistOptions.map { item in
                        item.playlistId == updated.playlistId
                            ? PlaylistOption(
                                playlistId: updated.playlistId,
                                title: updated.title,
                                privacy: updated.privacy,
                                containsSelectedVideos: optimisticOption.containsSelectedVideos,
                                saved: optimisticOption.saved
                            )
                            : item
                    }
                }
            }
        )
    }

    private func updatePlayback(_ transform: (VideoPlayback) -> VideoPlayback) {
        guard let playback else { return }
        self.playback = transform(playback)
    }

    private func updatePlaybackWatchLater(_ watchLater: PlaylistOption?) {
        updatePlayback { current in
            current.with(watchLater: watchLater)
        }
    }

    private func ratingNoticeTitle(for status: String) -> String {
        switch status {
        case "LIKE":
            return "Liked video"
        case "DISLIKE":
            return "Disliked video"
        default:
            return "Removed rating"
        }
    }

    private func ratingNoticeSymbol(for status: String) -> String {
        switch status {
        case "LIKE":
            return "hand.thumbsup.fill"
        case "DISLIKE":
            return "hand.thumbsdown.fill"
        default:
            return "hand.thumbsup.slash"
        }
    }
}
