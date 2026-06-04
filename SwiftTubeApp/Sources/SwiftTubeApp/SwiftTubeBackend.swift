import Foundation
import JavaScriptCore

extension Notification.Name {
    static let playbackProgressDidUpdate = Notification.Name("SwiftTubePlaybackProgressDidUpdate")
    static let authSessionDidChange = Notification.Name("SwiftTubeAuthSessionDidChange")
}

private struct WatchTrackingSnapshot: Sendable {
    let playbackURL: URL?
    let watchtimeURL: URL?
    let durationSeconds: Double?
}

private struct ActiveWatchSyncSession: Sendable {
    let videoID: String
    let cpn: String
    let tracking: WatchTrackingSnapshot
    var lastObservedSecond: Double?
    var pendingSegmentStartSecond: Double?
    var pendingSegmentEndSecond: Double?
    var sentInitialPlayback = false
}

private struct HistoryVideoRecord: Sendable {
    let item: VideoItem
    let sectionTitle: String?
    let indexInSection: Int
    let deleteCommand: InnerTubeCommand?
}

actor SwiftTubeBackend {
    static let shared = SwiftTubeBackend()

    private let authManager = YouTubeAuthManager()
    private let watchHistoryStore = WatchHistoryStore()
    private lazy var api = YouTubeAPI(authManager: authManager)
    private var channelAvatarCache: [String: String?] = [:]
    private var playbackCache: [String: YTDLPPlaybackData] = [:]
    private var inlinePlaybackCache: [String: InlinePlaybackPayload] = [:]
    private var trackingCache: [String: WatchTrackingSnapshot] = [:]
    private var playerScriptResolverCache: [String: YouTubeStreamURLResolver] = [:]
    private var activeWatchSyncSessions: [String: ActiveWatchSyncSession] = [:]

    func start() async throws {
        // The in-process backend has no bootstrap work; auth validation happens on demand.
    }

    func authStatus() async throws -> AuthStatusResponse {
        guard await authManager.currentMaterial() != nil else {
            return await authManager.signedOutStatus()
        }

        if await authManager.needsAccountIdentifierRefresh() {
            await refreshSignedInAccountProfile()
        }

        return await authManager.authStatus()
    }

    func connectBrowserAuth(browser: String) async throws -> AuthStatusResponse {
        _ = try await authManager.connect(browser: browser)
        do {
            try await api.validateAuthentication()
            await refreshSignedInAccountProfile()
            return await authManager.authStatus()
        } catch {
            _ = try? await authManager.clear()
            throw error
        }
    }

    func discoverBrowserAccounts() async throws -> [BrowserAccountDiscoveryResponse] {
        let browsers = BrowserLoginOption.installedOptions.filter { $0.cookieSource != nil }

        let probes = await withTaskGroup(of: BrowserAccountProbe?.self) { group in
            for browser in browsers {
                group.addTask {
                    await probeBrowserAccount(browser)
                }
            }

            var values: [BrowserAccountProbe] = []
            for await probe in group {
                if let probe {
                    values.append(probe)
                }
            }
            return values
        }

        return groupedBrowserAccounts(from: probes)
    }

    func runExtractorSpeedTest(videoID: String) async throws -> [ExtractorSpeedTestResult] {
        var results: [ExtractorSpeedTestResult] = []

        for mode in ExtractorSpeedTestMode.allCases {
            if let unavailableMessage = unavailableExtractorMessage(for: mode) {
                results.append(
                    ExtractorSpeedTestResult(
                        mode: mode,
                        isAvailable: false,
                        elapsedMilliseconds: nil,
                        streamCount: 0,
                        bestFormatID: nil,
                        errorMessage: unavailableMessage
                    )
                )
                continue
            }

            playbackCache.removeAll()
            let startDate = Date()

            do {
                let playbackData: (streamCount: Int, bestFormatID: String?)
                if mode == .nativeSwift {
                    let playback = try await withTimeout(
                        seconds: extractorSpeedTestModeTimeoutSeconds,
                        timeoutMessage: "\(mode.title) timed out."
                    ) {
                        try await self.buildVideoPlayback(videoID: videoID, authenticated: false, allowYTDLPFallback: false)
                    }
                    playbackData = (playback.streams.count, playback.bestStream?.formatId)
                } else if let ytdlpPlayback = try await extractYTDLPPlayback(
                    videoID: videoID,
                    cookieFileURL: nil,
                    source: mode.dependencySource,
                    timeout: ytDLPPlaybackTimeoutSeconds
                ) {
                    playbackData = (ytdlpPlayback.streams.count, ytdlpPlayback.streams.first?.formatId)
                } else {
                    throw BackendClientError(message: "\(mode.title) did not return playback formats.")
                }
                let elapsedMilliseconds = Int(Date().timeIntervalSince(startDate) * 1000)
                results.append(
                    ExtractorSpeedTestResult(
                        mode: mode,
                        isAvailable: true,
                        elapsedMilliseconds: elapsedMilliseconds,
                        streamCount: playbackData.streamCount,
                        bestFormatID: playbackData.bestFormatID,
                        errorMessage: nil
                    )
                )
            } catch {
                let elapsedMilliseconds = Int(Date().timeIntervalSince(startDate) * 1000)
                results.append(
                    ExtractorSpeedTestResult(
                        mode: mode,
                        isAvailable: true,
                        elapsedMilliseconds: elapsedMilliseconds,
                        streamCount: 0,
                        bestFormatID: nil,
                        errorMessage: error.localizedDescription
                    )
                )
            }
        }

        return results
    }

    func clearAuthSession() async throws -> AuthStatusResponse {
        try await authManager.clear(preserveBrowserChoice: false)
    }

    func fetchRecommendations(continuation: String? = nil) async throws -> RecommendationsResponse {
        var note: String?
        let usingAuth = await authManager.currentMaterial() != nil

        let data: JSONDictionary
        if usingAuth {
            do {
                data = try await loadRecommendations(continuation: continuation, authenticated: true)
            } catch {
                if await refreshAuthenticatedSessionIfPossible() {
                    do {
                        data = try await loadRecommendations(continuation: continuation, authenticated: true)
                    } catch {
                        note = "Your saved YouTube session expired. Showing public picks instead."
                        data = try await loadRecommendations(continuation: continuation, authenticated: false)
                    }
                } else {
                    note = "Your saved YouTube session expired. Showing public picks instead."
                    data = try await loadRecommendations(continuation: continuation, authenticated: false)
                }
            }
        } else {
            data = try await loadRecommendations(continuation: continuation, authenticated: false)
        }

        var items = extractVideoItems(from: data)
        var token = extractContinuationToken(from: data)

        if items.isEmpty, continuation == nil {
            let guide = try await api.guide(authenticated: false)
            let browseIDs = extractBrowseIDsFromGuide(from: guide, limit: 4)
            var fallbackItems: [VideoItem] = []
            var seen = Set<String>()

            for browseID in browseIDs {
                guard let browseData = try? await api.browse(browseID: browseID, authenticated: false) else {
                    continue
                }

                for item in extractVideoItems(from: browseData) where seen.insert(item.id).inserted {
                    fallbackItems.append(item)
                }
            }

            if !fallbackItems.isEmpty {
                note = usingAuth
                    ? "History is off on YouTube. Showing Explore picks instead."
                    : "You’re logged out. Showing Explore picks instead."
                items = fallbackItems
                token = nil
            }
        }

        items = await mergeStoredProgress(into: items)
        return RecommendationsResponse(items: items, continuation: token, note: note)
    }

    func fetchSearch(query: String, continuation: String? = nil) async throws -> SearchResponse {
        let usingAuth = await authManager.currentMaterial() != nil

        let data: JSONDictionary
        if usingAuth {
            do {
                data = try await api.search(query: continuation == nil ? query : nil, continuation: continuation, authenticated: true)
            } catch {
                if await refreshAuthenticatedSessionIfPossible() {
                    do {
                        data = try await api.search(query: continuation == nil ? query : nil, continuation: continuation, authenticated: true)
                    } catch {
                        data = try await api.search(query: continuation == nil ? query : nil, continuation: continuation, authenticated: false)
                    }
                } else {
                    data = try await api.search(query: continuation == nil ? query : nil, continuation: continuation, authenticated: false)
                }
            }
        } else {
            data = try await api.search(query: continuation == nil ? query : nil, continuation: continuation, authenticated: false)
        }

        return SearchResponse(
            items: await mergeStoredProgress(into: extractVideoItems(from: data)),
            continuation: extractContinuationToken(from: data),
            query: query
        )
    }

    func fetchWatchHistory(query: String? = nil, continuation: String? = nil) async throws -> WatchHistoryResponse {
        _ = try await requireAuthenticatedMaterial()
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try await api.browse(
            browseID: continuation == nil ? "FEhistory" : nil,
            query: continuation == nil ? trimmedQuery : nil,
            continuation: continuation,
            authenticated: true
        )

        return WatchHistoryResponse(
            items: await mergeStoredProgress(into: extractHistoryItems(from: data)),
            continuation: extractContinuationToken(from: data)
        )
    }

    func removeWatchHistoryVideo(id videoID: String) async throws -> WatchHistoryMutationResponse {
        _ = try await requireAuthenticatedMaterial()
        guard let record = try await findWatchHistoryRecord(videoID: videoID) else {
            throw BackendClientError(message: "Couldn’t find that video in your YouTube watch history.")
        }
        guard let command = record.deleteCommand else {
            throw BackendClientError(message: "YouTube did not expose a remove-history action for that video.")
        }

        _ = try await api.dispatch(command: command)
        try await verifyWatchHistoryRemoval(videoID: videoID)
        return WatchHistoryMutationResponse(
            success: true,
            removedVideoIDs: [videoID],
            removedCount: 1
        )
    }

    func trimWatchHistory(range: WatchHistoryTrimRange) async throws -> WatchHistoryMutationResponse {
        _ = try await requireAuthenticatedMaterial()

        var removedVideoIDs: [String] = []
        var continuation: String?
        var remainingPages = 8
        let cutoff = Date().addingTimeInterval(-timeInterval(for: range))
        let localProgressByID = await watchHistoryStore.allProgressEntries()

        while remainingPages > 0 {
            let data = try await api.browse(
                browseID: continuation == nil ? "FEhistory" : nil,
                continuation: continuation,
                authenticated: true
            )
            let records = extractHistoryVideoRecords(from: data)
            if records.isEmpty {
                break
            }

            var pageRemovedAny = false
            for record in records {
                guard shouldTrimHistoryRecord(
                    record,
                    range: range,
                    cutoff: cutoff,
                    localProgressByID: localProgressByID
                ) else {
                    continue
                }
                guard let command = record.deleteCommand else { continue }

                _ = try await api.dispatch(command: command)
                try await verifyWatchHistoryRemoval(videoID: record.item.id)
                removedVideoIDs.append(record.item.id)
                pageRemovedAny = true
            }

            continuation = extractContinuationToken(from: data)
            remainingPages -= 1

            if continuation == nil || pageRemovedAny == false {
                break
            }
        }

        return WatchHistoryMutationResponse(
            success: true,
            removedVideoIDs: removedVideoIDs,
            removedCount: removedVideoIDs.count
        )
    }

    func fetchSearchSuggestions(query: String) async throws -> SearchSuggestionsResponse {
        SearchSuggestionsResponse(query: query, suggestions: try await api.searchSuggestions(query: query))
    }

    func fetchChannelAvatar(channelID: String) async throws -> ChannelAvatarResponse {
        if let cached = channelAvatarCache[channelID] {
            return ChannelAvatarResponse(channelId: channelID, avatarUrl: cached)
        }

        let browseData = try await api.browse(browseID: channelID, authenticated: false)
        let url = extractChannelAvatarURL(from: browseData)
        channelAvatarCache[channelID] = url
        return ChannelAvatarResponse(channelId: channelID, avatarUrl: url)
    }

    func fetchChannelPage(
        channelID: String,
        tab: ChannelTabKind,
        searchQuery: String? = nil
    ) async throws -> ChannelPageResponse {
        let data = try await loadChannelInitialData(
            channelID: channelID,
            tab: tab,
            searchQuery: searchQuery
        )

        guard let header = extractChannelHeader(from: data) else {
            throw BackendClientError(message: "Couldn’t load that channel page.")
        }

        let controls = extractChannelBrowseControls(from: data)
        let subscriptionCommands = extractChannelSubscriptionCommands(from: data)

        return ChannelPageResponse(
            header: header,
            tabs: extractChannelTabs(from: data),
            selectedTab: extractSelectedChannelTab(from: data) ?? tab,
            items: await mergeStoredProgress(into: extractChannelContentItems(from: data)),
            sortOptions: controls.sortOptions,
            filterOptions: controls.filterOptions,
            continuation: extractChannelContentContinuationToken(from: data),
            searchQuery: searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
            subscription: extractChannelSubscriptionState(from: data, header: header),
            subscriptionCommands: subscriptionCommands
        )
    }

    func fetchChannelContinuation(token: String) async throws -> ChannelPageContinuationResponse {
        let data = try await loadBrowseContinuationData(token: token)
        let controls = extractChannelBrowseControls(from: data)
        return ChannelPageContinuationResponse(
            items: await mergeStoredProgress(into: extractChannelContentItems(from: data)),
            sortOptions: controls.sortOptions,
            filterOptions: controls.filterOptions,
            continuation: extractChannelContentContinuationToken(from: data)
        )
    }

    func fetchChannelAbout(token: String) async throws -> ChannelAboutResponse {
        let data = try await loadBrowseContinuationData(token: token)
        guard let about = extractChannelAbout(from: data) else {
            throw BackendClientError(message: "Couldn’t load this channel’s details.")
        }
        return ChannelAboutResponse(about: about)
    }

    func updateChannelSubscription(
        channelID: String,
        subscribed: Bool,
        commands: [String: InnerTubeCommand?]
    ) async throws -> SubscriptionResponse {
        _ = try await requireAuthenticatedMaterial()

        let commandKey = subscribed ? "subscribe" : "unsubscribe"
        guard let command = commands[commandKey] ?? nil else {
            throw BackendClientError(message: "This channel subscription action is unavailable right now.")
        }

        _ = try await api.dispatch(command: command)
        let latestData = try await loadChannelInitialData(
            channelID: channelID,
            tab: .videos,
            searchQuery: nil,
            authenticated: true
        )
        let latestHeader = extractChannelHeader(from: latestData)
        return SubscriptionResponse(
            subscription: extractChannelSubscriptionState(from: latestData, header: latestHeader)
        )
    }

    func fetchVideo(id videoID: String) async throws -> VideoPlayback {
        let usingAuth = await authManager.currentMaterial() != nil

        if usingAuth {
            do {
                return try await loadVideoPlaybackWithTimeout(videoID: videoID, authenticated: true)
            } catch {
                if await refreshAuthenticatedSessionIfPossible() {
                    do {
                        return try await loadVideoPlaybackWithTimeout(videoID: videoID, authenticated: true)
                    } catch {}
                }
            }
        }

        return try await loadVideoPlaybackWithTimeout(videoID: videoID, authenticated: false)
    }

    func fetchInlinePlayback(id videoID: String) async throws -> InlinePlaybackPayload {
        if let cached = inlinePlaybackCache[videoID] {
            return cached
        }

        let usingAuth = await authManager.currentMaterial() != nil

        if usingAuth {
            do {
                return try await buildInlinePlayback(videoID: videoID, authenticated: true)
            } catch {
                if await refreshAuthenticatedSessionIfPossible() {
                    do {
                        return try await buildInlinePlayback(videoID: videoID, authenticated: true)
                    } catch {}
                }
            }
        }

        return try await buildInlinePlayback(videoID: videoID, authenticated: false)
    }

    func recordPlaybackProgress(
        videoID: String,
        currentTime: Double,
        duration: Double?,
        didFinish: Bool
    ) async throws -> PlaybackProgressMutationResponse {
        let progress = await watchHistoryStore.recordProgress(
            videoID: videoID,
            currentTime: currentTime,
            duration: duration,
            didFinish: didFinish
        )

        if AppSettings.shared.sendWatchProgressToYouTube, await authManager.currentMaterial() != nil {
            await syncYouTubeWatchProgress(
                videoID: videoID,
                currentTime: currentTime,
                duration: duration,
                didFinish: didFinish
            )
        } else {
            activeWatchSyncSessions.removeValue(forKey: videoID)
        }

        await MainActor.run {
            NotificationCenter.default.post(
                name: .playbackProgressDidUpdate,
                object: nil,
                userInfo: [
                    "videoID": videoID,
                    "progress": progress,
                ]
            )
        }

        return PlaybackProgressMutationResponse(progress: progress)
    }

    func fetchComments(id videoID: String, continuation: String? = nil) async throws -> CommentsResponse {
        if let continuation {
            let usingAuth = await authManager.currentMaterial() != nil
            do {
                let data = try await api.next(continuation: continuation, authenticated: usingAuth)
                return CommentsResponse(
                    comments: extractComments(from: data),
                    commentCountText: nil,
                    continuation: extractCommentsToken(from: data)
                )
            } catch {
                if usingAuth {
                    await invalidateAuthenticatedSession()
                }
                throw error
            }
        }

        let usingAuth = await authManager.currentMaterial() != nil
        if usingAuth {
            do {
                return try await buildCommentsResponse(videoID: videoID, authenticated: true)
            } catch {
                await invalidateAuthenticatedSession()
            }
        }

        return try await buildCommentsResponse(videoID: videoID, authenticated: false)
    }

    func fetchLiveChat(
        id videoID: String,
        mode: LiveChatMode,
        continuation: String? = nil,
        isReplay: Bool = false,
        replayOffsetMs: Int? = nil
    ) async throws -> LiveChatResponse {
        let usingAuth = await authManager.currentMaterial() != nil

        if usingAuth {
            do {
                return try await buildLiveChatResponse(
                    videoID: videoID,
                    mode: mode,
                    continuation: continuation,
                    isReplay: isReplay,
                    replayOffsetMs: replayOffsetMs,
                    authenticated: true
                )
            } catch {
                // Live chat endpoints can fail for stream-specific reasons. Fall through publicly.
            }
        }

        return try await buildLiveChatResponse(
            videoID: videoID,
            mode: mode,
            continuation: continuation,
            isReplay: isReplay,
            replayOffsetMs: replayOffsetMs,
            authenticated: false
        )
    }

    func sendLiveChatMessage(
        message: String,
        params: String,
        clientIdPrefix: String?
    ) async throws {
        _ = try await requireAuthenticatedMaterial()

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw BackendClientError(message: "Write a message before sending it.")
        }

        _ = try await api.sendLiveChatMessage(
            message: trimmed,
            params: params,
            clientMessageId: makeLiveChatClientMessageID(prefix: clientIdPrefix)
        )
    }

    func fetchTranscript(track: SubtitleTrack?) async throws -> TranscriptResponse {
        guard let track else {
            return TranscriptResponse(track: nil, segments: [])
        }

        guard let url = transcriptURL(for: track.url) else {
            throw BackendClientError(message: "This transcript track has an invalid URL.")
        }

        let text = try await api.fetchText(from: url, authenticated: false)
        let segments = parseTranscriptSegments(from: text)
        return TranscriptResponse(track: track, segments: segments)
    }

    func fetchPlaylistOptions(id videoID: String) async throws -> PlaylistOptionsResponse {
        let (watchData, _) = try await loadWatchDataForActions(videoID: videoID)
        let clientCommand = extractWatchPageSaveCommand(from: watchData)
        guard let clientCommand else {
            throw BackendClientError(message: "Playlist save options are unavailable for this video.")
        }
        let sheet = try await api.dispatch(command: clientCommand)
        return PlaylistOptionsResponse(options: extractPlaylistOptions(from: sheet))
    }

    func fetchPlaylistLibrary(continuation: String? = nil) async throws -> PlaylistLibraryResponse {
        _ = try await requireAuthenticatedMaterial()
        do {
            let data = try await api.browse(
                browseID: continuation == nil ? "FEplaylist_aggregation" : nil,
                continuation: continuation,
                authenticated: true
            )
            return PlaylistLibraryResponse(
                items: extractPlaylistSummaries(from: data),
                continuation: extractContinuationToken(from: data)
            )
        } catch {
            if await refreshAuthenticatedSessionIfPossible() {
                let data = try await api.browse(
                    browseID: continuation == nil ? "FEplaylist_aggregation" : nil,
                    continuation: continuation,
                    authenticated: true
                )
                return PlaylistLibraryResponse(
                    items: extractPlaylistSummaries(from: data),
                    continuation: extractContinuationToken(from: data)
                )
            }
            throw BackendClientError(message: "Your YouTube session expired. SwiftTube is reconnecting using the last browser session if possible.")
        }
    }

    func fetchPlaylistFeed(id playlistID: String, continuation: String? = nil) async throws -> PlaylistFeed {
        _ = try await requireAuthenticatedMaterial()
        let browseID = playlistID.hasPrefix("VL") ? playlistID : "VL\(playlistID)"
        do {
            let data = try await api.browse(
                browseID: continuation == nil ? browseID : nil,
                continuation: continuation,
                authenticated: true
            )
            return await mergeStoredProgress(into: extractPlaylistFeed(from: data, playlistID: playlistID.removingPrefix("VL")))
        } catch {
            if await refreshAuthenticatedSessionIfPossible() {
                let data = try await api.browse(
                    browseID: continuation == nil ? browseID : nil,
                    continuation: continuation,
                    authenticated: true
                )
                return await mergeStoredProgress(into: extractPlaylistFeed(from: data, playlistID: playlistID.removingPrefix("VL")))
            }
            throw BackendClientError(message: "Your YouTube session expired. SwiftTube is reconnecting using the last browser session if possible.")
        }
    }

    func fetchRelatedVideos(id videoID: String, continuation: String? = nil) async throws -> RecommendationsResponse {
        let usingAuth = await authManager.currentMaterial() != nil
        if usingAuth {
            do {
                return try await buildRelatedResponse(videoID: videoID, continuation: continuation, authenticated: true)
            } catch {
                if await refreshAuthenticatedSessionIfPossible() {
                    do {
                        return try await buildRelatedResponse(videoID: videoID, continuation: continuation, authenticated: true)
                    } catch {}
                }
            }
        }

        return try await buildRelatedResponse(videoID: videoID, continuation: continuation, authenticated: false)
    }

    func updateSubscription(id videoID: String, subscribed: Bool) async throws -> SubscriptionResponse {
        let (watchData, metadata) = try await loadWatchDataForActions(videoID: videoID)
        guard let state = extractSubscriptionState(from: watchData, metadata: metadata), state.enabled else {
            throw BackendClientError(message: "Subscribe controls are unavailable for this video.")
        }

        let commands = extractSubscriptionCommands(from: watchData)
        let command = subscribed ? (commands["subscribe"] ?? nil) : (commands["unsubscribe"] ?? nil)
        guard let command else {
            throw BackendClientError(message: "This subscription action is unavailable right now.")
        }

        var latestWatchData = watchData
        if state.subscribed != subscribed {
            _ = try await api.dispatch(command: command)
            latestWatchData = try await api.next(videoID: videoID, authenticated: true)
        }

        let latestMetadata = extractWatchMetadata(from: latestWatchData)
        return SubscriptionResponse(
            subscription: extractSubscriptionState(from: latestWatchData, metadata: latestMetadata)
        )
    }

    func updateRating(id videoID: String, action: String) async throws -> RatingResponse {
        let normalizedAction = action.lowercased()
        guard ["like", "dislike", "none"].contains(normalizedAction) else {
            throw BackendClientError(message: "Rating action must be one of: like, dislike, none.")
        }

        let (watchData, _) = try await loadWatchDataForActions(videoID: videoID)
        guard let rating = extractRatingState(from: watchData) else {
            throw BackendClientError(message: "Like and dislike controls are unavailable for this video.")
        }

        let commands = extractRatingCommands(from: watchData)
        let commandKey: String = {
            switch normalizedAction {
            case "like":
                return rating.status == "LIKE" ? "removeLike" : "like"
            case "dislike":
                return rating.status == "DISLIKE" ? "removeDislike" : "dislike"
            default:
                return rating.status == "LIKE" ? "removeLike" : "removeDislike"
            }
        }()

        guard let command = commands[commandKey] ?? nil else {
            throw BackendClientError(message: "This rating action is unavailable right now.")
        }

        var latestWatchData = watchData
        let alreadyApplied = (normalizedAction == "like" && rating.status == "LIKE")
            || (normalizedAction == "dislike" && rating.status == "DISLIKE")
            || (normalizedAction == "none" && rating.status == "INDIFFERENT")
        if !alreadyApplied {
            _ = try await api.dispatch(command: command)
            latestWatchData = try await api.next(videoID: videoID, authenticated: true)
        }

        return RatingResponse(rating: extractRatingState(from: latestWatchData))
    }

    func updateWatchLater(id videoID: String, saved: Bool) async throws -> WatchLaterResponse {
        let (watchData, _) = try await loadWatchDataForActions(videoID: videoID)
        let sheet = try await loadPlaylistSheet(from: watchData)
        var options = extractPlaylistOptions(from: sheet)
        let commands = extractPlaylistOptionCommands(from: sheet)
        guard var option = findPlaylistOption(in: options, playlistID: "WL") else {
            throw BackendClientError(message: "Watch Later is unavailable for this account.")
        }

        if option.saved != saved {
            let command = commands["WL"]?[saved ? "add" : "remove"] ?? nil
            guard let command else {
                throw BackendClientError(message: "Watch Later mutation is unavailable right now.")
            }

            _ = try await api.dispatch(command: command)
            let latestWatchData = try await api.next(videoID: videoID, authenticated: true)
            options = extractPlaylistOptions(from: try await loadPlaylistSheet(from: latestWatchData))
            option = findPlaylistOption(in: options, playlistID: "WL") ?? option
        }

        return WatchLaterResponse(watchLater: option)
    }

    func updatePlaylist(id videoID: String, playlistID: String, saved: Bool) async throws -> PlaylistMutationResponse {
        let (watchData, _) = try await loadWatchDataForActions(videoID: videoID)
        let sheet = try await loadPlaylistSheet(from: watchData)
        var options = extractPlaylistOptions(from: sheet)
        let commands = extractPlaylistOptionCommands(from: sheet)
        guard var option = findPlaylistOption(in: options, playlistID: playlistID) else {
            throw BackendClientError(message: "That playlist was not found in your YouTube library.")
        }

        if option.saved != saved {
            let command = commands[playlistID]?[saved ? "add" : "remove"] ?? nil
            guard let command else {
                throw BackendClientError(message: "That playlist mutation is unavailable right now.")
            }

            _ = try await api.dispatch(command: command)
            let latestWatchData = try await api.next(videoID: videoID, authenticated: true)
            options = extractPlaylistOptions(from: try await loadPlaylistSheet(from: latestWatchData))
            option = findPlaylistOption(in: options, playlistID: playlistID) ?? option
        }

        return PlaylistMutationResponse(playlist: option)
    }

    func removePlaylistItem(playlistID: String, setVideoID: String) async throws -> PlaylistItemMutationResponse {
        _ = try await requireAuthenticatedMaterial()
        let browseData = try await api.browse(browseID: playlistBrowseID(for: playlistID), authenticated: true)
        guard let command = extractPlaylistItemActionCommand(from: browseData, setVideoID: setVideoID, action: "ACTION_REMOVE_VIDEO") else {
            throw BackendClientError(message: "That playlist item can’t be removed right now.")
        }
        _ = try await api.dispatch(command: command)
        return PlaylistItemMutationResponse(success: true)
    }

    func reorderPlaylistItem(playlistID: String, setVideoID: String, position: String) async throws -> PlaylistItemMutationResponse {
        _ = try await requireAuthenticatedMaterial()
        let action: String
        switch position.lowercased() {
        case "top":
            action = "ACTION_MOVE_VIDEO_AFTER"
        case "bottom":
            action = "ACTION_MOVE_VIDEO_BEFORE"
        default:
            throw BackendClientError(message: "Playlist reorder position must be top or bottom.")
        }

        let browseData = try await api.browse(browseID: playlistBrowseID(for: playlistID), authenticated: true)
        guard let command = extractPlaylistItemActionCommand(from: browseData, setVideoID: setVideoID, action: action) else {
            throw BackendClientError(message: "That playlist item can’t be reordered right now.")
        }
        _ = try await api.dispatch(command: command)
        return PlaylistItemMutationResponse(success: true)
    }

    private func buildCommentsResponse(videoID: String, authenticated: Bool) async throws -> CommentsResponse {
        let watchData = try await api.next(videoID: videoID, authenticated: authenticated)
        let metadata = extractWatchMetadata(from: watchData)
        let commentsToken = extractCommentsToken(from: watchData)

        var comments: [CommentItem] = []
        var nextToken = commentsToken
        if let commentsToken {
            do {
                let response = try await api.next(continuation: commentsToken, authenticated: authenticated)
                comments = extractComments(from: response)
                nextToken = extractCommentsToken(from: response)
            } catch {
                comments = []
            }
        }

        return CommentsResponse(
            comments: comments,
            commentCountText: metadata["commentCountText"] ?? nil,
            continuation: nextToken
        )
    }

    private func buildLiveChatResponse(
        videoID: String,
        mode: LiveChatMode,
        continuation: String?,
        isReplay: Bool,
        replayOffsetMs: Int?,
        authenticated: Bool
    ) async throws -> LiveChatResponse {
        if let continuation, continuation.isEmpty == false {
            let data = try await api.liveChat(
                continuation: continuation,
                isReplay: isReplay,
                replayOffsetMs: nil,
                authenticated: authenticated
            )
            return extractLiveChatResponse(from: data, requestedMode: mode)
        }

        let watchData = try await api.next(videoID: videoID, authenticated: authenticated)
        guard let session = extractLiveChatSession(from: watchData) else {
            throw BackendClientError(message: "Live chat isn’t available for this video.")
        }

        let bootstrapContinuation = session.initialContinuation ?? preferredLiveChatContinuation(for: mode, in: session)
        guard let bootstrapContinuation, bootstrapContinuation.isEmpty == false else {
            throw BackendClientError(message: "Live chat isn’t available for this mode right now.")
        }

        let bootstrapData = try await api.liveChat(
            continuation: bootstrapContinuation,
            isReplay: session.isReplay,
            replayOffsetMs: session.isReplay ? replayOffsetMs : nil,
            authenticated: authenticated
        )
        let bootstrapResponse = extractLiveChatResponse(from: bootstrapData, requestedMode: mode)
        let activeMode = extractLiveChatMode(from: bootstrapData) ?? session.defaultMode
        if activeMode == mode {
            return bootstrapResponse
        }

        guard let modeContinuation = extractLiveChatModeContinuations(from: bootstrapData)[mode],
              modeContinuation.isEmpty == false else {
            throw BackendClientError(message: "Live chat isn’t available for this mode right now.")
        }

        let modeData = try await api.liveChat(
            continuation: modeContinuation,
            isReplay: session.isReplay,
            replayOffsetMs: nil,
            authenticated: authenticated
        )
        return extractLiveChatResponse(from: modeData, requestedMode: mode)
    }

    private func makeLiveChatClientMessageID(prefix: String?) -> String {
        let base = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-")
        let resolvedPrefix: String
        if let prefix, prefix.isEmpty == false {
            resolvedPrefix = prefix
        } else {
            resolvedPrefix = String((0..<26).map { _ in base.randomElement() ?? "a" })
        }

        let counter = Int(Date().timeIntervalSince1970 * 1000) % Int.max
        return "\(resolvedPrefix)\(counter)"
    }

    private func buildRelatedResponse(
        videoID: String,
        continuation: String?,
        authenticated: Bool
    ) async throws -> RecommendationsResponse {
        let data: JSONDictionary
        if let continuation {
            data = try await api.next(continuation: continuation, authenticated: authenticated)
        } else {
            data = try await api.next(videoID: videoID, authenticated: authenticated)
        }

        return RecommendationsResponse(
            items: await mergeStoredProgress(into: extractRelatedVideos(from: data, currentVideoID: videoID)),
            continuation: extractRelatedContinuationToken(from: data),
            note: nil
        )
    }

    private func buildInlinePlayback(videoID: String, authenticated: Bool) async throws -> InlinePlaybackPayload {
        var playerResponses: [JSONDictionary] = []
        var issueSources: [PlaybackIssueSource] = []
        var streams: [StreamInfo] = []

        func appendPlayerResponse(_ data: JSONDictionary, profile: InnerTubeClientProfile) {
            let parsedStreams = parseStreams(from: data, defaultHeaders: api.streamRequestHeaders(for: profile))
            playerResponses.append(data)
            issueSources.append(PlaybackIssueSource(data: data, streams: parsedStreams))
            streams = mergeStreams(streams, parsedStreams)
        }

        let playerData = try await api.player(videoID: videoID, profile: .webParentTools, authenticated: authenticated)
        appendPlayerResponse(playerData, profile: .webParentTools)

        var selection = inlinePlaybackSelection(from: streams)
        if selection == nil {
            for profile in [InnerTubeClientProfile.web, .mweb] {
                guard let data = try? await api.player(videoID: videoID, profile: profile, authenticated: authenticated) else {
                    continue
                }
                appendPlayerResponse(data, profile: profile)
                selection = inlinePlaybackSelection(from: streams)
                if selection != nil { break }
            }
        }

        var watchPageHTML: String?
        if selection == nil {
            watchPageHTML = try? await api.watchPage(videoID: videoID, authenticated: authenticated)
            if let watchPagePlayerData = watchPageHTML.flatMap(extractInitialPlayerResponse) {
                appendPlayerResponse(watchPagePlayerData, profile: .web)
                selection = inlinePlaybackSelection(from: streams)
            }
        }

        let playbackTags = deduplicatedVideoTags(playerResponses.flatMap { extractVideoTags(from: $0) })
        let accessIssue = resolveVideoAccessIssue(from: issueSources, fallbackTags: playbackTags)
        if let accessIssue {
            throw BackendClientError(message: accessIssue.title)
        }

        let details = playerResponses.compactMap { $0["videoDetails"] as? JSONDictionary }
        let liveBroadcastDetails = playerResponses.compactMap {
            (($0["microformat"] as? JSONDictionary)?["playerMicroformatRenderer"] as? JSONDictionary)?["liveBroadcastDetails"] as? JSONDictionary
        }
        let isLive = liveBroadcastDetails.contains { ($0["isLiveNow"] as? Bool) == true }
        let isUpcoming = details.contains { ($0["isUpcoming"] as? Bool) == true }
        guard !isLive, !isUpcoming else {
            throw BackendClientError(message: "Inline playback is not available for this video.")
        }

        guard let selection else {
            throw BackendClientError(message: "No low-cost inline stream found.")
        }

        let duration = details.lazy.compactMap { metadataDurationText(from: $0) }.first
        let durationSeconds = parseDurationSeconds(from: duration)
        let storyboard = playerResponses.lazy.compactMap { extractStoryboard(from: $0) }.first
        if let tracking = extractWatchTracking(from: watchPageHTML, fallbackDuration: durationSeconds) {
            trackingCache[videoID] = tracking
        } else {
            Task {
                await self.cacheInlineWatchTracking(
                    videoID: videoID,
                    authenticated: authenticated,
                    fallbackDuration: durationSeconds
                )
            }
        }
        let progress = mergeVideoProgress(
            remote: nil,
            local: await watchHistoryStore.progressEntry(for: videoID),
            durationSeconds: durationSeconds
        )

        let payload = InlinePlaybackPayload(
            id: videoID,
            title: details.lazy.compactMap { $0["title"] as? String }.first,
            durationText: duration,
            durationSeconds: durationSeconds,
            videoStream: selection.video,
            audioStream: selection.audio,
            storyboard: storyboard,
            progress: progress
        )
        inlinePlaybackCache[videoID] = payload
        return payload
    }

    private func cacheInlineWatchTracking(
        videoID: String,
        authenticated: Bool,
        fallbackDuration: Double?
    ) async {
        guard trackingCache[videoID] == nil else { return }
        guard let html = try? await api.watchPage(videoID: videoID, authenticated: authenticated),
              let tracking = extractWatchTracking(from: html, fallbackDuration: fallbackDuration) else {
            return
        }
        trackingCache[videoID] = tracking
    }

    private func buildVideoPlayback(
        videoID: String,
        authenticated: Bool,
        allowYTDLPFallback: Bool = true
    ) async throws -> VideoPlayback {
        async let watchTask = api.next(videoID: videoID, authenticated: authenticated)
        async let webSafariWatchPageTask = api.watchPage(videoID: videoID, profile: .webSafari, authenticated: false)
        async let androidPlayerTask = api.player(videoID: videoID, profile: .android, authenticated: false)
        async let iosPlayerTask = api.player(videoID: videoID, profile: .ios, authenticated: false)

        let watchData = try await watchTask
        let webSafariWatchPageHTML = try? await webSafariWatchPageTask
        let webSafariPlayerData = webSafariWatchPageHTML.flatMap(extractInitialPlayerResponse) ?? [:]
        let webSafariVisitorData = webSafariWatchPageHTML.flatMap(extractVisitorData)
        let androidVRPlayerData: JSONDictionary
        if let webSafariVisitorData {
            androidVRPlayerData = (try? await api.player(
                videoID: videoID,
                profile: .androidVR,
                visitorData: webSafariVisitorData,
                authenticated: false
            )) ?? [:]
        } else {
            androidVRPlayerData = [:]
        }
        let androidPlayerData = (try? await androidPlayerTask) ?? [:]
        let iosPlayerData = (try? await iosPlayerTask) ?? [:]

        let metadata = extractWatchMetadata(from: watchData)
        let liveBroadcastDetails = [webSafariPlayerData, androidPlayerData, iosPlayerData].compactMap {
            (($0["microformat"] as? JSONDictionary)?["playerMicroformatRenderer"] as? JSONDictionary)?["liveBroadcastDetails"] as? JSONDictionary
        }

        let androidVRStreams = parseStreams(from: androidVRPlayerData, defaultHeaders: api.streamRequestHeaders(for: .androidVR))
        var androidStreams = parseStreams(from: androidPlayerData, defaultHeaders: api.streamRequestHeaders(for: .android))
        var iosStreams = parseStreams(from: iosPlayerData, defaultHeaders: api.streamRequestHeaders(for: .ios))
        let webSafariStreams = parseStreams(from: webSafariPlayerData, defaultHeaders: api.streamRequestHeaders(for: .webSafari))
        var hlsManifestSources = webSafariStreams
        if liveBroadcastDetails.isEmpty == false {
            hlsManifestSources += iosStreams
        }
        var hlsVariantStreams = await loadHLSVariantStreams(from: hlsManifestSources)
        let fallbackAudioLanguage = preferredNativeAudioLanguage(in: androidVRStreams + androidStreams + iosStreams)
            ?? automaticCaptionLanguage(from: webSafariPlayerData)
        var playerAPIStreams = sortedYouTubePlaybackStreams(applyingFallbackAudioLanguage(
            fallbackAudioLanguage,
            to: mergeYouTubeFormatStreams(
            hlsVariantStreams,
            androidVRStreams,
            androidStreams,
            iosStreams.filter { $0.formatId != "hls-manifest" }
            )
        ))

        if playerAPIStreams.count <= 1 {
            if let retriedAndroidData = try? await api.player(videoID: videoID, profile: .android, authenticated: false) {
                androidStreams = parseStreams(from: retriedAndroidData, defaultHeaders: api.streamRequestHeaders(for: .android))
            }
            if let retriedIOSData = try? await api.player(videoID: videoID, profile: .ios, authenticated: false) {
                iosStreams = parseStreams(from: retriedIOSData, defaultHeaders: api.streamRequestHeaders(for: .ios))
            }
            if hlsVariantStreams.isEmpty {
                hlsManifestSources = webSafariStreams
                if liveBroadcastDetails.isEmpty == false {
                    hlsManifestSources += iosStreams
                }
                hlsVariantStreams = await loadHLSVariantStreams(from: hlsManifestSources)
            }
            playerAPIStreams = sortedYouTubePlaybackStreams(applyingFallbackAudioLanguage(
                fallbackAudioLanguage,
                to: mergeYouTubeFormatStreams(
                hlsVariantStreams,
                androidVRStreams,
                androidStreams,
                iosStreams.filter { $0.formatId != "hls-manifest" }
                )
            ))
        }
        let playerStreams = playerAPIStreams
        let playerSubtitles = deduplicatedSubtitles(
            extractSubtitles(from: androidVRPlayerData)
                + extractSubtitles(from: androidPlayerData)
                + extractSubtitles(from: iosPlayerData)
        )
        let playbackTags = deduplicatedVideoTags(
            extractVideoTags(from: watchData),
            extractVideoTags(from: webSafariPlayerData),
            extractVideoTags(from: androidVRPlayerData),
            extractVideoTags(from: androidPlayerData),
            extractVideoTags(from: iosPlayerData)
        )
        let accessIssue = resolveVideoAccessIssue(
            from: [
                PlaybackIssueSource(data: androidVRPlayerData, streams: androidVRStreams),
                PlaybackIssueSource(data: webSafariPlayerData, streams: mergeStreams(webSafariStreams, hlsVariantStreams)),
                PlaybackIssueSource(data: androidPlayerData, streams: androidStreams),
                PlaybackIssueSource(data: iosPlayerData, streams: mergeStreams(iosStreams, hlsVariantStreams)),
            ],
            fallbackTags: playbackTags
        )

        let androidDetails = androidPlayerData["videoDetails"] as? JSONDictionary
        let iosDetails = iosPlayerData["videoDetails"] as? JSONDictionary
        let webSafariDetails = webSafariPlayerData["videoDetails"] as? JSONDictionary
        let isLive = liveBroadcastDetails.contains { ($0["isLiveNow"] as? Bool) == true }
        let isUpcoming = [webSafariDetails, androidDetails, iosDetails].contains { ($0?["isUpcoming"] as? Bool) == true }
        let liveManifestMetadata = isLive
            ? await loadLiveManifestMetadata(from: iosPlayerData.isEmpty ? androidPlayerData : iosPlayerData, api: api)
            : nil
        let livePlaybackStreams = hlsVariantStreams.isEmpty
            ? sortedYouTubePlaybackStreams(mergeYouTubeFormatStreams(
                androidStreams.filter { $0.formatId != "hls-manifest" && $0.formatId != "dash-manifest" },
                iosStreams.filter { $0.formatId != "hls-manifest" && $0.formatId != "dash-manifest" }
            ))
            : hlsVariantStreams
        let nativePlaybackStreams = isLive ? livePlaybackStreams : playerStreams
        let nativePlaybackBundle = buildPlaybackBundle(
            streams: nativePlaybackStreams,
            subtitles: playerSubtitles,
            preferHLSManifest: isLive
        )
        PlaybackDebugLogger.log(
            "native youtube extraction video=\(videoID) streams=\(nativePlaybackStreams.count) subtitles=\(playerSubtitles.count) best=\(nativePlaybackBundle.bestStream?.formatId ?? "nil")"
        )

        let preferredYTDLPPlayback: YTDLPPlaybackData?
        let shouldProbeYTDLP = allowYTDLPFallback
            && AppSettings.shared.ytDLPDependencySource != .nativeSwift
            && (!isLive || nativePlaybackBundle.bestStream == nil)
        if shouldProbeYTDLP {
            let publicPlayback = try? await cachedYTDLPPlayback(
                videoID: videoID,
                cookieFileURL: nil,
                cacheScope: "public"
            )
            if let publicPlayback, publicPlayback.streams.isEmpty == false {
                preferredYTDLPPlayback = publicPlayback
            } else if authenticated {
                preferredYTDLPPlayback = try? await cachedYTDLPPlayback(
                    videoID: videoID,
                    cookieFileURL: await authManager.playbackCookieFileURL(),
                    cacheScope: "auth"
                )
            } else {
                preferredYTDLPPlayback = nil
            }
        } else {
            preferredYTDLPPlayback = nil
        }

        let useYTDLPStreams = (preferredYTDLPPlayback?.streams.isEmpty == false)
            && !(isLive && nativePlaybackBundle.bestStream != nil)
        let resolvedStreams = (useYTDLPStreams ? preferredYTDLPPlayback?.streams : nil)
            ?? nativePlaybackStreams

        let playbackBundle: PlaybackBundle = {
            if let preferredYTDLPPlayback, useYTDLPStreams {
                return buildPlaybackBundle(
                    streams: preferredYTDLPPlayback.streams,
                    subtitles: playerSubtitles + preferredYTDLPPlayback.subtitles,
                    preferHLSManifest: isLive
                )
            }
            return nativePlaybackBundle
        }()
        let bestStream = pickBestStream(in: resolvedStreams)
        if resolvedStreams.isEmpty, accessIssue == nil {
            throw BackendClientError(message: "No playable streams found")
        }

        let title: String? = metadata["title"]
            ?? preferredYTDLPPlayback?.title
            ?? (webSafariDetails?["title"] as? String)
            ?? (androidDetails?["title"] as? String)
            ?? (iosDetails?["title"] as? String)
        let duration = metadata["durationText"]
            ?? preferredYTDLPPlayback?.durationText
            ?? metadataDurationText(from: webSafariDetails)
            ?? metadataDurationText(from: androidDetails)
            ?? metadataDurationText(from: iosDetails)
        let durationSeconds = parseDurationSeconds(from: duration)
        if authenticated {
            Task {
                await self.cacheInlineWatchTracking(
                    videoID: videoID,
                    authenticated: authenticated,
                    fallbackDuration: durationSeconds
                )
            }
        }
        let liveChatSession = extractLiveChatSession(from: watchData)
        let progress = mergeVideoProgress(
            remote: nil,
            local: await watchHistoryStore.progressEntry(for: videoID),
            durationSeconds: durationSeconds
        )
        let relatedItems = await mergeStoredProgress(into: extractRelatedVideos(from: watchData, currentVideoID: videoID))
        let storyboard = extractStoryboard(from: androidPlayerData, liveTimeline: liveManifestMetadata?.storyboardTimeline)
            ?? extractStoryboard(from: iosPlayerData, liveTimeline: liveManifestMetadata?.storyboardTimeline)

        return VideoPlayback(
            id: videoID,
            title: title,
            channel: metadata["channel"] ?? nil,
            channelId: metadata["channelId"] ?? nil,
            channelAvatarUrl: metadata["channelAvatarUrl"] ?? nil,
            subscriberCountText: metadata["subscriberCountText"] ?? nil,
            viewCountText: metadata["viewCountText"] ?? nil,
            publishedTimeText: metadata["publishedTimeText"] ?? nil,
            publishedDateText: metadata["publishedDateText"] ?? nil,
            likeCountText: metadata["likeCountText"] ?? nil,
            durationText: duration,
            description: metadata["description"] ?? nil,
            commentCountText: metadata["commentCountText"] ?? nil,
            streams: resolvedStreams,
            recommendations: relatedItems,
            comments: [],
            playbackStrategy: playbackBundle.playbackStrategy,
            preferredManifestStream: playbackBundle.preferredManifestStream,
            preferredMuxedStream: playbackBundle.preferredMuxedStream ?? bestStream,
            preferredVideoStream: playbackBundle.preferredVideoStream,
            preferredAudioStream: playbackBundle.preferredAudioStream,
            bestStreamUrl: (playbackBundle.bestStream ?? bestStream)?.url,
            bestStream: playbackBundle.bestStream ?? bestStream,
            subtitles: deduplicatedSubtitles(playbackBundle.subtitles),
            storyboard: storyboard,
            sponsorSegments: [],
            progress: progress,
            resumeStartTimeSeconds: progress?.bestResumeSeconds,
            subscription: extractSubscriptionState(from: watchData, metadata: metadata),
            rating: extractRatingState(from: watchData),
            watchLater: nil,
            playlistSaveEnabled: extractWatchPageSaveCommand(from: watchData) != nil,
            recommendationsContinuation: extractRelatedContinuationToken(from: watchData),
            tags: playbackTags,
            accessIssue: accessIssue,
            isLive: isLive,
            isUpcoming: isUpcoming,
            liveWindowDurationSeconds: liveManifestMetadata?.windowDurationSeconds,
            liveChat: liveChatSession
        )
    }

    private func loadVideoPlaybackWithTimeout(videoID: String, authenticated: Bool) async throws -> VideoPlayback {
        try await withTimeout(
            seconds: videoPlaybackTimeoutSeconds,
            timeoutMessage: "Video loading timed out."
        ) {
            try await self.buildVideoPlayback(videoID: videoID, authenticated: authenticated)
        }
    }

    private func cachedYTDLPPlayback(videoID: String, cookieFileURL: URL?, cacheScope: String) async throws -> YTDLPPlaybackData? {
        let settings = AppSettings.shared
        let cacheKey = [
            cacheScope,
            settings.ytDLPDependencySource.rawValue,
            settings.ytDLPDependencySource == .custom ? settings.ytDLPCustomPath : "",
            videoID
        ].joined(separator: ":")
        if let cached = playbackCache[cacheKey] {
            return cached
        }

        let playback = try await extractYTDLPPlayback(
            videoID: videoID,
            cookieFileURL: cookieFileURL,
            timeout: ytDLPPlaybackTimeoutSeconds
        )
        if let playback, playback.streams.isEmpty == false {
            playbackCache[cacheKey] = playback
        }
        return playback
    }

    private func streamURLResolver(from watchPageHTML: String?) async -> YouTubeStreamURLResolver? {
        guard
            let watchPageHTML,
            let playerScriptURL = extractPlayerJavaScriptURL(from: watchPageHTML)
        else {
            return nil
        }

        let cacheKey = playerScriptURL.absoluteString
        if let cached = playerScriptResolverCache[cacheKey] {
            return cached
        }

        guard
            let script = try? await api.textResource(url: playerScriptURL),
            let resolver = YouTubeStreamURLResolver(javaScript: script)
        else {
            return nil
        }

        playerScriptResolverCache[cacheKey] = resolver
        return resolver
    }

    private func loadHLSVariantStreams(from streams: [StreamInfo]) async -> [StreamInfo] {
        let manifests = streams.filter { $0.formatId == "hls-manifest" }
        guard manifests.isEmpty == false else { return [] }

        var variants: [StreamInfo] = []
        for manifest in manifests {
            guard
                let url = URL(string: manifest.url),
                let manifestText = try? await api.textResource(url: url),
                manifestText.isEmpty == false
            else {
                continue
            }
            variants = mergeStreams(variants, parseHLSVariantStreams(from: manifestText, manifest: manifest))
        }
        return variants
    }

    private func loadPlaylistSheet(from watchData: JSONDictionary) async throws -> JSONDictionary {
        guard let saveCommand = extractWatchPageSaveCommand(from: watchData) else {
            throw BackendClientError(message: "Playlist save options are unavailable for this video.")
        }
        return try await api.dispatch(command: saveCommand)
    }

    private func loadWatchDataForActions(videoID: String) async throws -> (JSONDictionary, [String: String]) {
        _ = try await requireAuthenticatedMaterial()
        let watchData = try await api.next(videoID: videoID, authenticated: true)
        return (watchData, extractWatchMetadata(from: watchData))
    }

    private func loadChannelInitialData(
        channelID: String,
        tab: ChannelTabKind,
        searchQuery: String?
    ) async throws -> JSONDictionary {
        let usingAuth = await authManager.currentMaterial() != nil

        if usingAuth {
            do {
                return try await loadChannelInitialData(
                    channelID: channelID,
                    tab: tab,
                    searchQuery: searchQuery,
                    authenticated: true
                )
            } catch {
                // Channel browse requests can fail for reasons unrelated to auth.
            }
        }

        return try await loadChannelInitialData(
            channelID: channelID,
            tab: tab,
            searchQuery: searchQuery,
            authenticated: false
        )
    }

    private func loadChannelInitialData(
        channelID: String,
        tab: ChannelTabKind,
        searchQuery: String?,
        authenticated: Bool
    ) async throws -> JSONDictionary {
        switch tab {
        case .videos:
            return try await api.browse(
                browseID: channelID,
                params: "EgZ2aWRlb3PyBgQKAjoA",
                authenticated: authenticated
            )
        case .shorts:
            return try await api.browse(
                browseID: channelID,
                params: "EgZzaG9ydHPyBgUKA5oBAA==",
                authenticated: authenticated
            )
        case .live:
            return try await api.browse(
                browseID: channelID,
                params: "EgdzdHJlYW1z8gYECgJ6AA==",
                authenticated: authenticated
            )
        case .playlists:
            return try await api.browse(
                browseID: channelID,
                params: "EglwbGF5bGlzdHPyBgQKAkIA",
                authenticated: authenticated
            )
        case .posts:
            return try await api.browse(
                browseID: channelID,
                params: "EgVwb3N0c_IGBAoCSgA=",
                authenticated: authenticated
            )
        case .about:
            return try await api.browse(
                browseID: channelID,
                params: "EgZ2aWRlb3PyBgQKAjoA",
                authenticated: authenticated
            )
        case .search:
            let trimmedQuery = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard trimmedQuery.isEmpty == false else {
                throw BackendClientError(message: "Enter something to search this channel.")
            }
            return try await api.browse(
                browseID: channelID,
                query: trimmedQuery,
                params: "EgZzZWFyY2jyBgQKAloA",
                authenticated: authenticated
            )
        }
    }

    private func loadBrowseContinuationData(token: String) async throws -> JSONDictionary {
        let usingAuth = await authManager.currentMaterial() != nil

        if usingAuth {
            do {
                return try await api.browse(continuation: token, authenticated: true)
            } catch {
                // Continuation browse failures should not implicitly sign the user out.
            }
        }

        return try await api.browse(continuation: token, authenticated: false)
    }

    private func requireAuthenticatedMaterial() async throws -> AuthMaterial {
        if let material = await authManager.currentMaterial() {
            return material
        }

        throw BackendClientError(message: "Sign in to YouTube to use this action.")
    }

    private func invalidateAuthenticatedSession() async {
        _ = try? await authManager.clear(preserveBrowserChoice: false)
        await publishAuthSessionChange()
    }

    private func publishAuthSessionChange() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .authSessionDidChange, object: nil)
        }
    }

    private func refreshAuthenticatedSessionIfPossible() async -> Bool {
        return false
    }

    private func refreshSignedInAccountProfile() async {
        let profile = await currentSignedInAccountProfile()

        try? await authManager.updateAccountProfile(
            displayName: profile.displayName,
            email: profile.email,
            handle: profile.handle,
            avatarURL: profile.avatarURL
        )
    }

    private func currentSignedInAccountProfile() async -> SignedInAccountProfile {
        await signedInAccountProfile(using: api)
    }

    private func unavailableExtractorMessage(for mode: ExtractorSpeedTestMode) -> String? {
        switch mode {
        case .nativeSwift:
            return nil
        case .systemYTDLP:
            return SwiftTubeDependencyManager.detectSystemYTDLP() == nil ? "Not found" : nil
        case .provisionedYTDLP:
            return SwiftTubeDependencyManager.detectProvisionedYTDLP() == nil ? "Not installed" : nil
        }
    }

    private func loadRecommendations(continuation: String?, authenticated: Bool) async throws -> JSONDictionary {
        if let continuation {
            return try await api.browse(continuation: continuation, authenticated: authenticated)
        }
        return try await api.browse(browseID: "FEwhat_to_watch", authenticated: authenticated)
    }

    private func findWatchHistoryRecord(videoID: String) async throws -> HistoryVideoRecord? {
        var continuation: String?
        var remainingPages = 8

        while remainingPages > 0 {
            let data = try await api.browse(
                browseID: continuation == nil ? "FEhistory" : nil,
                continuation: continuation,
                authenticated: true
            )
            if let record = extractHistoryVideoRecords(from: data).first(where: { $0.item.id == videoID }) {
                return record
            }

            continuation = extractContinuationToken(from: data)
            guard continuation != nil else { return nil }
            remainingPages -= 1
        }

        return nil
    }

    private func shouldTrimHistoryRecord(
        _ record: HistoryVideoRecord,
        range: WatchHistoryTrimRange,
        cutoff: Date,
        localProgressByID: [String: VideoProgress]
    ) -> Bool {
        if let lastUpdatedAt = localProgressByID[record.item.id]?.lastUpdatedAt {
            return lastUpdatedAt >= cutoff
        }

        let sectionTitle = (record.sectionTitle ?? "").lowercased()
        switch range {
        case .hour:
            // YouTube history does not expose an exact watched-at timestamp per row.
            // For non-local items we fall back to the newest part of the Today bucket.
            return sectionTitle == "today" && record.indexInSection < 12
        case .day:
            return sectionTitle == "today" || sectionTitle == "yesterday"
        case .week:
            return recentHistorySectionTitles().contains(sectionTitle)
        }
    }

    private func recentHistorySectionTitles() -> Set<String> {
        var labels: Set<String> = ["today", "yesterday"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let calendar = Calendar.current
        for offset in 2...6 {
            if let date = calendar.date(byAdding: .day, value: -offset, to: Date()) {
                labels.insert(formatter.weekdaySymbols[calendar.component(.weekday, from: date) - 1].lowercased())
            }
        }

        return labels
    }

    private func timeInterval(for range: WatchHistoryTrimRange) -> TimeInterval {
        switch range {
        case .hour:
            return 60 * 60
        case .day:
            return 60 * 60 * 24
        case .week:
            return 60 * 60 * 24 * 7
        }
    }

    private func verifyWatchHistoryRemoval(videoID: String) async throws {
        for attempt in 0..<3 {
            if try await findWatchHistoryRecord(videoID: videoID) == nil {
                return
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        throw BackendClientError(message: "YouTube accepted the request, but the video is still present in watch history after refresh.")
    }

    private func mergeStoredProgress(into items: [VideoItem]) async -> [VideoItem] {
        guard !items.isEmpty else { return items }

        let localProgress = await watchHistoryStore.progressEntries(for: items.map(\.id))
        return items.map { item in
            var updated = item
            let durationSeconds = parseDurationSeconds(from: item.durationText) ?? item.progress?.durationSeconds
            updated.progress = mergeVideoProgress(
                remote: item.progress,
                local: localProgress[item.id],
                durationSeconds: durationSeconds
            )
            return updated
        }
    }

    private func mergeStoredProgress(into items: [ChannelContentItem]) async -> [ChannelContentItem] {
        let videos = items.compactMap { item -> VideoItem? in
            if case .video(let video) = item {
                return video
            }
            return nil
        }
        guard !videos.isEmpty else { return items }

        let mergedVideos = await mergeStoredProgress(into: videos)
        var mergedByID: [String: VideoItem] = [:]
        for video in mergedVideos {
            mergedByID[video.id] = video
        }

        return items.map { item in
            guard case .video(let video) = item,
                  let merged = mergedByID[video.id] else {
                return item
            }
            return .video(merged)
        }
    }

    private func mergeStoredProgress(into feed: PlaylistFeed) async -> PlaylistFeed {
        feed.with(items: await mergeStoredProgress(into: feed.items))
    }

    private func syncYouTubeWatchProgress(
        videoID: String,
        currentTime: Double,
        duration: Double?,
        didFinish: Bool
    ) async {
        guard let tracking = trackingCache[videoID] else { return }

        var session = activeWatchSyncSessions[videoID] ?? ActiveWatchSyncSession(
            videoID: videoID,
            cpn: randomPlaybackNonce(),
            tracking: tracking,
            lastObservedSecond: nil,
            pendingSegmentStartSecond: nil,
            pendingSegmentEndSecond: nil
        )

        let durationSeconds = duration ?? tracking.durationSeconds
        let normalizedCurrentTime: Double
        if let durationSeconds, durationSeconds > 0 {
            normalizedCurrentTime = min(max(currentTime, 0), durationSeconds)
        } else {
            normalizedCurrentTime = max(currentTime, 0)
        }
        let conservativeCurrentTime = max(floor(normalizedCurrentTime), 0)
        let watchtimeCurrentTime: Double
        if let durationSeconds, durationSeconds > 1 {
            watchtimeCurrentTime = min(conservativeCurrentTime, max(floor(durationSeconds - 1), 0))
        } else {
            watchtimeCurrentTime = conservativeCurrentTime
        }

        if !session.sentInitialPlayback, conservativeCurrentTime >= 1 {
            if let playbackURL = trackedURL(
                from: tracking.playbackURL,
                cpn: session.cpn,
                currentTime: conservativeCurrentTime,
                startTime: nil,
                endTime: nil
            ) {
                try? await api.sendTrackingEvent(url: playbackURL, videoID: videoID, authenticated: true)
                session.sentInitialPlayback = true
            }
        }

        let continuityThresholdSeconds = 4.5
        let flushChunkThresholdSeconds = 10.0
        let initialFlushThresholdSeconds = 3.0

        if let lastObservedSecond = session.lastObservedSecond {
            let delta = watchtimeCurrentTime - lastObservedSecond

            if delta >= 0.75, delta <= continuityThresholdSeconds {
                if session.pendingSegmentStartSecond == nil {
                    session.pendingSegmentStartSecond = lastObservedSecond
                }
                session.pendingSegmentEndSecond = watchtimeCurrentTime
            } else if delta > continuityThresholdSeconds || delta < -0.75 {
                if let watchtimeURL = pendingWatchtimeURL(
                    session: session,
                    currentTime: lastObservedSecond,
                    threshold: initialFlushThresholdSeconds
                ) {
                    try? await api.sendTrackingEvent(url: watchtimeURL, videoID: videoID, authenticated: true)
                }
                session.pendingSegmentStartSecond = watchtimeCurrentTime
                session.pendingSegmentEndSecond = watchtimeCurrentTime
            }
        } else {
            session.pendingSegmentStartSecond = watchtimeCurrentTime
            session.pendingSegmentEndSecond = watchtimeCurrentTime
        }

        let pendingSegmentDuration = max(
            (session.pendingSegmentEndSecond ?? watchtimeCurrentTime) - (session.pendingSegmentStartSecond ?? watchtimeCurrentTime),
            0
        )
        let shouldFlushPendingSegment = didFinish
            || isEffectivelyFinished(currentTime: watchtimeCurrentTime, duration: durationSeconds)
            || pendingSegmentDuration >= flushChunkThresholdSeconds
            || ((session.pendingSegmentStartSecond ?? watchtimeCurrentTime) <= 0 && pendingSegmentDuration >= initialFlushThresholdSeconds)

        if shouldFlushPendingSegment,
           let watchtimeURL = pendingWatchtimeURL(
                session: session,
                currentTime: didFinish
                    ? (durationSeconds.map { max(floor($0 - 1), 0) } ?? watchtimeCurrentTime)
                    : watchtimeCurrentTime,
                threshold: 1.5
           ) {
            try? await api.sendTrackingEvent(url: watchtimeURL, videoID: videoID, authenticated: true)
            session.pendingSegmentStartSecond = watchtimeCurrentTime
            session.pendingSegmentEndSecond = watchtimeCurrentTime
        }

        session.lastObservedSecond = watchtimeCurrentTime

        if didFinish || isEffectivelyFinished(currentTime: watchtimeCurrentTime, duration: durationSeconds) {
            activeWatchSyncSessions.removeValue(forKey: videoID)
        } else {
            activeWatchSyncSessions[videoID] = session
        }
    }

    private func pendingWatchtimeURL(
        session: ActiveWatchSyncSession,
        currentTime: Double,
        threshold: Double
    ) -> URL? {
        guard let startTime = session.pendingSegmentStartSecond else { return nil }
        let endTime = max(session.pendingSegmentEndSecond ?? currentTime, currentTime)
        guard endTime - startTime >= threshold else { return nil }
        return trackedURL(
            from: session.tracking.watchtimeURL,
            cpn: session.cpn,
            currentTime: endTime,
            startTime: startTime,
            endTime: endTime
        )
    }

    private func playlistBrowseID(for playlistID: String) -> String {
        playlistID.hasPrefix("VL") ? playlistID : "VL\(playlistID)"
    }
}

private struct InlinePlaybackSelection {
    let video: StreamInfo
    let audio: StreamInfo?
}

private func inlinePlaybackSelection(from streams: [StreamInfo]) -> InlinePlaybackSelection? {
    let playableMuxed = streams
        .filter { stream in
            stream.hasVideo
                && stream.hasAudio
                && stream.streamKind != "manifest"
                && URL(string: stream.url) != nil
        }
        .sorted { inlineStreamScore($0) < inlineStreamScore($1) }

    if let muxed = playableMuxed.first {
        return InlinePlaybackSelection(video: muxed, audio: nil)
    }

    let audio = streams
        .filter { $0.hasAudio && !$0.hasVideo && URL(string: $0.url) != nil }
        .sorted { inlineAudioScore($0) < inlineAudioScore($1) }
        .first

    guard let audio else { return nil }

    let adaptiveVideo = streams
        .filter { stream in
            stream.hasVideo
                && !stream.hasAudio
                && stream.streamKind != "manifest"
                && URL(string: stream.url) != nil
                && !inlineHeadersConflict(video: stream, audio: audio)
        }
        .sorted { inlineStreamScore($0) < inlineStreamScore($1) }
        .first

    guard let adaptiveVideo else { return nil }
    return InlinePlaybackSelection(video: adaptiveVideo, audio: audio)
}

private func inlineStreamScore(_ stream: StreamInfo) -> (Int, Int, Int, Int) {
    let height = stream.height ?? 0
    let targetHeightPenalty = height == 0 ? 2000 : abs(height - 360)
    let tooLargePenalty = height > 480 ? 1000 + height : 0
    return (
        tooLargePenalty,
        targetHeightPenalty,
        stream.bitrate ?? Int.max,
        stream.fps ?? 0
    )
}

private func inlineAudioScore(_ stream: StreamInfo) -> (Int, Int, Int) {
    (
        stream.bitrate ?? Int.max,
        stream.audioChannels ?? 2,
        codecScore(stream.audioCodec)
    )
}

private func inlineHeadersConflict(video: StreamInfo, audio: StreamInfo) -> Bool {
    let videoClient = video.httpHeaders?["X-YouTube-Client-Name"]
    let audioClient = audio.httpHeaders?["X-YouTube-Client-Name"]
    guard let videoClient, let audioClient else { return false }
    return videoClient != audioClient
}

private struct PlaybackBundle {
    let streams: [StreamInfo]
    let preferredManifestStream: StreamInfo?
    let preferredMuxedStream: StreamInfo?
    let preferredVideoStream: StreamInfo?
    let preferredAudioStream: StreamInfo?
    let subtitles: [SubtitleTrack]

    var playbackStrategy: String {
        if preferredManifestStream != nil {
            return "manifest"
        }
        if let preferredVideoStream, let preferredAudioStream {
            let muxedHeight = preferredMuxedStream?.height ?? 0
            if (preferredVideoStream.height ?? 0) > muxedHeight || preferredMuxedStream == nil {
                _ = preferredAudioStream
                return "mpv"
            }
        }
        return "direct"
    }

    var bestStream: StreamInfo? {
        preferredManifestStream ?? preferredMuxedStream ?? preferredVideoStream
    }
}

private struct PlaybackIssueSource {
    let data: JSONDictionary
    let streams: [StreamInfo]
}

private struct YTDLPPlaybackData {
    let title: String?
    let durationText: String?
    let streams: [StreamInfo]
    let subtitles: [SubtitleTrack]
}

private struct LiveManifestMetadata {
    let windowDurationSeconds: Double?
    let storyboardTimeline: LiveStoryboardTimeline?
}

private let ytDLPPlaybackTimeoutSeconds: TimeInterval = 12
private let extractorSpeedTestModeTimeoutSeconds: TimeInterval = 24
private let videoPlaybackTimeoutSeconds: TimeInterval = 24

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    timeoutMessage: String,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            let duration = max(seconds, 0)
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            throw BackendClientError(message: timeoutMessage)
        }

        guard let result = try await group.next() else {
            group.cancelAll()
            throw BackendClientError(message: timeoutMessage)
        }

        group.cancelAll()
        return result
    }
}

private func resolveVideoAccessIssue(
    from sources: [PlaybackIssueSource],
    fallbackTags: [VideoTag]
) -> VideoAccessIssue? {
    let hasPlayableSource = sources.contains { source in
        let bundle = buildPlaybackBundle(streams: source.streams, subtitles: [])
        return bundle.bestStream != nil || pickBestStream(in: source.streams) != nil
    }

    guard !hasPlayableSource else { return nil }

    for source in sources {
        if let issue = extractVideoAccessIssue(from: source.data, fallbackTags: []) {
            return issue
        }
    }

    return extractVideoAccessIssue(from: nil, fallbackTags: fallbackTags)
}

private func extractYTDLPPlayback(
    videoID: String,
    cookieFileURL: URL?,
    source explicitSource: YTDLPDependencySource? = nil,
    timeout: TimeInterval? = nil
) async throws -> YTDLPPlaybackData? {
    let settings = AppSettings.shared
    let source = explicitSource ?? settings.ytDLPDependencySource
    guard source != .nativeSwift else {
        return nil
    }

    let ytDLPPath: URL
    do {
        if let explicitSource {
            guard let explicitPath = try SwiftTubeDependencyManager.resolvedYTDLPExecutable(
                source: explicitSource,
                customPath: settings.ytDLPCustomPath
            ) else {
                return nil
            }
            ytDLPPath = explicitPath
        } else {
            ytDLPPath = try YTDLPTool.resolvePath()
        }
    } catch {
        return nil
    }

    var arguments = [
        "-J",
        "--skip-download",
        "--quiet",
        "--no-warnings",
        "--ignore-no-formats-error",
        "https://www.youtube.com/watch?v=\(videoID)",
    ]

    if let cookieFile = cookieFileURL {
        arguments.insert(contentsOf: ["--cookies", cookieFile.path], at: 0)
    }

    let startDate = Date()
    let result = try await ProcessRunner.run(
        executableURL: ytDLPPath,
        arguments: arguments,
        timeout: timeout,
        timeoutMessage: "yt-dlp timed out while extracting playback data."
    )
    let elapsed = Date().timeIntervalSince(startDate)
    guard result.exitCode == 0, let data = result.output.data(using: .utf8) else { return nil }

    guard let payload = try JSONSerialization.jsonObject(with: data) as? JSONDictionary else {
        return nil
    }

    let streams = parseYTDLPStreams(from: payload)
    let subtitles = parseYTDLPSubtitles(from: payload)
    PlaybackDebugLogger.log(
        "yt-dlp extraction video=\(videoID) source=\(source.rawValue) elapsed=\(String(format: "%.3f", elapsed)) streams=\(streams.count) subtitles=\(subtitles.count)"
    )

    return YTDLPPlaybackData(
        title: payload["title"] as? String,
        durationText: formatDuration(seconds: payload["duration"]),
        streams: streams,
        subtitles: subtitles
    )
}

private func metadataDurationText(from details: JSONDictionary?) -> String? {
    guard let lengthString = details?["lengthSeconds"] as? String, let seconds = Int(lengthString) else {
        return nil
    }
    return formatDuration(seconds: seconds)
}

private func formatDuration(seconds: Any?) -> String? {
    let totalSeconds: Int
    if let seconds = seconds as? Int {
        totalSeconds = seconds
    } else if let seconds = seconds as? Double {
        totalSeconds = Int(seconds)
    } else {
        return nil
    }

    guard totalSeconds > 0 else { return nil }
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let secondsPart = totalSeconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secondsPart)
    }
    return String(format: "%d:%02d", minutes, secondsPart)
}

private func mergeStreams(_ groups: [StreamInfo]...) -> [StreamInfo] {
    var mergedByKey: [String: StreamInfo] = [:]
    var order: [String] = []

    for group in groups {
        for stream in group {
            let key = "\(stream.url)|\(stream.formatId ?? "")|\(stream.streamKind)"
            if let existing = mergedByKey[key] {
                if existing.httpHeaders == nil, stream.httpHeaders != nil {
                    mergedByKey[key] = stream
                }
            } else {
                mergedByKey[key] = stream
                order.append(key)
            }
        }
    }

    return order.compactMap { mergedByKey[$0] }
}

private func mergeYouTubeFormatStreams(_ groups: [StreamInfo]...) -> [StreamInfo] {
    var mergedByKey: [String: StreamInfo] = [:]
    var order: [String] = []

    for group in groups {
        for stream in group {
            let key = youtubeFormatMergeKey(for: stream)
            if let existing = mergedByKey[key] {
                if preferredYouTubeFormatStream(existing: existing, candidate: stream) == stream {
                    mergedByKey[key] = stream
                }
            } else {
                mergedByKey[key] = stream
                order.append(key)
            }
        }
    }

    return order.compactMap { mergedByKey[$0] }
}

private func sortedYouTubePlaybackStreams(_ streams: [StreamInfo]) -> [StreamInfo] {
    streams.sorted { lhs, rhs in
        youtubeStreamOrderKey(for: lhs).lexicographicallyPrecedes(youtubeStreamOrderKey(for: rhs))
    }
}

private func applyingFallbackAudioLanguage(_ language: String?, to streams: [StreamInfo]) -> [StreamInfo] {
    guard let language, language.isEmpty == false else { return streams }
    let preservesMuxedNilLanguage = preservesMuxedNilAudioLanguage(in: streams, fallbackLanguage: language)
    return streams.map { stream in
        guard stream.hasAudio, stream.audioLanguage == nil else { return stream }
        if preservesMuxedNilLanguage && stream.hasVideo {
            return stream
        }
        return StreamInfo(
            url: stream.url,
            formatId: stream.formatId,
            mimeType: stream.mimeType,
            qualityLabel: stream.qualityLabel,
            httpHeaders: stream.httpHeaders,
            bitrate: stream.bitrate,
            width: stream.width,
            height: stream.height,
            fps: stream.fps,
            audioChannels: stream.audioChannels,
            audioCodec: stream.audioCodec,
            videoCodec: stream.videoCodec,
            container: stream.container,
            hasAudio: stream.hasAudio,
            hasVideo: stream.hasVideo,
            isAdaptive: stream.isAdaptive,
            streamKind: stream.streamKind,
            audioLanguage: language,
            audioTrackKind: stream.audioTrackKind,
            audioLanguagePreference: stream.audioLanguagePreference,
            audioIsDefault: stream.audioIsDefault
        )
    }
}

private func preservesMuxedNilAudioLanguage(in streams: [StreamInfo], fallbackLanguage: String) -> Bool {
    let manifestAudioStreams = streams.filter {
        $0.streamKind == "manifest" && $0.hasAudio && $0.hasVideo
    }
    guard manifestAudioStreams.isEmpty == false else { return false }
    if fallbackLanguage.lowercased().hasPrefix("en"),
       manifestAudioStreams.contains(where: { $0.audioLanguage != nil }),
       manifestAudioStreams.contains(where: { $0.audioLanguage == nil && isNonStandardHLSHeight($0.height) }) {
        return true
    }
    return manifestAudioStreams.allSatisfy { $0.audioTrackKind == "original" }
}

private func isNonStandardHLSHeight(_ height: Int?) -> Bool {
    guard let height else { return false }
    return [144, 240, 360, 480, 720, 1080].contains(height) == false
}

private func preferredNativeAudioLanguage(in streams: [StreamInfo]) -> String? {
    streams
        .filter { $0.hasAudio && $0.audioLanguage != nil }
        .sorted { lhs, rhs in
            nativeAudioLanguageScore(lhs).lexicographicallyPrecedes(nativeAudioLanguageScore(rhs))
        }
        .last?
        .audioLanguage
}

private func nativeAudioLanguageScore(_ stream: StreamInfo) -> [Int] {
    let audioScore = adaptiveAudioScore(stream)
    return [
        stream.audioIsDefault == true ? 4 : 0,
        stream.audioTrackKind == "original" ? 2 : 0,
        audioScore.0,
        audioScore.1,
        audioScore.2,
        audioScore.3,
    ]
}

private func automaticCaptionLanguage(from playerData: JSONDictionary) -> String? {
    let captionTracks = ((((playerData["captions"] as? JSONDictionary)?["playerCaptionsTracklistRenderer"] as? JSONDictionary)?["captionTracks"] as? [Any])) ?? []
    for item in captionTracks {
        guard let item = item as? JSONDictionary,
              (item["kind"] as? String) == "asr",
              let language = item["languageCode"] as? String,
              language.isEmpty == false else {
            continue
        }
        return language
    }
    return nil
}

private func youtubeStreamOrderKey(for stream: StreamInfo) -> [Int] {
    if stream.hasAudio && stream.hasVideo == false {
        return [
            0,
            youtubeAudioFormatOrder(for: stream),
            numericFormatID(stream.formatId) ?? 0,
        ]
    }

    if stream.streamKind == "manifest" {
        return [
            1,
            stream.height ?? 0,
            0,
            stream.fps ?? 0,
            stream.audioTrackKind == "original" ? 1 : 0,
            stream.bitrate ?? 0,
            numericFormatID(stream.formatId) ?? 0,
            hlsVariantIndex(stream.formatId) ?? 0,
        ]
    }

    return [
        1,
        stream.height ?? 0,
        youtubeVideoFormatKindOrder(for: stream),
        stream.fps ?? 0,
        stream.bitrate ?? 0,
        numericFormatID(stream.formatId) ?? 0,
    ]
}

private func youtubeAudioFormatOrder(for stream: StreamInfo) -> Int {
    switch stream.formatId {
    case "139":
        return 0
    case "249":
        return 1
    case "256":
        return 2
    case "140":
        return 3
    case "251":
        return 4
    case "258":
        return 5
    default:
        return 100 + (stream.bitrate ?? 0)
    }
}

private func youtubeVideoFormatKindOrder(for stream: StreamInfo) -> Int {
    if stream.streamKind == "manifest" {
        return 0
    }
    if stream.hasAudio && stream.hasVideo {
        return 2
    }
    if stream.videoCodec?.hasPrefix("avc1") == true {
        return 1
    }
    if stream.videoCodec?.hasPrefix("vp9.2") == true || stream.videoCodec?.hasPrefix("vp09.2") == true {
        return 4
    }
    if stream.videoCodec?.hasPrefix("vp9") == true || stream.videoCodec?.hasPrefix("vp09") == true {
        return 3
    }
    if stream.videoCodec?.hasPrefix("av01") == true {
        return 5
    }
    return 6
}

private func numericFormatID(_ formatID: String?) -> Int? {
    guard let formatID else { return nil }
    return Int(formatID.split(separator: "-").first.map(String.init) ?? formatID)
}

private func hlsVariantIndex(_ formatID: String?) -> Int? {
    guard let suffix = formatID?.split(separator: "-", maxSplits: 1).dropFirst().first else {
        return nil
    }
    return Int(suffix)
}

private func youtubeFormatMergeKey(for stream: StreamInfo) -> String {
    if let formatId = stream.formatId, formatId.isEmpty == false {
        return "format:\(formatId)"
    }
    return "url:\(stream.url)|\(stream.streamKind)"
}

private func preferredYouTubeFormatStream(existing: StreamInfo, candidate: StreamInfo) -> StreamInfo {
    if existing.httpHeaders == nil, candidate.httpHeaders != nil {
        return candidate
    }
    if existing.formatId == nil, candidate.formatId != nil {
        return candidate
    }
    if existing.height == nil, candidate.height != nil {
        return candidate
    }
    return existing
}

private func deduplicatedSubtitles(_ subtitles: [SubtitleTrack]) -> [SubtitleTrack] {
    var mergedByKey: [String: SubtitleTrack] = [:]
    var order: [String] = []

    for subtitle in subtitles {
        let key = normalizedSubtitleKey(for: subtitle)
        if let existing = mergedByKey[key] {
            if preferredSubtitleTrack(existing: existing, candidate: subtitle) == subtitle {
                mergedByKey[key] = subtitle
            }
        } else {
            mergedByKey[key] = subtitle
            order.append(key)
        }
    }

    return order.compactMap { mergedByKey[$0] }
}

private func normalizedSubtitleKey(for subtitle: SubtitleTrack) -> String {
    let language = subtitle.language
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "_", with: "-")
        .replacingOccurrences(of: "-orig", with: "")
        .split(separator: "-")
        .first
        .map(String.init) ?? "unknown"
    let label = subtitle.label
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "(auto-generated)", with: "")
        .replacingOccurrences(of: "(auto)", with: "")
        .replacingOccurrences(of: "(en-orig)", with: "")
        .replacingOccurrences(of: "(en)", with: "")
        .replacingOccurrences(of: "(orig)", with: "")
        .replacingOccurrences(of: "(original)", with: "")
        .replacingOccurrences(of: "  ", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let kind = subtitle.isAutoGenerated ? "auto" : "manual"
    return "\(kind)|\(language)|\(label)"
}

private func preferredSubtitleTrack(existing: SubtitleTrack, candidate: SubtitleTrack) -> SubtitleTrack {
    if existing.isAutoGenerated != candidate.isAutoGenerated {
        return existing.isAutoGenerated ? candidate : existing
    }

    let existingLabelLength = existing.label.trimmingCharacters(in: .whitespacesAndNewlines).count
    let candidateLabelLength = candidate.label.trimmingCharacters(in: .whitespacesAndNewlines).count
    if candidateLabelLength != existingLabelLength {
        return candidateLabelLength < existingLabelLength ? candidate : existing
    }

    return candidate.url < existing.url ? candidate : existing
}

private func buildPlaybackBundle(
    streams: [StreamInfo],
    subtitles: [SubtitleTrack],
    preferHLSManifest: Bool = false
) -> PlaybackBundle {
    PlaybackBundle(
        streams: streams,
        preferredManifestStream: preferHLSManifest ? bestManifestStream(in: streams, preferHLS: true) : nil,
        preferredMuxedStream: bestMuxedStream(in: streams),
        preferredVideoStream: bestVideoStream(in: streams),
        preferredAudioStream: bestAudioStream(in: streams),
        subtitles: subtitles
    )
}

private func shouldPreferNativePlayback(bundle: PlaybackBundle, streams: [StreamInfo]) -> Bool {
    if bundle.preferredManifestStream != nil {
        return true
    }

    if bundle.preferredVideoStream != nil, bundle.preferredAudioStream != nil {
        return true
    }

    let muxedCandidates = streams.filter {
        $0.hasAudio && $0.hasVideo
            && (($0.container ?? "").hasPrefix("mp4") || ($0.container ?? "").hasPrefix("mov"))
            && !isManifestURL($0.url)
    }
    return muxedCandidates.count > 1 && bundle.preferredMuxedStream != nil
}

private func bestManifestStream(in streams: [StreamInfo], preferHLS: Bool = false) -> StreamInfo? {
    streams
        .filter { $0.streamKind == "manifest" && $0.hasVideo }
        .max(by: {
            manifestStreamScore($0, preferHLS: preferHLS)
                .lexicographicallyPrecedes(manifestStreamScore($1, preferHLS: preferHLS))
        })
}

private func bestMuxedStream(in streams: [StreamInfo]) -> StreamInfo? {
    streams
        .filter {
            $0.hasAudio && $0.hasVideo
                && (($0.container ?? "").hasPrefix("mp4") || ($0.container ?? "").hasPrefix("mov"))
                && !isManifestURL($0.url)
        }
        .max(by: { streamScore($0) < streamScore($1) })
}

private func bestVideoStream(in streams: [StreamInfo]) -> StreamInfo? {
    streams
        .filter {
            $0.hasVideo
                && !$0.hasAudio
                && ($0.container ?? "").hasPrefix("mp4")
                && isSupportedVideoCodec($0.videoCodec)
        }
        .max(by: { streamScore($0) < streamScore($1) })
}

private func bestAudioStream(in streams: [StreamInfo]) -> StreamInfo? {
    streams
        .filter {
            $0.hasAudio
                && !$0.hasVideo
                && (($0.container ?? "").hasPrefix("m4a") || ($0.container ?? "").hasPrefix("mp4"))
        }
        .max(by: { adaptiveAudioScore($0) < adaptiveAudioScore($1) })
}

private func pickBestStream(in streams: [StreamInfo]) -> StreamInfo? {
    guard !streams.isEmpty else { return nil }
    let candidates = streams.filter { $0.hasAudio && $0.hasVideo }
    let pool = !candidates.isEmpty ? candidates : (streams.filter { $0.hasVideo }.isEmpty ? streams : streams.filter { $0.hasVideo })
    return pool.max(by: { simpleStreamScore($0) < simpleStreamScore($1) })
}

private func parseStreams(
    from playerResponse: JSONDictionary,
    defaultHeaders: [String: String]? = nil,
    urlResolver: YouTubeStreamURLResolver? = nil
) -> [StreamInfo] {
    guard let streaming = playerResponse["streamingData"] as? JSONDictionary else {
        return []
    }

    var results: [StreamInfo] = []

    if let hlsManifestURL = streaming["hlsManifestUrl"] as? String, hlsManifestURL.isEmpty == false {
        results.append(
            StreamInfo(
                url: hlsManifestURL,
                formatId: "hls-manifest",
                mimeType: "application/x-mpegURL",
                qualityLabel: nil,
                httpHeaders: defaultHeaders,
                bitrate: nil,
                width: nil,
                height: nil,
                fps: nil,
                audioChannels: nil,
                audioCodec: nil,
                videoCodec: nil,
                container: "m3u8",
                hasAudio: true,
                hasVideo: true,
                isAdaptive: false,
                streamKind: "manifest"
            )
        )
    }

    if let dashManifestURL = streaming["dashManifestUrl"] as? String, dashManifestURL.isEmpty == false {
        results.append(
            StreamInfo(
                url: dashManifestURL,
                formatId: "dash-manifest",
                mimeType: "application/dash+xml",
                qualityLabel: nil,
                httpHeaders: defaultHeaders,
                bitrate: nil,
                width: nil,
                height: nil,
                fps: nil,
                audioChannels: nil,
                audioCodec: nil,
                videoCodec: nil,
                container: "mpd",
                hasAudio: true,
                hasVideo: true,
                isAdaptive: false,
                streamKind: "manifest"
            )
        )
    }

    for key in ["formats", "adaptiveFormats"] {
        guard let entries = streaming[key] as? [Any] else { continue }
        for entry in entries {
            guard let entry = entry as? JSONDictionary else { continue }
            guard let url = streamURL(from: entry, resolver: urlResolver), !url.isEmpty else { continue }
            let baseFormatId = stringify(entry["itag"])
            guard isSkippedNativeFormatID(baseFormatId) == false else { continue }

            let mimeType = entry["mimeType"] as? String
            let parsedMime = parseMimeType(mimeType)
            let hasAudio = parsedMime.audioCodec != nil
                || entry["audioQuality"] != nil
                || entry["audioChannels"] != nil
                || (mimeType?.contains("audio/") == true)
            let hasVideo = parsedMime.videoCodec != nil
                || entry["qualityLabel"] != nil
                || (mimeType?.contains("video/") == true)
            let audioLanguage = audioLanguage(from: entry, url: url)
            let audioTrackKind = audioTrackKind(from: entry, url: url)
            let audioIsDefault = (entry["audioTrack"] as? JSONDictionary)?["audioIsDefault"] as? Bool
            let isSuperResolution = isSuperResolutionFormat(url: url)
            let formatId = nativeFormatID(baseFormatId, isSuperResolution: isSuperResolution)
            let qualityLabel = nativeQualityLabel(
                (entry["qualityLabel"] as? String)
                    ?? ytdlpAudioFormatNote(
                        quality: audioQualityLabel(from: entry["audioQuality"]),
                        language: audioLanguage,
                        trackKind: audioTrackKind,
                        isDefault: audioIsDefault
                    ),
                isSuperResolution: isSuperResolution
            )
            let container = normalizedNativeContainer(
                parsedMime.container ?? (entry["container"] as? String),
                hasAudio: hasAudio,
                hasVideo: hasVideo
            )

            results.append(
                StreamInfo(
                    url: url,
                    formatId: formatId,
                    mimeType: mimeType,
                    qualityLabel: qualityLabel,
                    httpHeaders: defaultHeaders,
                    bitrate: intValue(entry["bitrate"]),
                    width: intValue(entry["width"]),
                    height: intValue(entry["height"]),
                    fps: intValue(entry["fps"]),
                    audioChannels: intValue(entry["audioChannels"]),
                    audioCodec: parsedMime.audioCodec ?? (entry["audioQuality"] as? String),
                    videoCodec: parsedMime.videoCodec,
                    container: container,
                    hasAudio: hasAudio,
                    hasVideo: hasVideo,
                    isAdaptive: key == "adaptiveFormats",
                    streamKind: streamKind(for: url, hasAudio: hasAudio, hasVideo: hasVideo),
                    audioLanguage: audioLanguage,
                    audioTrackKind: audioTrackKind,
                    audioLanguagePreference: nil,
                    audioIsDefault: audioIsDefault
                )
            )
        }
    }

    return results
}

private func isSkippedNativeFormatID(_ formatId: String?) -> Bool {
    guard let formatId else { return false }
    return ["250", "598", "599", "600"].contains(formatId)
}

private func nativeFormatID(_ formatId: String?, isSuperResolution: Bool) -> String? {
    guard let formatId else { return nil }
    return isSuperResolution ? "\(formatId)-sr" : formatId
}

private func nativeQualityLabel(_ label: String?, isSuperResolution: Bool) -> String? {
    guard let label else { return nil }
    if isSuperResolution && label.localizedCaseInsensitiveContains("AI-upscaled") == false {
        return "\(label), AI-upscaled"
    }
    return label
}

private func isSuperResolutionFormat(url: String) -> Bool {
    audioTrackAttributes(from: url)["sr"] == "1"
}

private func audioQualityLabel(from value: Any?) -> String? {
    guard let value = stringify(value)?.lowercased(), value.hasPrefix("audio_quality_") else {
        return nil
    }
    return String(value.dropFirst("audio_quality_".count))
}

private func ytdlpAudioFormatNote(
    quality: String?,
    language: String?,
    trackKind: String?,
    isDefault: Bool?
) -> String? {
    guard let quality else { return nil }
    guard let language, trackKind == "original" || isDefault == true else {
        return quality
    }

    var components = [languageLabel(for: language)]
    if trackKind == "original" {
        components.append("original")
    }
    if isDefault == true {
        components.append("(default)")
    }
    return "\(components.joined(separator: " ")), \(quality)"
}

private func normalizedNativeContainer(_ container: String?, hasAudio: Bool, hasVideo: Bool) -> String? {
    guard let container else { return nil }
    if hasAudio, hasVideo == false, container.lowercased() == "mp4" {
        return "m4a"
    }
    return container
}

private func parseHLSVariantStreams(from manifest: String, manifest baseStream: StreamInfo) -> [StreamInfo] {
    let lines = manifest
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

    var results: [StreamInfo] = []
    var pendingAttributes: [String: String]?

    for line in lines {
        if line.hasPrefix("#EXT-X-STREAM-INF:") {
            let rawAttributes = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
            pendingAttributes = parseHLSAttributes(rawAttributes)
            continue
        }

        guard
            line.hasPrefix("#") == false,
            line.isEmpty == false,
            let attributes = pendingAttributes
        else {
            continue
        }

        pendingAttributes = nil
        let absoluteURL = absoluteHLSURL(line, relativeTo: baseStream.url)
        guard absoluteURL.isEmpty == false else { continue }

        let codecs = attributes["CODECS"]?.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
        let videoCodec = codecs.first { !$0.hasPrefix("mp4a") && !$0.hasPrefix("opus") }
        let audioCodec = codecs.first { $0.hasPrefix("mp4a") || $0.hasPrefix("opus") }
        let size = parseHLSResolution(attributes["RESOLUTION"])
        guard let height = size.height, (100...1080).contains(height) else { continue }
        let fps = intValue(attributes["FRAME-RATE"])
        let formatId = hlsFormatID(from: absoluteURL, height: size.height, fps: fps)
        let hlsAudioLanguage = hlsAudioLanguage(from: attributes, url: absoluteURL)
        let hlsAudioTrackKind = hlsAudioTrackKind(from: attributes, url: absoluteURL)
        let hlsAudioIsDefault = hlsAudioIsDefault(from: attributes, url: absoluteURL)
        let hlsAudioLanguagePreference = hlsAudioLanguagePreference(
            trackKind: hlsAudioTrackKind,
            isDefault: hlsAudioIsDefault
        )

        results.append(
            StreamInfo(
                url: absoluteURL,
                formatId: formatId,
                mimeType: "application/x-mpegURL",
                qualityLabel: hlsQualityLabel(
                    height: size.height,
                    trackKind: hlsAudioTrackKind,
                    isDefault: hlsAudioIsDefault
                ),
                httpHeaders: baseStream.httpHeaders,
                bitrate: intValue(attributes["BANDWIDTH"]),
                width: size.width,
                height: size.height,
                fps: fps,
                audioChannels: nil,
                audioCodec: audioCodec,
                videoCodec: videoCodec,
                container: "mp4",
                hasAudio: true,
                hasVideo: true,
                isAdaptive: false,
                streamKind: "manifest",
                audioLanguage: hlsAudioLanguage,
                audioTrackKind: hlsAudioTrackKind,
                audioLanguagePreference: hlsAudioLanguagePreference,
                audioIsDefault: hlsAudioIsDefault
            )
        )
    }

    return hlsVariantsWithYTDLPFormatIDs(results)
}

private func hlsVariantsWithYTDLPFormatIDs(_ streams: [StreamInfo]) -> [StreamInfo] {
    var groups: [String: [StreamInfo]] = [:]
    var order: [String] = []
    for stream in streams {
        guard let formatId = stream.formatId else {
            order.append(UUID().uuidString)
            continue
        }
        if groups[formatId] == nil {
            order.append(formatId)
            groups[formatId] = []
        }
        groups[formatId]?.append(stream)
    }

    return order.flatMap { formatId -> [StreamInfo] in
        guard let variants = groups[formatId] else { return [] }
        guard variants.count > 1 else { return variants }
        return variants
            .sorted {
                hlsVariantYTDLPSortKey($0).lexicographicallyPrecedes(hlsVariantYTDLPSortKey($1))
            }
            .enumerated()
            .map { index, stream in
                copyStream(stream, formatId: "\(formatId)-\(index)")
            }
    }
}

private func hlsVariantYTDLPSortKey(_ stream: StreamInfo) -> [Int] {
    [
        stream.audioTrackKind == "original" ? 1 : 0,
        stream.bitrate ?? 0,
        hlsLanguageTieBreak(stream.audioLanguage),
    ]
}

private func hlsLanguageTieBreak(_ language: String?) -> Int {
    guard let language else { return 0 }
    switch language {
    case "zh-Hans":
        return 1
    case "zh-Hant":
        return 2
    default:
        return 0
    }
}

private func copyStream(_ stream: StreamInfo, formatId: String?) -> StreamInfo {
    StreamInfo(
        url: stream.url,
        formatId: formatId,
        mimeType: stream.mimeType,
        qualityLabel: stream.qualityLabel,
        httpHeaders: stream.httpHeaders,
        bitrate: stream.bitrate,
        width: stream.width,
        height: stream.height,
        fps: stream.fps,
        audioChannels: stream.audioChannels,
        audioCodec: stream.audioCodec,
        videoCodec: stream.videoCodec,
        container: stream.container,
        hasAudio: stream.hasAudio,
        hasVideo: stream.hasVideo,
        isAdaptive: stream.isAdaptive,
        streamKind: stream.streamKind,
        audioLanguage: stream.audioLanguage,
        audioTrackKind: stream.audioTrackKind,
        audioLanguagePreference: stream.audioLanguagePreference,
        audioIsDefault: stream.audioIsDefault
    )
}

private func hlsAudioLanguage(from attributes: [String: String], url: String) -> String? {
    if let language = hlsAudioTrackAttributes(from: attributes, url: url)["lang"] {
        return language
    }
    if let id = attributes["YT-EXT-AUDIO-CONTENT-ID"],
       let language = audioLanguage(fromAudioTrackID: id) {
        return language
    }
    return audioLanguage(from: attributes, url: url)
}

private func hlsAudioTrackKind(from attributes: [String: String], url: String) -> String? {
    if hlsAudioTrackAttributes(from: attributes, url: url)["acont"] == "original" {
        return "original"
    }
    return nil
}

private func hlsAudioIsDefault(from attributes: [String: String], url: String) -> Bool? {
    let audioAttributes = hlsAudioTrackAttributes(from: attributes, url: url)
    if audioAttributes["acont"] == "dubbed-auto",
       audioAttributes["lang"]?.lowercased().hasPrefix("en") == true {
        return true
    }
    return nil
}

private func hlsAudioLanguagePreference(trackKind: String?, isDefault: Bool?) -> Int? {
    if isDefault == true {
        return 5
    }
    if trackKind == "original" {
        return 10
    }
    return nil
}

private func hlsQualityLabel(height: Int?, trackKind: String?, isDefault: Bool?) -> String? {
    if trackKind == "original" {
        return "(original)"
    }
    if isDefault == true {
        return "(default)"
    }
    return height.map { "\($0)p" }
}

private func hlsAudioTrackAttributes(from attributes: [String: String], url: String) -> [String: String] {
    var result = audioTrackAttributes(from: url)
    if let encodedTags = attributes["YT-EXT-XTAGS"] {
        for (key, value) in decodedHLSAudioTrackAttributes(from: encodedTags) {
            result[key] = value
        }
    }
    if result["lang"] == nil,
       let id = attributes["YT-EXT-AUDIO-CONTENT-ID"],
       let language = audioLanguage(fromAudioTrackID: id) {
        result["lang"] = language
    }
    return result
}

private func decodedHLSAudioTrackAttributes(from encodedTags: String) -> [String: String] {
    var padded = encodedTags
    let remainder = padded.count % 4
    if remainder != 0 {
        padded.append(String(repeating: "=", count: 4 - remainder))
    }
    guard let data = Data(base64Encoded: padded) else { return [:] }

    var tokens: [String] = []
    var current: [UInt8] = []
    for byte in data {
        if (32...126).contains(byte) {
            current.append(byte)
        } else if current.isEmpty == false {
            if let token = String(bytes: current, encoding: .utf8) {
                tokens.append(token)
            }
            current.removeAll()
        }
    }
    if current.isEmpty == false,
       let token = String(bytes: current, encoding: .utf8) {
        tokens.append(token)
    }

    let knownKeys = Set(["acont", "lang"])
    var result: [String: String] = [:]
    var pendingKey: String?
    for token in tokens {
        if knownKeys.contains(token) {
            pendingKey = token
        } else if let key = pendingKey {
            result[key] = token
            pendingKey = nil
        }
    }
    return result
}

private func parseHLSAttributes(_ rawValue: String) -> [String: String] {
    var attributes: [String: String] = [:]
    var current = ""
    var inQuotes = false

    func appendCurrent() {
        let parts = current.split(separator: "=", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            attributes[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        current = ""
    }

    for character in rawValue {
        if character == "\"" {
            inQuotes.toggle()
            current.append(character)
        } else if character == ",", inQuotes == false {
            appendCurrent()
        } else {
            current.append(character)
        }
    }
    appendCurrent()

    return attributes
}

private func parseHLSResolution(_ value: String?) -> (width: Int?, height: Int?) {
    guard let value else { return (nil, nil) }
    let parts = value.split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2 else { return (nil, nil) }
    return (parts[0], parts[1])
}

private func hlsFormatID(from urlString: String, height: Int?, fps: Int?) -> String? {
    if let url = URL(string: urlString),
       let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
       let itag = components.queryItems?.first(where: { $0.name == "itag" })?.value,
       itag.isEmpty == false {
        return itag
    }

    if let path = URL(string: urlString)?.path,
       let itag = firstMatch(in: path, pattern: #"/itag/(\d+)(?:/|$)"#) {
        return itag
    }

    switch height {
    case 144: return "91"
    case 240: return "92"
    case 360: return "93"
    case 480: return "94"
    case 720: return (fps ?? 0) >= 50 ? "300" : "95"
    case 1080: return (fps ?? 0) >= 50 ? "301" : "96"
    default: return nil
    }
}

private func absoluteHLSURL(_ value: String, relativeTo baseURLString: String) -> String {
    if URL(string: value)?.scheme != nil {
        return value
    }
    guard let baseURL = URL(string: baseURLString),
          let url = URL(string: value, relativeTo: baseURL) else {
        return value
    }
    return url.absoluteURL.absoluteString
}

private func streamURL(from entry: JSONDictionary, resolver: YouTubeStreamURLResolver?) -> String? {
    if let url = entry["url"] as? String, !url.isEmpty {
        return url
    }

    guard let cipher = (entry["signatureCipher"] as? String) ?? (entry["cipher"] as? String) else {
        return nil
    }

    return resolver?.resolvedURL(fromCipher: cipher)
}

private final class YouTubeStreamURLResolver: @unchecked Sendable {
    private let context: JSContext?
    private let lock = NSLock()

    init?(javaScript: String) {
        guard let components = Self.decipherComponents(from: javaScript) else {
            return nil
        }

        let context = JSContext()
        context?.exceptionHandler = { _, exception in
            PlaybackDebugLogger.log("youtube player decipher exception=\(exception?.toString() ?? "unknown")")
        }
        context?.evaluateScript(components.helperScript)
        context?.evaluateScript(components.functionScript)

        guard context?.objectForKeyedSubscript("__swiftTubeDecipher").isUndefined == false else {
            return nil
        }

        self.context = context
    }

    func resolvedURL(fromCipher cipher: String) -> String? {
        let values = cipherQueryValues(from: cipher)
        guard let baseURL = values["url"], baseURL.isEmpty == false else {
            return nil
        }

        if let directSignature = values["sig"], directSignature.isEmpty == false {
            return appendSignature(directSignature, named: values["sp"] ?? "signature", to: baseURL)
        }

        guard let encryptedSignature = values["s"], encryptedSignature.isEmpty == false else {
            return baseURL
        }

        guard let signature = decipher(encryptedSignature), signature.isEmpty == false else {
            return nil
        }

        return appendSignature(signature, named: values["sp"] ?? "signature", to: baseURL)
    }

    private func decipher(_ signature: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard let function = context?.objectForKeyedSubscript("__swiftTubeDecipher") else {
            return nil
        }
        return function.call(withArguments: [signature])?.toString()
    }

    private static func decipherComponents(from javaScript: String) -> (helperScript: String, functionScript: String)? {
        let functionPatterns = [
            #"(?:function\s+[A-Za-z0-9_$]+\s*\(\s*([A-Za-z0-9_$]+)\s*\)|[A-Za-z0-9_$]+\s*=\s*function\s*\(\s*([A-Za-z0-9_$]+)\s*\))\s*\{"#,
            #"([A-Za-z0-9_$]+)\s*:\s*function\s*\(\s*([A-Za-z0-9_$]+)\s*\)\s*\{"#,
        ]

        for pattern in functionPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(javaScript.startIndex..<javaScript.endIndex, in: javaScript)
            let matches = regex.matches(in: javaScript, options: [], range: nsRange)

            for match in matches {
                guard
                    let matchRange = Range(match.range(at: 0), in: javaScript),
                    let braceIndex = javaScript[matchRange].firstIndex(of: "{"),
                    let block = extractBalancedJavaScriptBlock(in: javaScript, startingAt: braceIndex),
                    block.contains(".split(\"\")"),
                    block.contains(".join(\"\")")
                else {
                    continue
                }

                let parameter = firstCapturedString(in: javaScript, match: match, groups: [1, 2]) ?? "a"
                guard
                    let helperName = extractHelperObjectName(from: block, parameter: parameter),
                    let helperScript = extractHelperScript(named: helperName, from: javaScript)
                else {
                    continue
                }

                let functionScript = "var __swiftTubeDecipher = function(\(parameter)) \(block);"
                return (helperScript, functionScript)
            }
        }

        return nil
    }
}

private func cipherQueryValues(from cipher: String) -> [String: String] {
    let query = cipher.hasPrefix("?") ? String(cipher.dropFirst()) : cipher
    if let components = URLComponents(string: "https://youtube.local/stream?\(query)") {
        let pairs = components.queryItems ?? []
        if pairs.isEmpty == false {
            return pairs.reduce(into: [String: String]()) { result, item in
                result[item.name] = item.value ?? ""
            }
        }
    }

    return query
        .split(separator: "&")
        .reduce(into: [String: String]()) { result, pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = parts.first?.removingPercentEncoding else { return }
            result[name] = parts.dropFirst().first?.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
        }
}

private func appendSignature(_ signature: String, named name: String, to urlString: String) -> String {
    guard var components = URLComponents(string: urlString) else {
        let separator = urlString.contains("?") ? "&" : "?"
        return "\(urlString)\(separator)\(name)=\(signature)"
    }

    var queryItems = components.queryItems ?? []
    if queryItems.contains(where: { $0.name == name }) == false {
        queryItems.append(URLQueryItem(name: name, value: signature))
    }
    components.queryItems = queryItems
    return components.url?.absoluteString ?? urlString
}

private func extractPlayerJavaScriptURL(from html: String) -> URL? {
    let patterns = [
        #""jsUrl"\s*:\s*"([^"]+)""#,
        #""PLAYER_JS_URL"\s*:\s*"([^"]+)""#,
        #"(/s/player/[^"]+/base\.js)"#,
    ]

    for pattern in patterns {
        guard let rawValue = firstMatch(in: html, pattern: pattern) else { continue }
        let cleaned = rawValue
            .replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: #"\\u0026"#, with: "&")

        if cleaned.hasPrefix("//") {
            return URL(string: "https:\(cleaned)")
        }
        if cleaned.hasPrefix("/") {
            return URL(string: "https://www.youtube.com\(cleaned)")
        }
        if let url = URL(string: cleaned), url.scheme != nil {
            return url
        }
    }

    return nil
}

private func extractBalancedJavaScriptBlock(in source: String, startingAt startIndex: String.Index) -> String? {
    guard source[startIndex] == "{" else { return nil }

    var depth = 0
    var inString: Character?
    var isEscaped = false
    var index = startIndex

    while index < source.endIndex {
        let character = source[index]

        if let quote = inString {
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == quote {
                inString = nil
            }
        } else {
            if character == "\"" || character == "'" || character == "`" {
                inString = character
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[startIndex...index])
                }
            }
        }

        index = source.index(after: index)
    }

    return nil
}

private func extractHelperObjectName(from functionBlock: String, parameter: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: #"\b([A-Za-z_$][A-Za-z0-9_$]*)\.[A-Za-z_$][A-Za-z0-9_$]*\("#) else {
        return nil
    }
    let nsRange = NSRange(functionBlock.startIndex..<functionBlock.endIndex, in: functionBlock)
    let matches = regex.matches(in: functionBlock, options: [], range: nsRange)

    for match in matches {
        guard let name = firstCapturedString(in: functionBlock, match: match, groups: [1]),
              name != parameter else {
            continue
        }
        return name
    }

    return nil
}

private func extractHelperScript(named helperName: String, from javaScript: String) -> String? {
    let escapedName = NSRegularExpression.escapedPattern(for: helperName)
    let patterns = [
        #"(?:var|let|const)\s+\#(escapedName)\s*=\s*\{"#,
        #"\b\#(escapedName)\s*=\s*\{"#,
    ]

    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        let nsRange = NSRange(javaScript.startIndex..<javaScript.endIndex, in: javaScript)
        guard
            let match = regex.firstMatch(in: javaScript, options: [], range: nsRange),
            let matchRange = Range(match.range(at: 0), in: javaScript),
            let braceIndex = javaScript[matchRange].firstIndex(of: "{"),
            let objectBlock = extractBalancedJavaScriptBlock(in: javaScript, startingAt: braceIndex)
        else {
            continue
        }

        return "var \(helperName) = \(objectBlock);"
    }

    return nil
}

private func firstCapturedString(in source: String, match: NSTextCheckingResult, groups: [Int]) -> String? {
    for group in groups where group < match.numberOfRanges {
        guard let range = Range(match.range(at: group), in: source) else { continue }
        let value = String(source[range])
        if value.isEmpty == false {
            return value
        }
    }
    return nil
}

private func parseYTDLPStreams(from payload: JSONDictionary) -> [StreamInfo] {
    guard let formats = payload["formats"] as? [Any] else { return [] }

    return formats.compactMap { format in
        guard let format = format as? JSONDictionary else { return nil }
        guard let url = format["url"] as? String, !url.isEmpty else { return nil }

        let protocolValue = format["protocol"] as? String
        guard protocolValue?.hasPrefix("http") == true || protocolValue?.hasPrefix("m3u8") == true else {
            return nil
        }

        let videoCodec = format["vcodec"] as? String
        let audioCodec = format["acodec"] as? String
        let hasVideo = videoCodec != nil && videoCodec != "none"
        let hasAudio = audioCodec != nil && audioCodec != "none"
        let bitrate = ((format["tbr"] as? Double).map { Int($0 * 1000) }) ?? intValue(format["tbr"])

        return StreamInfo(
            url: url,
            formatId: stringify(format["format_id"]),
            mimeType: mimeTypeFromYTDLP(format: format),
            qualityLabel: (format["format_note"] as? String) ?? ((format["height"] as? Int).map { "\($0)p" }),
            httpHeaders: (format["http_headers"] as? JSONDictionary)?.compactMapValues { $0 as? String },
            bitrate: bitrate,
            width: intValue(format["width"]),
            height: intValue(format["height"]),
            fps: intValue(format["fps"]),
            audioChannels: intValue(format["audio_channels"]),
            audioCodec: audioCodec,
            videoCodec: videoCodec,
            container: (format["container"] as? String) ?? (format["ext"] as? String),
            hasAudio: hasAudio,
            hasVideo: hasVideo,
            isAdaptive: hasAudio != hasVideo,
            streamKind: streamKind(for: url, hasAudio: hasAudio, hasVideo: hasVideo),
            audioLanguage: stringify(format["language"]) ?? audioLanguage(from: format, url: url),
            audioTrackKind: audioTrackKind(from: format, url: url),
            audioLanguagePreference: intValue(format["language_preference"]),
            audioIsDefault: audioIsDefault(from: format, url: url)
        )
    }
}

private func parseYTDLPSubtitles(from payload: JSONDictionary) -> [SubtitleTrack] {
    var results: [SubtitleTrack] = []
    var seen = Set<String>()

    let groups: [(String, Bool)] = [("subtitles", false), ("automatic_captions", true)]
    for (key, autoGenerated) in groups {
        guard let map = payload[key] as? JSONDictionary else { continue }
        for (language, rawEntries) in map {
            if seen.contains(language) && autoGenerated {
                continue
            }
            guard let entries = rawEntries as? [Any] else { continue }
            let url = entries.compactMap { ($0 as? JSONDictionary)?["url"] as? String }.first
            guard let url else { continue }

            results.append(
                SubtitleTrack(
                    language: language,
                    label: languageLabel(for: language),
                    url: url,
                    isAutoGenerated: autoGenerated
                )
            )
            seen.insert(language)
        }
    }

    return results
}

private func extractSubtitles(from playerData: JSONDictionary) -> [SubtitleTrack] {
    let captionTracks = ((((playerData["captions"] as? JSONDictionary)?["playerCaptionsTracklistRenderer"] as? JSONDictionary)?["captionTracks"] as? [Any])) ?? []
    return captionTracks.compactMap { item in
        guard let item = item as? JSONDictionary else { return nil }
        guard let url = item["baseUrl"] as? String else { return nil }

        let language = (item["languageCode"] as? String) ?? "unknown"
        let label = textValue(from: item["name"]) ?? languageLabel(for: language)
        let kind = item["kind"] as? String

        return SubtitleTrack(
            language: language,
            label: label,
            url: url,
            isAutoGenerated: kind == "asr"
        )
    }
}

private func extractLiveChatSession(from watchData: JSONDictionary) -> LiveChatSession? {
    guard let renderer = (((((watchData["contents"] as? JSONDictionary)?["twoColumnWatchNextResults"] as? JSONDictionary)?["conversationBar"] as? JSONDictionary)?["liveChatRenderer"] as? JSONDictionary)) else {
        return nil
    }

    let initialContinuation = extractLiveChatContinuationToken(from: renderer["continuations"]).token
    let modeContinuations = extractLiveChatModeContinuations(from: renderer)
    let defaultMode = extractLiveChatMode(from: renderer) ?? .top
    let isReplay = extractLiveChatSubMenuItems(from: renderer).contains { item in
        ((item["title"] as? String) ?? "").localizedCaseInsensitiveContains("replay")
    } || extractLiveChatContinuationToken(from: renderer["continuations"]).isReplay

    guard initialContinuation != nil || modeContinuations[.top] != nil || modeContinuations[.live] != nil else {
        return nil
    }

    return LiveChatSession(
        initialContinuation: initialContinuation,
        topChatContinuation: modeContinuations[.top],
        liveChatContinuation: modeContinuations[.live],
        defaultMode: defaultMode,
        isReplay: isReplay
    )
}

private func preferredLiveChatContinuation(for mode: LiveChatMode, in session: LiveChatSession) -> String? {
    switch mode {
    case .top:
        return session.topChatContinuation ?? session.initialContinuation
    case .live:
        return session.liveChatContinuation ?? session.initialContinuation
    }
}

private func extractLiveChatMode(from data: JSONDictionary) -> LiveChatMode? {
    let continuation = ((data["continuationContents"] as? JSONDictionary)?["liveChatContinuation"] as? JSONDictionary)
    return extractLiveChatMode(from: continuation)
}

private func extractLiveChatMode(from renderer: JSONDictionary?) -> LiveChatMode? {
    guard let renderer else { return nil }

    let liveChatCurrentFilter = (((renderer["header"] as? JSONDictionary)?["liveChatHeaderRenderer"] as? JSONDictionary)?["viewSelector"] as? JSONDictionary)?["liveChatCurrentFilter"] as? String
    if liveChatCurrentFilter == "LIVE_CHAT_FILTER_MODE_UNFILTERED" {
        return .live
    }
    if liveChatCurrentFilter == "LIVE_CHAT_FILTER_MODE_DEFAULT" {
        return .top
    }

    let subMenuItems = extractLiveChatSubMenuItems(from: renderer)
    for item in subMenuItems {
        guard (item["selected"] as? Bool) == true else { continue }
        return liveChatMode(for: item)
    }

    return nil
}

private func extractLiveChatModeContinuations(from data: JSONDictionary) -> [LiveChatMode: String] {
    let continuation = ((data["continuationContents"] as? JSONDictionary)?["liveChatContinuation"] as? JSONDictionary)
    return extractLiveChatModeContinuations(from: continuation)
}

private func extractLiveChatModeContinuations(from renderer: JSONDictionary?) -> [LiveChatMode: String] {
    var continuations: [LiveChatMode: String] = [:]

    for item in extractLiveChatSubMenuItems(from: renderer) {
        guard let mode = liveChatMode(for: item) else { continue }
        guard let continuation = extractLiveChatContinuationToken(from: item["continuation"]).token,
              continuation.isEmpty == false else {
            continue
        }
        continuations[mode] = continuation
    }

    return continuations
}

private func extractLiveChatSubMenuItems(from renderer: JSONDictionary?) -> [JSONDictionary] {
    guard let renderer else { return [] }

    let subMenuItems = ((((renderer["header"] as? JSONDictionary)?["liveChatHeaderRenderer"] as? JSONDictionary)?["viewSelector"] as? JSONDictionary)?["sortFilterSubMenuRenderer"] as? JSONDictionary)?["subMenuItems"] as? [Any] ?? []
    return subMenuItems.compactMap { $0 as? JSONDictionary }
}

private func liveChatMode(for item: JSONDictionary) -> LiveChatMode? {
    let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    if title.contains("live") {
        return .live
    }
    if title.isEmpty == false {
        return .top
    }
    return nil
}

private func extractLiveChatResponse(
    from data: JSONDictionary,
    requestedMode: LiveChatMode
) -> LiveChatResponse {
    let continuation = ((data["continuationContents"] as? JSONDictionary)?["liveChatContinuation"] as? JSONDictionary) ?? [:]
    let actions = continuation["actions"] as? [Any] ?? []
    let deltas = extractLiveChatMessageDeltas(from: actions)
    let continuationPayload = extractLiveChatContinuationToken(from: continuation["continuations"])
    let responseContext = data["responseContext"] as? JSONDictionary

    return LiveChatResponse(
        mode: requestedMode,
        messages: deltas.messages,
        replacedMessages: deltas.replacedMessages,
        removedMessageIDs: deltas.removedMessageIDs,
        continuation: continuationPayload.token,
        timeoutMs: continuationPayload.timeoutMs,
        composer: extractLiveChatComposer(from: continuation, responseContext: responseContext),
        viewerName: textValue(from: continuation["viewerName"])
    )
}

private func extractLiveChatMessageDeltas(from actions: [Any]) -> (
    messages: [LiveChatMessage],
    replacedMessages: [LiveChatMessage],
    removedMessageIDs: [String]
) {
    var messages: [LiveChatMessage] = []
    var replacedMessages: [LiveChatMessage] = []
    var removedMessageIDs: [String] = []

    for action in actions {
        guard let action = action as? JSONDictionary else { continue }

        if let replayChatItemAction = action["replayChatItemAction"] as? JSONDictionary {
            let nestedActions = replayChatItemAction["actions"] as? [Any] ?? []
            let nestedDeltas = extractLiveChatMessageDeltas(from: nestedActions)
            messages.append(contentsOf: nestedDeltas.messages)
            replacedMessages.append(contentsOf: nestedDeltas.replacedMessages)
            removedMessageIDs.append(contentsOf: nestedDeltas.removedMessageIDs)
            continue
        }

        if let addChatItemAction = action["addChatItemAction"] as? JSONDictionary,
           let item = addChatItemAction["item"],
           let message = extractLiveChatMessage(from: item) {
            messages.append(message)
        }

        if let replaceChatItemAction = action["replaceChatItemAction"] as? JSONDictionary,
           let item = replaceChatItemAction["replacementItem"],
           let message = extractLiveChatMessage(from: item) {
            replacedMessages.append(message)
        }

        if let removeChatItemAction = action["removeChatItemAction"] as? JSONDictionary,
           let targetItemID = removeChatItemAction["targetItemId"] as? String,
           targetItemID.isEmpty == false {
            removedMessageIDs.append(targetItemID)
        }
    }

    return (messages, replacedMessages, removedMessageIDs)
}

private func extractLiveChatMessage(from item: Any?) -> LiveChatMessage? {
    guard let item = item as? JSONDictionary else { return nil }

    if let renderer = item["liveChatTextMessageRenderer"] as? JSONDictionary {
        return makeLiveChatMessage(
            renderer: renderer,
            kind: .text,
            body: renderer["message"] as? JSONDictionary
        )
    }

    if let renderer = item["liveChatPaidMessageRenderer"] as? JSONDictionary {
        return makeLiveChatMessage(
            renderer: renderer,
            kind: .paid,
            body: renderer["message"] as? JSONDictionary
        )
    }

    if let renderer = item["liveChatPaidStickerRenderer"] as? JSONDictionary {
        let stickerLabel = textValue(from: ((renderer["sticker"] as? JSONDictionary)?["accessibility"] as? JSONDictionary)?["accessibilityData"])
            ?? "Super Sticker"
        return makeLiveChatMessage(
            renderer: renderer,
            kind: .paidSticker,
            body: ["runs": [["text": stickerLabel]]]
        )
    }

    if let renderer = item["liveChatMembershipItemRenderer"] as? JSONDictionary {
        let membershipBody = (renderer["message"] as? JSONDictionary)
            ?? (renderer["headerSubtext"] as? JSONDictionary)
        return makeLiveChatMessage(
            renderer: renderer,
            kind: .membership,
            body: membershipBody
        )
    }

    if let renderer = item["liveChatViewerEngagementMessageRenderer"] as? JSONDictionary {
        return LiveChatMessage(
            id: renderer["id"] as? String ?? UUID().uuidString,
            kind: .system,
            author: "YouTube",
            authorChannelId: nil,
            avatarUrl: nil,
            fragments: extractLiveChatFragments(from: renderer["message"] as? JSONDictionary),
            timestampUsec: renderer["timestampUsec"] as? String,
            purchaseAmountText: nil,
            isVerified: false,
            isOwner: false,
            isModerator: false,
            isMember: false,
            isPending: false
        )
    }

    return nil
}

private func makeLiveChatMessage(
    renderer: JSONDictionary,
    kind: LiveChatMessageKind,
    body: JSONDictionary?
) -> LiveChatMessage? {
    let fragments = extractLiveChatFragments(from: body)
    let authorName = textValue(from: renderer["authorName"])
    let purchaseAmountText = textValue(from: renderer["purchaseAmountText"])
    let messageID = renderer["id"] as? String ?? UUID().uuidString

    guard authorName != nil || fragments.isEmpty == false || purchaseAmountText != nil else {
        return nil
    }

    let authorBadges = renderer["authorBadges"] as? [Any] ?? []
    let badgeKinds = Set(authorBadges.compactMap { badge -> String? in
        let renderer = (badge as? JSONDictionary)?["liveChatAuthorBadgeRenderer"] as? JSONDictionary
        return ((renderer?["icon"] as? JSONDictionary)?["iconType"] as? String)
    })

    let isMember = authorBadges.contains { badge in
        let renderer = (badge as? JSONDictionary)?["liveChatAuthorBadgeRenderer"] as? JSONDictionary
        return renderer?["customThumbnail"] != nil
    }

    return LiveChatMessage(
        id: messageID,
        kind: kind,
        author: authorName,
        authorChannelId: renderer["authorExternalChannelId"] as? String,
        avatarUrl: bestThumbnailURL(thumbnails(from: renderer["authorPhoto"])),
        fragments: fragments,
        timestampUsec: renderer["timestampUsec"] as? String,
        purchaseAmountText: purchaseAmountText,
        isVerified: badgeKinds.contains("VERIFIED"),
        isOwner: badgeKinds.contains("OWNER"),
        isModerator: badgeKinds.contains("MODERATOR"),
        isMember: isMember,
        isPending: false
    )
}

private func extractLiveChatFragments(from message: JSONDictionary?) -> [LiveChatMessageFragment] {
    let runs = message?["runs"] as? [Any] ?? []
    return runs.enumerated().compactMap { index, value in
        guard let run = value as? JSONDictionary else { return nil }

        if let emoji = run["emoji"] as? JSONDictionary {
            let shortcut = (emoji["shortcuts"] as? [Any])?.compactMap { $0 as? String }.first
            let emojiID = emoji["emojiId"] as? String
            let displayText = (emoji["isCustomEmoji"] as? Bool) == true
                ? (shortcut ?? emojiID ?? "")
                : (emojiID ?? shortcut ?? "")

            guard displayText.isEmpty == false else { return nil }

            return LiveChatMessageFragment(
                id: "emoji-\(index)",
                text: displayText,
                kind: .emoji,
                url: nil,
                emojiImageUrl: bestThumbnailURL(thumbnails(from: (emoji["image"] as? JSONDictionary)))
            )
        }

        guard let text = run["text"] as? String, text.isEmpty == false else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: LiveChatMessageFragmentKind
        if trimmed.hasPrefix("@") {
            kind = .mention
        } else if extractCommandURL(from: run["navigationEndpoint"]) != nil {
            kind = .link
        } else {
            kind = .text
        }

        return LiveChatMessageFragment(
            id: "text-\(index)",
            text: text,
            kind: kind,
            url: extractCommandURL(from: run["navigationEndpoint"]),
            emojiImageUrl: nil
        )
    }
}

private func extractLiveChatComposer(
    from continuation: JSONDictionary,
    responseContext: JSONDictionary?
) -> LiveChatComposer? {
    if let renderer = (continuation["actionPanel"] as? JSONDictionary)?["liveChatMessageInputRenderer"] as? JSONDictionary {
        let textInputField = ((renderer["inputField"] as? JSONDictionary)?["liveChatTextInputFieldRenderer"] as? JSONDictionary)
        let sendEndpoint = (((renderer["sendButton"] as? JSONDictionary)?["buttonRenderer"] as? JSONDictionary)?["serviceEndpoint"] as? JSONDictionary)?["sendLiveChatMessageEndpoint"] as? JSONDictionary
        let datasyncId = (((responseContext?["mainAppWebResponseContext"] as? JSONDictionary)?["datasyncId"] as? String))

        return LiveChatComposer(
            authorName: textValue(from: renderer["authorName"]),
            placeholder: textValue(from: textInputField?["placeholder"]) ?? textValue(from: textInputField?["unselectedPlaceholder"]),
            maxCharacterLimit: intValue(textInputField?["maxCharacterLimit"]) ?? 200,
            sendParams: sendEndpoint?["params"] as? String,
            clientIdPrefix: sendEndpoint?["clientIdPrefix"] as? String,
            datasyncId: datasyncId,
            restrictedMessage: nil
        )
    }

    if let restricted = (continuation["actionPanel"] as? JSONDictionary)?["liveChatRestrictedParticipationRenderer"] as? JSONDictionary {
        return LiveChatComposer(
            authorName: nil,
            placeholder: nil,
            maxCharacterLimit: 0,
            sendParams: nil,
            clientIdPrefix: nil,
            datasyncId: nil,
            restrictedMessage: textValue(from: restricted["message"])
        )
    }

    return nil
}

private func extractLiveChatContinuationToken(from value: Any?) -> (token: String?, timeoutMs: Int?, isReplay: Bool) {
    let entries: [Any]
    if let list = value as? [Any] {
        entries = list
    } else if let dictionary = value as? JSONDictionary {
        entries = [dictionary]
    } else {
        entries = []
    }

    for entry in entries {
        guard let entry = entry as? JSONDictionary else { continue }

        if let reload = entry["reloadContinuationData"] as? JSONDictionary,
           let continuation = reload["continuation"] as? String,
           continuation.isEmpty == false {
            return (continuation, intValue(reload["timeoutMs"]), false)
        }

        if let invalidation = entry["invalidationContinuationData"] as? JSONDictionary,
           let continuation = invalidation["continuation"] as? String,
           continuation.isEmpty == false {
            return (continuation, intValue(invalidation["timeoutMs"]), false)
        }

        if let timed = entry["timedContinuationData"] as? JSONDictionary,
           let continuation = timed["continuation"] as? String,
           continuation.isEmpty == false {
            return (continuation, intValue(timed["timeoutMs"]), false)
        }

        if let replay = entry["liveChatReplayContinuationData"] as? JSONDictionary,
           let continuation = replay["continuation"] as? String,
           continuation.isEmpty == false {
            return (
                continuation,
                intValue(replay["timeoutMs"]) ?? intValue(replay["timeUntilLastMessageMsec"]),
                true
            )
        }
    }

    return (nil, nil, false)
}

private func transcriptURL(for baseURLString: String) -> URL? {
    guard var components = URLComponents(string: baseURLString) else {
        return nil
    }

    var queryItems = components.queryItems ?? []
    queryItems.removeAll { $0.name == "fmt" }
    queryItems.append(URLQueryItem(name: "fmt", value: "vtt"))
    queryItems.append(URLQueryItem(name: "xorb", value: "2"))
    components.queryItems = queryItems
    return components.url
}

private func parseTranscriptSegments(from text: String) -> [TranscriptSegment] {
    let vttSegments = parseWebVTTTranscriptSegments(from: text)
    if vttSegments.isEmpty == false {
        return vttSegments
    }

    return parseXMLTranscriptSegments(from: text)
}

private func parseWebVTTTranscriptSegments(from text: String) -> [TranscriptSegment] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    let blocks = normalized.components(separatedBy: "\n\n")
    var segments: [TranscriptSegment] = []

    for block in blocks {
        let lines = block
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
        let timingParts = lines[timingIndex].components(separatedBy: "-->")
        guard timingParts.count == 2,
              let start = parseWebVTTTime(timingParts[0]),
              let end = parseWebVTTTime(timingParts[1]) else {
            continue
        }

        let caption = lines[(timingIndex + 1)...]
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = decodeTranscriptText(caption)
        guard cleaned.isEmpty == false else { continue }

        segments.append(
            TranscriptSegment(
                id: "vtt-\(segments.count)",
                startTime: start,
                duration: max(end - start, 0),
                text: cleaned
            )
        )
    }

    return segments
}

private func parseWebVTTTime(_ value: String) -> Double? {
    let trimmed = value
        .components(separatedBy: " ")
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let parts = trimmed.split(separator: ":").map(String.init)
    guard parts.count == 2 || parts.count == 3 else { return nil }

    let secondsPart = parts.last ?? ""
    let secondComponents = secondsPart.split(separator: ".").map(String.init)
    guard let seconds = Double(secondComponents.first ?? "") else { return nil }
    let fractional = secondComponents.count > 1 ? (Double("0.\(secondComponents[1])") ?? 0) : 0

    if parts.count == 2 {
        guard let minutes = Double(parts[0]) else { return nil }
        return (minutes * 60) + seconds + fractional
    }

    guard let hours = Double(parts[0]), let minutes = Double(parts[1]) else { return nil }
    return (hours * 3600) + (minutes * 60) + seconds + fractional
}

private func parseXMLTranscriptSegments(from text: String) -> [TranscriptSegment] {
    let pattern = #"<(text|p)\b([^>]*)>(.*?)</\1>"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
        return []
    }

    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    var segments: [TranscriptSegment] = []

    for match in matches {
        guard match.numberOfRanges >= 4 else { continue }
        let attributes = nsText.substring(with: match.range(at: 2))
        let inner = nsText.substring(with: match.range(at: 3))

        let start = attributeValue(named: "start", in: attributes).flatMap(Double.init)
            ?? attributeValue(named: "t", in: attributes).flatMap { value in
                Double(value).map { $0 / 1000 }
            }
        let duration = attributeValue(named: "dur", in: attributes).flatMap(Double.init)
            ?? attributeValue(named: "d", in: attributes).flatMap { value in
                Double(value).map { $0 / 1000 }
            }

        guard let start else { continue }
        let cleaned = decodeTranscriptText(stripXMLTags(from: inner))
        guard cleaned.isEmpty == false else { continue }

        segments.append(
            TranscriptSegment(
                id: "xml-\(segments.count)",
                startTime: start,
                duration: duration ?? 0,
                text: cleaned
            )
        )
    }

    return segments
}

private func attributeValue(named name: String, in attributes: String) -> String? {
    let pattern = #"\b\#(name)=\"([^\"]+)\""#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsAttributes = attributes as NSString
    guard let match = regex.firstMatch(in: attributes, range: NSRange(location: 0, length: nsAttributes.length)),
          match.numberOfRanges >= 2 else {
        return nil
    }
    return nsAttributes.substring(with: match.range(at: 1))
}

private func stripXMLTags(from text: String) -> String {
    text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
}

private func decodeTranscriptText(_ text: String) -> String {
    let decoded = text
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\u{00A0}", with: " ")

    return decoded
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func mergeVideoProgress(
    remote: VideoProgress?,
    local: VideoProgress?,
    durationSeconds: Double?
) -> VideoProgress? {
    let resolvedDuration = durationSeconds ?? remote?.durationSeconds ?? local?.durationSeconds
    let merged = VideoProgress(
        youtubeFraction: remote?.youtubeFraction,
        localElapsedSeconds: local?.localElapsedSeconds,
        durationSeconds: resolvedDuration,
        lastUpdatedAt: local?.lastUpdatedAt,
        localCompleted: local?.localCompleted ?? false
    )

    if merged.youtubeFraction == nil,
       merged.localElapsedSeconds == nil,
       merged.localCompleted == false {
        return nil
    }

    return merged
}

private func makeRemoteProgress(youtubeFraction: Double?, durationText: String?) -> VideoProgress? {
    guard let youtubeFraction else { return nil }
    return VideoProgress(
        youtubeFraction: youtubeFraction / 100,
        localElapsedSeconds: nil,
        durationSeconds: parseDurationSeconds(from: durationText),
        lastUpdatedAt: nil,
        localCompleted: false
    )
}

private func deduplicatedVideoTags(_ groups: [VideoTag]...) -> [VideoTag] {
    var seen = Set<String>()
    var result: [VideoTag] = []

    for group in groups {
        for tag in group where seen.insert(tag.id).inserted {
            result.append(tag)
        }
    }

    return result
}

private func extractVideoTags(from data: Any?) -> [VideoTag] {
    guard let data else { return [] }
    var hasLive = false
    var hasMembersOnly = false

    visitJSONObjects(in: data) { node in
        if let renderer = node["metadataBadgeRenderer"] as? JSONDictionary {
            let style = (renderer["style"] as? String) ?? ""
            let label = textValue(from: renderer["label"]) ?? ""
            let tooltip = textValue(from: renderer["tooltip"]) ?? ""
            let iconType = (((renderer["icon"] as? JSONDictionary)?["iconType"] as? String) ?? "")
            if matchesLiveBadge(style) || matchesLiveBadge(label) || matchesLiveBadge(tooltip) || matchesLiveBadge(iconType) {
                hasLive = true
            }
            if style.localizedCaseInsensitiveContains("members_only")
                || matchesMembersOnlyBadge(label)
                || matchesMembersOnlyBadge(tooltip) {
                hasMembersOnly = true
            }
        }

        if let badgeViewModel = node["badgeViewModel"] as? JSONDictionary {
            let iconName = (badgeViewModel["iconName"] as? String) ?? ""
            let label = (badgeViewModel["label"] as? String) ?? contentTextValue(from: badgeViewModel["text"]) ?? ""
            if matchesLiveBadge(iconName) || matchesLiveBadge(label) {
                hasLive = true
            }
            if iconName.localizedCaseInsensitiveContains("members")
                || matchesMembersOnlyBadge(label) {
                hasMembersOnly = true
            }
        }

        if let thumbnailBadgeViewModel = node["thumbnailBadgeViewModel"] as? JSONDictionary {
            let text = (thumbnailBadgeViewModel["text"] as? String) ?? ""
            if matchesLiveBadge(text) {
                hasLive = true
            }
            if matchesMembersOnlyBadge(text) {
                hasMembersOnly = true
            }
        }

        if let overlayRenderer = node["thumbnailOverlayTimeStatusRenderer"] as? JSONDictionary {
            let style = (overlayRenderer["style"] as? String) ?? ""
            let text = textValue(from: overlayRenderer["text"]) ?? ""
            if matchesLiveBadge(style) || matchesLiveBadge(text) {
                hasLive = true
            }
        }

        return (hasLive && hasMembersOnly) ? .stop : .continue
    }

    var tags: [VideoTag] = []
    if hasLive {
        tags.append(.live)
    }
    if hasMembersOnly {
        tags.append(.membersOnly)
    }
    return tags
}

private func matchesLiveBadge(_ text: String) -> Bool {
    let normalized = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard !normalized.isEmpty else { return false }
    return normalized == "live"
        || normalized == "live now"
        || normalized.contains("live_now")
        || normalized.contains("live now")
        || normalized.contains("style_live")
}

private func matchesMembersOnlyBadge(_ text: String) -> Bool {
    let normalized = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard !normalized.isEmpty else { return false }
    return normalized.contains("members only")
        || normalized.contains("member only")
        || normalized.contains("for members")
        || normalized.contains("members-only")
}

private func extractVideoAccessIssue(from data: Any?, fallbackTags: [VideoTag]) -> VideoAccessIssue? {
    guard let root = data as? JSONDictionary,
          let playability = root["playabilityStatus"] as? JSONDictionary else {
        if fallbackTags.contains(where: \.isMembersOnly) {
            return VideoAccessIssue(
                kind: .membersOnly,
                title: "Members-only video",
                message: "Join this channel on YouTube to watch this video."
            )
        }
        return nil
    }

    let status = ((playability["status"] as? String) ?? "").uppercased()
    let errorRenderer = (playability["errorScreen"] as? JSONDictionary)?["playerErrorMessageRenderer"] as? JSONDictionary
    let reason = textValue(from: playability["reason"])
        ?? textValue(from: errorRenderer?["reason"])
    let subreason = textValue(from: errorRenderer?["subreason"])
        ?? contentTextValue(from: errorRenderer?["subreason"])
    let message = [reason, subreason]
        .compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        .joined(separator: " ")

    if matchesMembersOnlyBadge(message) || fallbackTags.contains(where: \.isMembersOnly) {
        return VideoAccessIssue(
            kind: .membersOnly,
            title: "Members-only video",
            message: message.isEmpty ? "Join this channel on YouTube to watch this video." : message
        )
    }

    guard status != "OK" else { return nil }

    return VideoAccessIssue(
        kind: .unavailable,
        title: "This video can’t be played",
        message: message.isEmpty ? "YouTube did not return a playable stream for this video." : message
    )
}

private func parseStandardVideoItem(_ renderer: JSONDictionary) -> VideoItem? {
    guard let videoID = renderer["videoId"] as? String, !videoID.isEmpty else {
        return nil
    }

    let metadataParts = splitMetadataText(textValue(from: renderer["metadataText"]))
    let durationText = textValue(from: renderer["lengthText"])

    return VideoItem(
        id: videoID,
        title: textValue(from: renderer["title"]) ?? "Untitled",
        channel: textValue(from: renderer["longBylineText"])
            ?? textValue(from: renderer["shortBylineText"])
            ?? textValue(from: renderer["ownerText"])
            ?? textValue(from: renderer["bylineText"]),
        channelId: channelID(from: renderer),
        channelAvatarUrl: channelAvatarURL(from: renderer),
        viewCountText: textValue(from: renderer["viewCountText"])
            ?? textValue(from: renderer["shortViewCountText"])
            ?? metadataParts.first,
        publishedTimeText: textValue(from: renderer["publishedTimeText"])
            ?? (metadataParts.count > 1 ? metadataParts[1] : nil),
        durationText: durationText,
        thumbnails: thumbnails(from: renderer["thumbnail"]),
        progress: makeRemoteProgress(
            youtubeFraction: extractWatchProgressFraction(from: renderer["thumbnailOverlays"]),
            durationText: durationText
        ),
        tags: extractVideoTags(from: renderer)
    )
}

private func extractChannelHeader(from data: Any) -> ChannelHeader? {
    let metadataRenderer = ((data as? JSONDictionary)?["metadata"] as? JSONDictionary)?["channelMetadataRenderer"] as? JSONDictionary
    let pageHeader = (((((data as? JSONDictionary)?["header"] as? JSONDictionary)?["pageHeaderRenderer"] as? JSONDictionary)?["content"] as? JSONDictionary)?["pageHeaderViewModel"] as? JSONDictionary)

    let metadataRows = ((((pageHeader?["metadata"] as? JSONDictionary)?["contentMetadataViewModel"] as? JSONDictionary)?["metadataRows"] as? [Any])) ?? []
    let handleText = metadataRows.indices.contains(0) ? rowTextParts(metadataRows[0]).first : nil
    let metrics = metadataRows.indices.contains(1) ? rowTextParts(metadataRows[1]) : []

    let channelID = (metadataRenderer?["externalId"] as? String)
        ?? channelID(from: metadataRenderer)
        ?? channelID(from: pageHeader)
    let title = contentTextValue(from: (((pageHeader?["title"] as? JSONDictionary)?["dynamicTextViewModel"] as? JSONDictionary)?["text"]))
        ?? (metadataRenderer?["title"] as? String)
    guard let channelID, let title else {
        return nil
    }

    let avatarImage =
        ((((pageHeader?["image"] as? JSONDictionary)?["decoratedAvatarViewModel"] as? JSONDictionary)?["avatar"] as? JSONDictionary)?["avatarViewModel"] as? JSONDictionary)?["image"]
    let bannerImage = ((pageHeader?["banner"] as? JSONDictionary)?["imageBannerViewModel"] as? JSONDictionary)?["image"]
    let descriptionPreview = contentTextValue(from: ((pageHeader?["description"] as? JSONDictionary)?["descriptionPreviewViewModel"] as? JSONDictionary)?["description"])
        ?? (metadataRenderer?["description"] as? String)
    let canonicalBaseURL =
        normalizeURL((metadataRenderer?["vanityChannelUrl"] as? String))
        ?? normalizeURL((metadataRenderer?["ownerUrls"] as? [String])?.first)
        ?? normalizeURL((metadataRenderer?["channelUrl"] as? String))

    return ChannelHeader(
        channel: ChannelReference(
            channelId: channelID,
            title: title,
            canonicalBaseUrl: canonicalBaseURL
        ),
        handleText: handleText,
        avatarUrl: bestThumbnailURL(sourceThumbnails(from: avatarImage))
            ?? bestThumbnailURL(thumbnails(from: metadataRenderer?["avatar"])),
        bannerUrl: bestThumbnailURL(sourceThumbnails(from: bannerImage)),
        descriptionPreview: descriptionPreview,
        subscriberCountText: metrics.first,
        videoCountText: metrics.count > 1 ? metrics[1] : nil,
        subscribeButtonTitle: extractChannelSubscribeButtonTitle(from: pageHeader),
        aboutContinuationToken: extractChannelAboutContinuationToken(from: pageHeader)
    )
}

private func extractChannelSubscribeButtonTitle(from pageHeader: JSONDictionary?) -> String? {
    guard let actions = pageHeader?["actions"] else { return nil }

    var title: String?
    visitJSONObjects(in: actions) { node in
        guard let buttonViewModel = node["buttonViewModel"] as? JSONDictionary else { return .continue }
        guard let candidate = contentTextValue(from: buttonViewModel["title"]) ?? (buttonViewModel["title"] as? String) else {
            return .continue
        }

        let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return .continue }

        let lowercase = normalized.lowercased()
        guard lowercase.contains("subscribe") || lowercase.contains("subscribed") else {
            return .continue
        }

        title = normalized
        return .stop
    }

    return title
}

private func extractChannelSubscriptionState(from data: Any, header: ChannelHeader?) -> SubscriptionState? {
    if let buttonViewModel = firstChannelSubscribeButtonViewModel(from: data) {
        let stateKey = buttonViewModel["stateEntityStoreKey"] as? String
        let subscribed = stateKey.flatMap { channelSubscriptionStateValue(in: data, key: $0) }
            ?? ((buttonViewModel["unsubscribeButtonContent"] as? JSONDictionary)?["subscribeState"] as? JSONDictionary)?["subscribed"] as? Bool
            ?? ((buttonViewModel["subscribeButtonContent"] as? JSONDictionary)?["subscribeState"] as? JSONDictionary)?["subscribed"] as? Bool
            ?? false
        let activeContent = currentChannelSubscribeContent(from: buttonViewModel, subscribed: subscribed)
        let buttonText = (activeContent?["buttonText"] as? String)
            ?? (subscribed ? "Subscribed" : "Subscribe")
        let channelID = channelID(from: channelSubscriptionCommandSource(from: activeContent))
            ?? channelID(from: channelSubscriptionCommandSource(from: (buttonViewModel["subscribeButtonContent"] as? JSONDictionary)))
            ?? channelID(from: channelSubscriptionCommandSource(from: (buttonViewModel["unsubscribeButtonContent"] as? JSONDictionary)))
            ?? header?.channel.channelId

        guard let channelID else { return nil }

        return SubscriptionState(
            channelId: channelID,
            buttonText: buttonText,
            subscribed: subscribed,
            enabled: !((buttonViewModel["disableSubscribeButton"] as? Bool) ?? false),
            subscriberCountText: header?.subscriberCountText
        )
    }

    let pageHeader = (((((data as? JSONDictionary)?["header"] as? JSONDictionary)?["pageHeaderRenderer"] as? JSONDictionary)?["content"] as? JSONDictionary)?["pageHeaderViewModel"] as? JSONDictionary)
    let commands = extractChannelSubscriptionCommands(from: data)
    let title = extractChannelSubscribeButtonTitle(from: pageHeader) ?? header?.subscribeButtonTitle
    let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let channelID = header?.channel.channelId,
          let normalizedTitle,
          normalizedTitle.isEmpty == false else {
        return nil
    }

    let normalizedKey = normalizedChannelControlTitle(normalizedTitle)
    let subscribed = normalizedKey.contains("subscribed")
        || normalizedKey.contains("підписан")
        || normalizedKey.contains("ви підписані")
    let enabled = commands["subscribe"] != nil || commands["unsubscribe"] != nil

    return SubscriptionState(
        channelId: channelID,
        buttonText: normalizedTitle,
        subscribed: subscribed,
        enabled: enabled,
        subscriberCountText: header?.subscriberCountText
    )
}

private func extractChannelSubscriptionCommands(from data: Any) -> [String: InnerTubeCommand?] {
    let pageHeader = (((((data as? JSONDictionary)?["header"] as? JSONDictionary)?["pageHeaderRenderer"] as? JSONDictionary)?["content"] as? JSONDictionary)?["pageHeaderViewModel"] as? JSONDictionary)
    let actions = pageHeader?["actions"]
    var result: [String: InnerTubeCommand?] = [
        "subscribe": nil,
        "unsubscribe": nil,
    ]

    if let buttonViewModel = firstChannelSubscribeButtonViewModel(from: data) {
        result["subscribe"] = channelSubscribeCommand(from: buttonViewModel)
        result["unsubscribe"] = channelUnsubscribeCommand(from: buttonViewModel)
        if result["subscribe"] != nil || result["unsubscribe"] != nil {
            return result
        }
    }

    guard let actions else { return result }

    visitJSONObjects(in: actions) { node in
        if result["subscribe"] == nil,
           let command = normalizeSubscribeEndpoint(node, unsubscribe: false) {
            result["subscribe"] = command
        }

        if result["unsubscribe"] == nil,
           let command = normalizeSubscribeEndpoint(node, unsubscribe: true) {
            result["unsubscribe"] = command
        }

        return (result["subscribe"] != nil && result["unsubscribe"] != nil) ? .stop : .continue
    }

    return result
}

private func firstChannelSubscribeButtonViewModel(from data: Any) -> JSONDictionary? {
    var result: JSONDictionary?

    visitJSONObjects(in: data) { node in
        guard let buttonViewModel = node["subscribeButtonViewModel"] as? JSONDictionary else {
            return .continue
        }

        result = buttonViewModel
        return .stop
    }

    return result
}

private func channelSubscriptionStateValue(in data: Any, key: String) -> Bool? {
    let mutations = ((((data as? JSONDictionary)?["frameworkUpdates"] as? JSONDictionary)?["entityBatchUpdate"] as? JSONDictionary)?["mutations"] as? [Any]) ?? []

    for mutation in mutations {
        guard let mutation = mutation as? JSONDictionary,
              (mutation["entityKey"] as? String) == key,
              let payload = mutation["payload"] as? JSONDictionary,
              let entity = payload["subscriptionStateEntity"] as? JSONDictionary,
              let subscribed = entity["subscribed"] as? Bool else {
            continue
        }
        return subscribed
    }

    return nil
}

private func currentChannelSubscribeContent(from buttonViewModel: JSONDictionary, subscribed: Bool) -> JSONDictionary? {
    let key = subscribed ? "unsubscribeButtonContent" : "subscribeButtonContent"
    return buttonViewModel[key] as? JSONDictionary
}

private func channelSubscriptionCommandSource(from content: JSONDictionary?) -> Any? {
    (((content?["onTapCommand"] as? JSONDictionary)?["innertubeCommand"] as? JSONDictionary))
}

private func channelSubscribeCommand(from buttonViewModel: JSONDictionary) -> InnerTubeCommand? {
    normalizeSubscribeEndpoint(
        channelSubscriptionCommandSource(from: buttonViewModel["subscribeButtonContent"] as? JSONDictionary),
        unsubscribe: false
    )
}

private func channelUnsubscribeCommand(from buttonViewModel: JSONDictionary) -> InnerTubeCommand? {
    let content = buttonViewModel["unsubscribeButtonContent"] as? JSONDictionary
    let command = channelSubscriptionCommandSource(from: content)

    if let direct = normalizeSubscribeEndpoint(command, unsubscribe: true) {
        return direct
    }

    let actions = ((((command as? JSONDictionary)?["signalServiceEndpoint"] as? JSONDictionary)?["actions"] as? [Any]) ?? [])
    for action in actions {
        if let command = normalizeSubscribeEndpoint(popupConfirmServiceEndpoint(from: action), unsubscribe: true) {
            return command
        }
    }

    let listItems = (((((((buttonViewModel["onShowSubscriptionOptions"] as? JSONDictionary)?["innertubeCommand"] as? JSONDictionary)?["showSheetCommand"] as? JSONDictionary)?["panelLoadingStrategy"] as? JSONDictionary)?["inlineContent"] as? JSONDictionary)?["sheetViewModel"] as? JSONDictionary)?["content"] as? JSONDictionary)
    let entries = ((listItems?["listViewModel"] as? JSONDictionary)?["listItems"] as? [Any]) ?? []
    for value in entries {
        guard let item = (value as? JSONDictionary)?["listItemViewModel"] as? JSONDictionary else { continue }
        let command = ((((item["rendererContext"] as? JSONDictionary)?["commandContext"] as? JSONDictionary)?["onTap"] as? JSONDictionary)?["innertubeCommand"])
        if let normalized = normalizeSubscribeEndpoint(command, unsubscribe: true) {
            return normalized
        }
        let actions = ((((command as? JSONDictionary)?["signalServiceEndpoint"] as? JSONDictionary)?["actions"] as? [Any]) ?? [])
        for action in actions {
            if let normalized = normalizeSubscribeEndpoint(popupConfirmServiceEndpoint(from: action), unsubscribe: true) {
                return normalized
            }
        }
    }

    return nil
}

private func extractChannelTabs(from data: Any) -> [ChannelTabSummary] {
    guard let tabs = (((data as? JSONDictionary)?["contents"] as? JSONDictionary)?["twoColumnBrowseResultsRenderer"] as? JSONDictionary)?["tabs"] as? [Any] else {
        return []
    }

    return tabs.compactMap { value in
        guard let container = value as? JSONDictionary else { return nil }
        let renderer = (container["tabRenderer"] as? JSONDictionary) ?? (container["expandableTabRenderer"] as? JSONDictionary)
        guard let renderer,
              let kind = parseChannelTabKind(from: renderer) else {
            return nil
        }
        return ChannelTabSummary(kind: kind, title: renderer["title"] as? String ?? kind.title)
    }
}

private func extractSelectedChannelTab(from data: Any) -> ChannelTabKind? {
    guard let tabs = (((data as? JSONDictionary)?["contents"] as? JSONDictionary)?["twoColumnBrowseResultsRenderer"] as? JSONDictionary)?["tabs"] as? [Any] else {
        return nil
    }

    for value in tabs {
        guard let container = value as? JSONDictionary else { continue }
        let renderer = (container["tabRenderer"] as? JSONDictionary) ?? (container["expandableTabRenderer"] as? JSONDictionary)
        guard let renderer, renderer["selected"] as? Bool == true else { continue }
        return parseChannelTabKind(from: renderer)
    }

    return nil
}

private func extractChannelBrowseControls(from data: Any) -> (sortOptions: [ChannelSortOption], filterOptions: [ChannelSortOption]) {
    var sortOptions: [ChannelSortOption] = []
    var filterGroups: [[ChannelSortOption]] = []
    var seenSortTitles = Set<String>()
    var seenFilterSignatures = Set<String>()

    visitJSONObjects(in: data) { node in
        guard let bar = node["chipBarViewModel"] as? JSONDictionary,
              let chips = bar["chips"] as? [Any] else {
            return .continue
        }

        var regularOptions: [ChannelSortOption] = []
        var barHasDropdownSort = false

        for value in chips {
            guard let viewModel = (value as? JSONDictionary)?["chipViewModel"] as? JSONDictionary else { continue }

            let dropdownOptions = extractChannelDropdownSortOptions(from: viewModel)
            if dropdownOptions.isEmpty == false {
                barHasDropdownSort = true
                for option in dropdownOptions where seenSortTitles.insert(option.title).inserted {
                    sortOptions.append(option)
                }
                continue
            }

            guard let title = viewModel["text"] as? String, !title.isEmpty else { continue }
            guard let command = ((viewModel["tapCommand"] as? JSONDictionary)?["innertubeCommand"] as? JSONDictionary),
                  let token = ((command["continuationCommand"] as? JSONDictionary)?["token"] as? String),
                  !token.isEmpty else {
                continue
            }

            regularOptions.append(ChannelSortOption(
                title: title,
                continuationToken: token,
                isSelected: viewModel["selected"] as? Bool ?? false
            ))
        }

        guard regularOptions.isEmpty == false else { return .continue }
        let signature = regularOptions.map(\.title).joined(separator: "|")
        guard seenFilterSignatures.insert(signature).inserted else { return .continue }

        if barHasDropdownSort {
            filterGroups.append(regularOptions)
        } else {
            switch classifyChannelControlGroup(regularOptions) {
            case .sort:
                for option in regularOptions where seenSortTitles.insert(option.title).inserted {
                    sortOptions.append(option)
                }
            case .filter:
                filterGroups.append(regularOptions)
            }
        }
        return .continue
    }

    var filterOptions: [ChannelSortOption] = []
    for group in filterGroups {
        for option in group where filterOptions.contains(where: { $0.title == option.title }) == false {
            filterOptions.append(option)
        }
    }

    return (sortOptions, filterOptions)
}

private func extractChannelDropdownSortOptions(from viewModel: JSONDictionary) -> [ChannelSortOption] {
    guard (viewModel["displayType"] as? String) == "CHIP_VIEW_MODEL_DISPLAY_TYPE_DROP_DOWN",
          let listItems = ((((((viewModel["tapCommand"] as? JSONDictionary)?["innertubeCommand"] as? JSONDictionary)?["showSheetCommand"] as? JSONDictionary)?["panelLoadingStrategy"] as? JSONDictionary)?["inlineContent"] as? JSONDictionary)?["sheetViewModel"] as? JSONDictionary)?["content"] as? JSONDictionary,
          let entries = (listItems["listViewModel"] as? JSONDictionary)?["listItems"] as? [Any] else {
        return []
    }

    return entries.compactMap { value in
        guard let item = (value as? JSONDictionary)?["listItemViewModel"] as? JSONDictionary else { return nil }
        guard let title = contentTextValue(from: item["title"]) ?? textValue(from: item["title"]), !title.isEmpty else { return nil }
        let commands = ((((item["rendererContext"] as? JSONDictionary)?["commandContext"] as? JSONDictionary)?["onTap"] as? JSONDictionary)?["innertubeCommand"] as? JSONDictionary)?["commandExecutorCommand"] as? JSONDictionary
        let token = extractContinuationTokenFromCommandExecutor(commands)
        guard let token, !token.isEmpty else { return nil }

        return ChannelSortOption(
            title: title,
            continuationToken: token,
            isSelected: item["isSelected"] as? Bool ?? false
        )
    }
}

private func extractContinuationTokenFromCommandExecutor(_ value: JSONDictionary?) -> String? {
    guard let commands = value?["commands"] as? [Any] else { return nil }
    for command in commands {
        guard let command = command as? JSONDictionary else { continue }
        if let token = ((command["continuationCommand"] as? JSONDictionary)?["token"] as? String), !token.isEmpty {
            return token
        }
    }
    return nil
}

private enum ChannelControlGroupKind {
    case sort
    case filter
}

private func classifyChannelControlGroup(_ options: [ChannelSortOption]) -> ChannelControlGroupKind {
    let normalizedTitles = options.map { normalizedChannelControlTitle($0.title) }
    let sortMatchCount = normalizedTitles.filter { isKnownChannelSortTitle($0) }.count

    if sortMatchCount == normalizedTitles.count, normalizedTitles.isEmpty == false {
        return .sort
    }

    if sortMatchCount >= 2 {
        return .sort
    }

    return .filter
}

private func normalizedChannelControlTitle(_ title: String) -> String {
    title
        .folding(options: .diacriticInsensitive, locale: .current)
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .joined()
}

private func isKnownChannelSortTitle(_ title: String) -> Bool {
    [
        "latest", "newest", "recent", "new",
        "popular",
        "oldest", "old",
        "нові", "новые", "нове", "новеиши", "найновіші",
        "популярні", "популярные",
        "найстаріші", "старые", "старі", "наистаріші"
    ].contains(title)
}

private func extractChannelContentItems(from data: Any) -> [ChannelContentItem] {
    let entries = flattenedChannelContentEntries(from: data)
    var items: [ChannelContentItem] = []
    var seen = Set<String>()

    for entry in entries {
        guard let item = parseChannelContentItem(from: entry) else { continue }
        guard seen.insert(item.id).inserted else { continue }
        items.append(item)
    }

    return items
}

private func extractChannelContentContinuationToken(from data: Any) -> String? {
    for list in channelContentLists(from: data) {
        var payloadCount = 0
        var pendingToken: String?

        for entry in flattenedChannelContentEntries(list) {
            if parseChannelContentItem(from: entry) != nil {
                payloadCount += 1
            } else if let token = continuationToken(in: entry), !token.isEmpty {
                pendingToken = token
            }
        }

        if payloadCount > 0, let pendingToken {
            return pendingToken
        }
    }

    return nil
}

private func extractChannelAbout(from data: Any) -> ChannelAbout? {
    var about: ChannelAbout?

    visitJSONObjects(in: data) { node in
        guard let renderer = node["aboutChannelRenderer"] as? JSONDictionary else { return .continue }
        guard let viewModel = ((renderer["metadata"] as? JSONDictionary)?["aboutChannelViewModel"] as? JSONDictionary) else {
            return .continue
        }

        about = ChannelAbout(
            description: viewModel["description"] as? String,
            canonicalChannelUrl: viewModel["canonicalChannelUrl"] as? String,
            displayCanonicalChannelUrl: viewModel["displayCanonicalChannelUrl"] as? String,
            joinedDateText: contentTextValue(from: viewModel["joinedDateText"]),
            subscriberCountText: viewModel["subscriberCountText"] as? String,
            videoCountText: viewModel["videoCountText"] as? String,
            viewCountText: viewModel["viewCountText"] as? String,
            country: viewModel["country"] as? String,
            linksLabel: viewModel["customLinksLabel"] as? String,
            links: extractChannelLinks(from: viewModel),
            businessEmailPrompt: extractBusinessEmailPrompt(from: viewModel["signInForBusinessEmail"]),
            businessEmailURL: extractCommandURL(from: viewModel["signInForBusinessEmail"])
        )
        return .stop
    }

    return about
}

private func extractChannelLinks(from viewModel: JSONDictionary) -> [ChannelLink] {
    let entries = viewModel["links"] as? [Any] ?? []

    return entries.compactMap { value in
        let renderer = (value as? JSONDictionary)?["channelExternalLinkViewModel"] as? JSONDictionary
            ?? value as? JSONDictionary
        guard let renderer else { return nil }

        let title = contentTextValue(from: renderer["title"])
            ?? textValue(from: renderer["title"])
            ?? contentTextValue(from: renderer["link"])
            ?? textValue(from: renderer["link"])
        guard let title, title.isEmpty == false else { return nil }

        let displayURL = contentTextValue(from: renderer["link"])
            ?? textValue(from: renderer["link"])
            ?? extractCommandURL(from: renderer["link"])
        guard let url = normalizedExternalURL(extractCommandURL(from: renderer["link"]) ?? displayURL) else {
            return nil
        }

        return ChannelLink(
            title: title,
            url: url,
            faviconUrl: bestThumbnailURL(sourceThumbnails(from: renderer["favicon"]))
                ?? bestThumbnailURL(thumbnails(from: renderer["favicon"]))
        )
    }
}

private func extractBusinessEmailPrompt(from value: Any?) -> String? {
    guard let prompt = contentTextValue(from: value) ?? textValue(from: value) else {
        return nil
    }

    let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
}

private func extractCommandURL(from value: Any?) -> String? {
    if let object = value as? JSONDictionary {
        if let url = normalizeURL(((object["commandMetadata"] as? JSONDictionary)?["webCommandMetadata"] as? JSONDictionary)?["url"]) {
            return url
        }

        if let url = normalizeURL((object["urlEndpoint"] as? JSONDictionary)?["url"]) {
            return url
        }

        if let commandRuns = object["commandRuns"] as? [Any] {
            for run in commandRuns {
                guard let runObject = run as? JSONDictionary else { continue }
                if let url = extractCommandURL(from: (runObject["onTap"] as? JSONDictionary)?["innertubeCommand"]) {
                    return url
                }
            }
        }

        if let runs = object["runs"] as? [Any] {
            for run in runs {
                guard let runObject = run as? JSONDictionary else { continue }
                if let url = extractCommandURL(from: runObject["navigationEndpoint"]) {
                    return url
                }
            }
        }
    }

    return nil
}

private func normalizedExternalURL(_ value: String?) -> String? {
    guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines), rawValue.isEmpty == false else {
        return nil
    }

    if rawValue.hasPrefix("http://") || rawValue.hasPrefix("https://") || rawValue.hasPrefix("mailto:") {
        return rawValue
    }

    if rawValue.hasPrefix("/") {
        return "https://www.youtube.com\(rawValue)"
    }

    if rawValue.hasPrefix("//") {
        return "https:\(rawValue)"
    }

    return "https://\(rawValue)"
}

private func parseChannelContentItem(from value: Any) -> ChannelContentItem? {
    guard let node = value as? JSONDictionary else { return nil }

    if let lockup = node["lockupViewModel"] as? JSONDictionary {
        if let video = parseLockupVideoItem(lockup) {
            return .video(video)
        }
        if let playlist = parseLockupPlaylistItem(lockup) {
            return .playlist(playlist)
        }
    }

    if let shorts = node["shortsLockupViewModel"] as? JSONDictionary,
       let video = parseShortsVideoItem(shorts) {
        return .video(video)
    }

    if let postThread = node["backstagePostThreadRenderer"] as? JSONDictionary,
       let post = parseBackstagePost(postThread) {
        return .post(post)
    }

    if let playlistRenderer = node["playlistRenderer"] as? JSONDictionary,
       let playlist = parsePlaylistRendererItem(playlistRenderer) {
        return .playlist(playlist)
    }

    let renderer = (node["videoRenderer"] as? JSONDictionary)
        ?? (node["gridVideoRenderer"] as? JSONDictionary)
        ?? (node["videoCardRenderer"] as? JSONDictionary)
        ?? (node["compactVideoRenderer"] as? JSONDictionary)
    if let renderer, let video = parseStandardVideoItem(renderer) {
        return .video(video)
    }

    return nil
}

private func parseShortsVideoItem(_ renderer: JSONDictionary) -> VideoItem? {
    let command = ((renderer["onTap"] as? JSONDictionary)?["innertubeCommand"] as? JSONDictionary)
    let reelEndpoint = command?["reelWatchEndpoint"] as? JSONDictionary
    guard let videoID = reelEndpoint?["videoId"] as? String, !videoID.isEmpty else {
        return nil
    }

    return VideoItem(
        id: videoID,
        title: contentTextValue(from: (renderer["overlayMetadata"] as? JSONDictionary)?["primaryText"]) ?? "Short",
        channel: nil,
        channelId: nil,
        channelAvatarUrl: nil,
        viewCountText: contentTextValue(from: (renderer["overlayMetadata"] as? JSONDictionary)?["secondaryText"]),
        publishedTimeText: nil,
        durationText: nil,
        thumbnails: thumbnails(from: reelEndpoint?["thumbnail"]),
        tags: extractVideoTags(from: renderer)
    )
}

private func parsePlaylistRendererItem(_ renderer: JSONDictionary) -> PlaylistSummary? {
    guard let playlistID = renderer["playlistId"] as? String, !playlistID.isEmpty else {
        return nil
    }

    return PlaylistSummary(
        playlistId: playlistID,
        title: textValue(from: renderer["title"]) ?? "Playlist",
        privacy: nil,
        itemCountText: textValue(from: renderer["videoCountText"]) ?? (renderer["videoCount"] as? String).map { "\($0) videos" },
        updatedText: nil,
        thumbnails: thumbnails(from: (renderer["thumbnails"] as? [Any])?.first)
    )
}

private func parseBackstagePost(_ thread: JSONDictionary) -> ChannelPost? {
    guard let renderer = ((thread["post"] as? JSONDictionary)?["backstagePostRenderer"] as? JSONDictionary),
          let postID = renderer["postId"] as? String,
          !postID.isEmpty,
          let content = textValue(from: renderer["contentText"]) else {
        return nil
    }

    let actionButtons = (renderer["actionButtons"] as? JSONDictionary)?["commentActionButtonsRenderer"] as? JSONDictionary
    let attachedVideoRenderer = ((renderer["backstageAttachment"] as? JSONDictionary)?["videoRenderer"] as? JSONDictionary)

    return ChannelPost(
        id: postID,
        author: textValue(from: renderer["authorText"]) ?? "Unknown channel",
        authorChannelId: channelID(from: renderer["authorEndpoint"]),
        authorAvatarUrl: firstThumbnailURL(thumbnails(from: renderer["authorThumbnail"])),
        content: content,
        publishedTimeText: textValue(from: renderer["publishedTimeText"]),
        likeCountText: textValue(from: renderer["voteCount"]),
        commentCountText: textValue(from: ((actionButtons?["replyButton"] as? JSONDictionary)?["buttonRenderer"] as? JSONDictionary)?["text"]),
        attachedVideo: attachedVideoRenderer.flatMap(parseStandardVideoItem)
    )
}

private func parseChannelTabKind(from renderer: JSONDictionary) -> ChannelTabKind? {
    let browseEndpoint = (renderer["endpoint"] as? JSONDictionary)?["browseEndpoint"] as? JSONDictionary
    let params = (browseEndpoint?["params"] as? String) ?? ""

    if params.hasPrefix("EgZ2aWRlb3M") {
        return .videos
    }
    if params.hasPrefix("EgZzaG9ydHM") || params.hasPrefix("EgZzaG9ydHP") {
        return .shorts
    }
    if params.hasPrefix("EgdzdHJlYW1z") {
        return .live
    }
    if params.hasPrefix("EglwbGF5bGlzdHM") || params.hasPrefix("EglwbGF5bGlzdHP") {
        return .playlists
    }
    if params.hasPrefix("EgVwb3N0cw") || params.hasPrefix("EgVwb3N0c") {
        return .posts
    }
    if params.hasPrefix("EgZzZWFyY2g") {
        return .search
    }

    let title = (renderer["title"] as? String)?.lowercased() ?? ""
    switch title {
    case "videos":
        return .videos
    case "shorts":
        return .shorts
    case "live":
        return .live
    case "playlists":
        return .playlists
    case "posts":
        return .posts
    case "search":
        return .search
    default:
        return nil
    }
}

private func extractChannelAboutContinuationToken(from pageHeader: JSONDictionary?) -> String? {
    let descriptionPreview = ((pageHeader?["description"] as? JSONDictionary)?["descriptionPreviewViewModel"] as? JSONDictionary)
    let rendererContext = (descriptionPreview?["rendererContext"] as? JSONDictionary)
    let commandContext = (rendererContext?["commandContext"] as? JSONDictionary)

    guard let onTap = commandContext?["onTap"] as? JSONDictionary,
          let innerTubeCommand = onTap["innertubeCommand"] as? JSONDictionary else {
        return nil
    }

    return (((((((innerTubeCommand["showEngagementPanelEndpoint"] as? JSONDictionary)?["engagementPanel"] as? JSONDictionary)?["engagementPanelSectionListRenderer"] as? JSONDictionary)?["content"] as? JSONDictionary)?["sectionListRenderer"] as? JSONDictionary)?["contents"] as? [Any])?.first as? JSONDictionary)
        .flatMap { (($0["itemSectionRenderer"] as? JSONDictionary)?["contents"] as? [Any])?.first }
        .flatMap(continuationToken(in:))
}

private func selectedChannelTabContentRoot(from data: Any) -> JSONDictionary? {
    guard let tabs = (((data as? JSONDictionary)?["contents"] as? JSONDictionary)?["twoColumnBrowseResultsRenderer"] as? JSONDictionary)?["tabs"] as? [Any] else {
        return nil
    }

    for value in tabs {
        guard let container = value as? JSONDictionary else { continue }
        let renderer = (container["tabRenderer"] as? JSONDictionary) ?? (container["expandableTabRenderer"] as? JSONDictionary)
        guard let renderer,
              renderer["selected"] as? Bool == true,
              let content = renderer["content"] as? JSONDictionary else {
            continue
        }
        return content
    }

    return nil
}

private func channelContentLists(from data: Any) -> [[Any]] {
    var lists: [[Any]] = []

    if let root = selectedChannelTabContentRoot(from: data) {
        if let contents = ((root["richGridRenderer"] as? JSONDictionary)?["contents"] as? [Any]) {
            lists.append(contents)
        }
        if let contents = ((root["sectionListRenderer"] as? JSONDictionary)?["contents"] as? [Any]) {
            lists.append(contents)
        }
    }

    visitJSONObjects(in: data) { node in
        let listsToAppend = continuationLists(from: node)
        if !listsToAppend.isEmpty {
            lists.append(contentsOf: listsToAppend)
        }
        return .continue
    }

    return lists
}

private func flattenedChannelContentEntries(from data: Any) -> [Any] {
    channelContentLists(from: data).flatMap(flattenedChannelContentEntries)
}

private func flattenedChannelContentEntries(_ entries: [Any]) -> [Any] {
    var flattened: [Any] = []

    for entry in entries {
        guard let object = entry as? JSONDictionary else { continue }

        if let itemSection = object["itemSectionRenderer"] as? JSONDictionary,
           let contents = itemSection["contents"] as? [Any] {
            flattened.append(contentsOf: flattenedChannelContentEntries(contents))
            continue
        }

        if let gridRenderer = object["gridRenderer"] as? JSONDictionary {
            if let items = gridRenderer["items"] as? [Any] {
                flattened.append(contentsOf: flattenedChannelContentEntries(items))
            }
            if let continuations = gridRenderer["continuations"] as? [Any] {
                flattened.append(contentsOf: continuations)
            }
            continue
        }

        if let horizontalList = object["horizontalListRenderer"] as? JSONDictionary,
           let items = horizontalList["items"] as? [Any] {
            flattened.append(contentsOf: flattenedChannelContentEntries(items))
            continue
        }

        if let shelfRenderer = object["shelfRenderer"] as? JSONDictionary,
           let content = shelfRenderer["content"] {
            flattened.append(contentsOf: flattenedChannelContentEntries([content]))
            continue
        }

        if let richItem = object["richItemRenderer"] as? JSONDictionary,
           let content = richItem["content"] {
            flattened.append(content)
            continue
        }

        if object["chipBarViewModel"] != nil {
            continue
        }

        flattened.append(object)
    }

    return flattened
}

private func extractVideoItems(from data: Any, limit: Int = 120) -> [VideoItem] {
    var items: [VideoItem] = []
    var seen = Set<String>()

    visitJSONObjects(in: data) { node in
        if let lockup = node["lockupViewModel"] as? JSONDictionary,
           let item = parseLockupVideoItem(lockup),
           seen.insert(item.id).inserted {
            items.append(item)
            return items.count >= limit ? .stop : .continue
        }

        let renderer = (node["videoRenderer"] as? JSONDictionary)
            ?? (node["gridVideoRenderer"] as? JSONDictionary)
            ?? (node["videoCardRenderer"] as? JSONDictionary)
            ?? (node["compactVideoRenderer"] as? JSONDictionary)
        guard let renderer,
              let item = parseStandardVideoItem(renderer),
              seen.insert(item.id).inserted else {
            return .continue
        }

        items.append(item)

        return items.count >= limit ? .stop : .continue
    }

    return items
}

private func extractHistoryItems(from data: Any, limit: Int = 200) -> [VideoItem] {
    Array(extractHistoryVideoRecords(from: data, limit: limit).map(\.item).prefix(limit))
}

private func extractHistoryVideoRecords(from data: Any, limit: Int = 200) -> [HistoryVideoRecord] {
    var records: [HistoryVideoRecord] = []
    var seen = Set<String>()

    for section in historyItemSectionRenderers(from: data) {
        let headerTitle = historySectionTitle(from: section["header"])
        for (indexInSection, content) in ((section["contents"] as? [Any]) ?? []).enumerated() {
            guard let content = content as? JSONDictionary else { continue }

            if let lockup = content["lockupViewModel"] as? JSONDictionary,
               let item = parseLockupVideoItem(lockup),
               seen.insert(item.id).inserted {
                records.append(
                    HistoryVideoRecord(
                        item: item,
                        sectionTitle: headerTitle,
                        indexInSection: indexInSection,
                        deleteCommand: extractHistoryDeleteCommand(from: lockup)
                    )
                )
                if records.count >= limit {
                    return records
                }
                continue
            }

            let renderer = (content["videoRenderer"] as? JSONDictionary)
                ?? (content["gridVideoRenderer"] as? JSONDictionary)
                ?? (content["videoCardRenderer"] as? JSONDictionary)
                ?? (content["compactVideoRenderer"] as? JSONDictionary)
            guard let renderer,
                  let item = parseStandardVideoItem(renderer),
                  seen.insert(item.id).inserted else {
                continue
            }

            records.append(
                HistoryVideoRecord(
                    item: item,
                    sectionTitle: headerTitle,
                    indexInSection: indexInSection,
                    deleteCommand: extractHistoryDeleteCommand(from: renderer)
                )
            )
            if records.count >= limit {
                return records
            }
        }
    }

    if records.isEmpty {
        visitJSONObjects(in: data) { node in
            if let lockup = node["lockupViewModel"] as? JSONDictionary,
               let item = parseLockupVideoItem(lockup),
               seen.insert(item.id).inserted {
                records.append(
                    HistoryVideoRecord(
                        item: item,
                        sectionTitle: nil,
                        indexInSection: records.count,
                        deleteCommand: extractHistoryDeleteCommand(from: lockup)
                    )
                )
                return records.count >= limit ? .stop : .continue
            }
            return .continue
        }
    }

    return records
}

private func historyItemSectionRenderers(from data: Any) -> [JSONDictionary] {
    var sections: [JSONDictionary] = []

    visitJSONObjects(in: data) { node in
        guard let renderer = node["itemSectionRenderer"] as? JSONDictionary else { return .continue }
        guard let contents = renderer["contents"] as? [Any], contents.isEmpty == false else { return .continue }
        sections.append(renderer)
        return .continue
    }

    return sections
}

private func historySectionTitle(from value: Any?) -> String? {
    guard let header = value as? JSONDictionary else { return nil }
    if let renderer = header["itemSectionHeaderRenderer"] as? JSONDictionary {
        return textValue(from: renderer["title"]) ?? contentTextValue(from: renderer["title"])
    }
    return nil
}

private func extractPlaylistSummaries(from data: Any, limit: Int = 120) -> [PlaylistSummary] {
    var items: [PlaylistSummary] = []
    var seen = Set<String>()

    visitJSONObjects(in: data) { node in
        guard let lockup = node["lockupViewModel"] as? JSONDictionary else { return .continue }
        guard let item = parseLockupPlaylistItem(lockup) else { return .continue }
        guard seen.insert(item.playlistId).inserted else { return .continue }
        items.append(item)
        return items.count >= limit ? .stop : .continue
    }

    return items
}

private func extractBrowseIDsFromGuide(from data: Any, limit: Int = 6) -> [String] {
    var browseIDs: [String] = []

    visitJSONObjects(in: data) { node in
        guard let browseEndpoint = node["browseEndpoint"] as? JSONDictionary else { return .continue }
        guard let browseID = browseEndpoint["browseId"] as? String, browseID.hasPrefix("UC"), !browseIDs.contains(browseID) else {
            return .continue
        }

        browseIDs.append(browseID)
        return browseIDs.count >= limit ? .stop : .continue
    }

    return browseIDs
}

private func extractContinuationToken(from data: Any) -> String? {
    var result: String?

    visitJSONObjects(in: data) { node in
        if let token = ((node["continuationCommand"] as? JSONDictionary)?["token"] as? String), !token.isEmpty {
            result = token
            return .stop
        }

        if let token = ((((node["continuationEndpoint"] as? JSONDictionary)?["continuationCommand"] as? JSONDictionary)?["token"] as? String)), !token.isEmpty {
            result = token
            return .stop
        }

        if let token = ((node["nextContinuationData"] as? JSONDictionary)?["continuation"] as? String), !token.isEmpty {
            result = token
            return .stop
        }

        return .continue
    }

    return result
}

private func extractRelatedVideos(from data: Any, currentVideoID: String?, limit: Int = 12) -> [VideoItem] {
    var items: [VideoItem] = []
    var seen = Set<String>()

    visitJSONObjects(in: data) { node in
        guard let lockup = node["lockupViewModel"] as? JSONDictionary else { return .continue }
        guard (lockup["contentType"] as? String) == "LOCKUP_CONTENT_TYPE_VIDEO" else { return .continue }
        guard let videoID = lockup["contentId"] as? String, !videoID.isEmpty else { return .continue }
        guard videoID != currentVideoID, seen.insert(videoID).inserted else { return .continue }

        let metadataRows =
            ((((lockup["metadata"] as? JSONDictionary)?["lockupMetadataViewModel"] as? JSONDictionary)?["metadata"] as? JSONDictionary)?["contentMetadataViewModel"] as? JSONDictionary)?["metadataRows"] as? [Any] ?? []
        let firstRow = metadataRows.indices.contains(0) ? rowTextParts(metadataRows[0]) : []
        let secondRow = metadataRows.indices.contains(1) ? rowTextParts(metadataRows[1]) : []
        let metadata = (lockup["metadata"] as? JSONDictionary)?["lockupMetadataViewModel"] as? JSONDictionary
        let title = contentTextValue(from: lockup["title"])
            ?? contentTextValue(from: metadata?["title"])
            ?? "Untitled"
        let thumbnailImage = ((lockup["contentImage"] as? JSONDictionary)?["thumbnailViewModel"] as? JSONDictionary)?["image"]

        items.append(
            VideoItem(
                id: videoID,
                title: title,
                channel: firstRow.first,
                channelId: channelID(from: lockup),
                channelAvatarUrl: channelAvatarURL(from: lockup),
                viewCountText: secondRow.first,
                publishedTimeText: secondRow.count > 1 ? secondRow[1] : nil,
                durationText: extractLockupDuration(from: lockup),
                thumbnails: sourceThumbnails(from: thumbnailImage),
                tags: extractVideoTags(from: lockup)
            )
        )

        return items.count >= limit ? .stop : .continue
    }

    if items.count < limit {
        for item in extractVideoItems(from: data, limit: limit + 8) where item.id != currentVideoID && !seen.contains(item.id) {
            seen.insert(item.id)
            items.append(item)
            if items.count >= limit { break }
        }
    }

    return items
}

private func extractRelatedContinuationToken(from data: Any) -> String? {
    var result: String?

    visitJSONObjects(in: data) { node in
        let contentLists = continuationLists(from: node)
        for contents in contentLists {
            var hasVideoPayload = false
            var token: String?

            for item in contents {
                if itemHasVideoPayload(item) {
                    hasVideoPayload = true
                }

                if let continuation = (((item as? JSONDictionary)?["continuationItemRenderer"] as? JSONDictionary)?["continuationEndpoint"] as? JSONDictionary)?["continuationCommand"] as? JSONDictionary,
                   let rawToken = continuation["token"] as? String,
                   !rawToken.isEmpty {
                    token = rawToken
                }
            }

            if hasVideoPayload, let token {
                result = token
                return .stop
            }
        }

        return .continue
    }

    return result
}

private func extractWatchMetadata(from data: Any) -> [String: String] {
    var metadata: [String: String] = [:]

    visitJSONObjects(in: data) { node in
        if let primary = node["videoPrimaryInfoRenderer"] as? JSONDictionary {
            metadata["title"] = metadata["title"] ?? textValue(from: primary["title"])
            metadata["publishedTimeText"] = metadata["publishedTimeText"] ?? textValue(from: primary["relativeDateText"])
            metadata["publishedDateText"] = metadata["publishedDateText"] ?? textValue(from: primary["dateText"])
            let viewCount = (((primary["viewCount"] as? JSONDictionary)?["videoViewCountRenderer"] as? JSONDictionary)?["viewCount"])
            metadata["viewCountText"] = metadata["viewCountText"] ?? textValue(from: viewCount)
        }

        if let secondary = node["videoSecondaryInfoRenderer"] as? JSONDictionary,
           let owner = ((secondary["owner"] as? JSONDictionary)?["videoOwnerRenderer"] as? JSONDictionary) {
            metadata["channel"] = metadata["channel"] ?? textValue(from: owner["title"])
            metadata["subscriberCountText"] = metadata["subscriberCountText"] ?? textValue(from: owner["subscriberCountText"])
            metadata["channelId"] = metadata["channelId"] ?? ((((owner["navigationEndpoint"] as? JSONDictionary)?["browseEndpoint"] as? JSONDictionary)?["browseId"] as? String))
            metadata["channelAvatarUrl"] = metadata["channelAvatarUrl"] ?? firstThumbnailURL(thumbnails(from: owner["thumbnail"]))
        }

        if let descriptionHeader = node["videoDescriptionHeaderRenderer"] as? JSONDictionary {
            metadata["channel"] = metadata["channel"] ?? textValue(from: descriptionHeader["channel"])
            metadata["publishedDateText"] = metadata["publishedDateText"] ?? textValue(from: descriptionHeader["publishDate"])
            metadata["viewCountText"] = metadata["viewCountText"] ?? textValue(from: descriptionHeader["views"])
            metadata["channelId"] = metadata["channelId"] ?? ((((descriptionHeader["channelNavigationEndpoint"] as? JSONDictionary)?["browseEndpoint"] as? JSONDictionary)?["browseId"] as? String))
            metadata["channelAvatarUrl"] = metadata["channelAvatarUrl"] ?? firstThumbnailURL(thumbnails(from: descriptionHeader["channelThumbnail"]))

            if let factoids = descriptionHeader["factoid"] as? [Any] {
                for factoidValue in factoids {
                    guard let factoidContainer = factoidValue as? JSONDictionary else { continue }
                    let factoid = (factoidContainer["factoidRenderer"] as? JSONDictionary)
                        ?? ((((factoidContainer["viewCountFactoidRenderer"] as? JSONDictionary)?["factoid"] as? JSONDictionary)?["factoidRenderer"] as? JSONDictionary))
                    guard let factoid else { continue }
                    let label = textValue(from: factoid["label"]) ?? ""
                    let value = textValue(from: factoid["value"])
                    guard let value else { continue }
                    if label == "Likes" {
                        metadata["likeCountText"] = metadata["likeCountText"] ?? value
                    } else if label == "Views" {
                        metadata["viewCountText"] = metadata["viewCountText"] ?? value
                    }
                }
            }
        }

        if let descriptionBody = node["expandableVideoDescriptionBodyRenderer"] as? JSONDictionary {
            metadata["description"] = metadata["description"] ?? contentTextValue(from: descriptionBody["attributedDescriptionBodyText"])
        }

        if let panel = node["engagementPanelSectionListRenderer"] as? JSONDictionary,
           (panel["targetId"] as? String) == "engagement-panel-comments-section" {
            let contextualInfo = ((panel["header"] as? JSONDictionary)?["engagementPanelTitleHeaderRenderer"] as? JSONDictionary)?["contextualInfo"]
            metadata["commentCountText"] = metadata["commentCountText"] ?? textValue(from: contextualInfo)
        }

        return .continue
    }

    return metadata
}

private func extractChannelAvatarURL(from data: Any) -> String? {
    channelAvatarURL(from: data)
}

private func extractPlaylistItemActionCommand(from data: Any, setVideoID: String, action: String) -> InnerTubeCommand? {
    var command: InnerTubeCommand?

    visitJSONObjects(in: data) { node in
        guard let renderer = node["playlistVideoRenderer"] as? JSONDictionary else { return .continue }
        guard (renderer["setVideoId"] as? String) == setVideoID else { return .continue }

        for menuItem in menuServiceItemRenderers(from: renderer["menu"]) {
            guard let candidate = normalizePlaylistEditEndpoint(menuItem["serviceEndpoint"]) else { continue }
            guard let actions = candidate.payload["actions"] as? [Any], let firstAction = actions.first as? JSONDictionary else { continue }
            if (firstAction["action"] as? String) == action {
                command = candidate
                return .stop
            }
        }

        return .stop
    }

    return command
}

private func extractPlaylistFeed(from data: Any, playlistID: String) -> PlaylistFeed {
    var title = "Playlist"
    var ownerText: String?
    var privacy: String?
    var itemCountText: String?

    visitJSONObjects(in: data) { node in
        guard let header = node["playlistHeaderRenderer"] as? JSONDictionary else { return .continue }
        title = textValue(from: header["title"]) ?? title
        ownerText = ownerText ?? textValue(from: header["ownerText"])
        privacy = privacy ?? (header["privacy"] as? String)
        itemCountText = itemCountText ?? textValue(from: header["numVideosText"])
        return .stop
    }

    var items: [VideoItem] = []
    var seen = Set<String>()

    visitJSONObjects(in: data) { node in
        guard let renderer = node["playlistVideoRenderer"] as? JSONDictionary else { return .continue }
        guard let videoID = renderer["videoId"] as? String, !videoID.isEmpty else { return .continue }
        guard seen.insert(videoID).inserted else { return .continue }

        let menuFlags = playlistItemMenuFlags(from: renderer["menu"])
        items.append(
            VideoItem(
                id: videoID,
                title: textValue(from: renderer["title"]) ?? "Untitled",
                channel: textValue(from: renderer["shortBylineText"]) ?? textValue(from: renderer["longBylineText"]),
                channelId: channelID(from: renderer),
                channelAvatarUrl: channelAvatarURL(from: renderer),
                viewCountText: textValue(from: renderer["videoInfo"]),
                publishedTimeText: textValue(from: renderer["publishedTimeText"]),
                durationText: textValue(from: renderer["lengthText"]),
                thumbnails: thumbnails(from: renderer["thumbnail"]),
                playlistSetVideoId: renderer["setVideoId"] as? String,
                playlistIndexText: textValue(from: renderer["index"]),
                playlistSelected: renderer.keys.contains("selected") ? (renderer["selected"] as? Bool) : nil,
                playlistCanRemove: menuFlags.remove,
                playlistCanMoveToTop: menuFlags.moveTop,
                playlistCanMoveToBottom: menuFlags.moveBottom,
                tags: extractVideoTags(from: renderer)
            )
        )

        return .continue
    }

    return PlaylistFeed(
        playlistId: playlistID,
        title: title,
        ownerText: ownerText,
        privacy: privacy,
        itemCountText: itemCountText,
        items: items,
        continuation: extractContinuationToken(from: data)
    )
}

private func extractSubscriptionState(from data: Any, metadata: [String: String]) -> SubscriptionState? {
    var state: SubscriptionState?

    visitJSONObjects(in: data) { node in
        guard let subscribeButton = node["subscribeButton"] as? JSONDictionary else { return .continue }
        guard let renderer = subscribeButton["subscribeButtonRenderer"] as? JSONDictionary else { return .continue }
        guard let channelID = renderer["channelId"] as? String, !channelID.isEmpty else { return .continue }

        state = SubscriptionState(
            channelId: channelID,
            buttonText: textValue(from: renderer["buttonText"]),
            subscribed: renderer["subscribed"] as? Bool ?? false,
            enabled: renderer["enabled"] as? Bool ?? false,
            subscriberCountText: metadata["subscriberCountText"]
        )
        return .stop
    }

    return state
}

private func extractRatingState(from data: Any) -> RatingState? {
    var state: RatingState?

    visitJSONObjects(in: data) { node in
        guard let viewModel = node["segmentedLikeDislikeButtonViewModel"] as? JSONDictionary else { return .continue }

        let likeButton = ((((viewModel["likeButtonViewModel"] as? JSONDictionary)?["likeButtonViewModel"] as? JSONDictionary)?["toggleButtonViewModel"] as? JSONDictionary)?["toggleButtonViewModel"] as? JSONDictionary)
        let dislikeButton = ((((viewModel["dislikeButtonViewModel"] as? JSONDictionary)?["dislikeButtonViewModel"] as? JSONDictionary)?["toggleButtonViewModel"] as? JSONDictionary)?["toggleButtonViewModel"] as? JSONDictionary)

        guard likeButton != nil, dislikeButton != nil else { return .continue }

        let likeVM = ((viewModel["likeButtonViewModel"] as? JSONDictionary)?["likeButtonViewModel"] as? JSONDictionary)
        var status = (((likeVM?["likeStatusEntity"] as? JSONDictionary)?["likeStatus"] as? String) ?? "INDIFFERENT")
        if !["LIKE", "DISLIKE", "INDIFFERENT"].contains(status) {
            status = "INDIFFERENT"
        }

        let likeCount = (((((likeButton?["defaultButtonViewModel"] as? JSONDictionary)?["buttonViewModel"] as? JSONDictionary)?["title"] as? String)))
        state = RatingState(status: status, likeCountText: likeCount)
        return .stop
    }

    return state
}

private func extractWatchPageSaveCommand(from data: Any) -> InnerTubeCommand? {
    var command: InnerTubeCommand?

    visitJSONObjects(in: data) { node in
        if let normalized = normalizeAddToPlaylistEndpoint(node) {
            command = normalized
            return .stop
        }

        let flexibleItems = ((((node["videoActions"] as? JSONDictionary)?["menuRenderer"] as? JSONDictionary)?["flexibleItems"] as? [Any])) ?? []
        guard !flexibleItems.isEmpty else { return .continue }

        for item in flexibleItems {
            guard let renderer = ((item as? JSONDictionary)?["menuFlexibleItemRenderer"] as? JSONDictionary) else { continue }

            let serviceEndpoint = ((((renderer["menuItem"] as? JSONDictionary)?["menuServiceItemRenderer"] as? JSONDictionary)?["serviceEndpoint"]))
            if let normalized = normalizeAddToPlaylistEndpoint(serviceEndpoint) {
                command = normalized
                return .stop
            }

            let commands = (((((renderer["topLevelButton"] as? JSONDictionary)?["buttonViewModel"] as? JSONDictionary)?["onTap"] as? JSONDictionary)?["serialCommand"] as? JSONDictionary)?["commands"] as? [Any]) ?? []
            if let normalized = normalizeAddToPlaylistEndpoint(findInnerTubeCommand(in: commands, endpointKey: "addToPlaylistServiceEndpoint")) {
                command = normalized
                return .stop
            }
        }

        return .continue
    }

    return command
}

private func extractPlaylistOptions(from data: Any) -> [PlaylistOption] {
    var options: [PlaylistOption] = []
    var seen = Set<String>()

    visitJSONObjects(in: data) { node in
        guard let renderer = node["playlistAddToOptionRenderer"] as? JSONDictionary else { return .continue }
        guard let playlistID = renderer["playlistId"] as? String, !playlistID.isEmpty else { return .continue }
        guard seen.insert(playlistID).inserted else { return .continue }
        guard let title = textValue(from: renderer["title"]) else { return .continue }

        let containsSelectedVideos = (renderer["containsSelectedVideos"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "NONE"
        options.append(
            PlaylistOption(
                playlistId: playlistID,
                title: title,
                privacy: renderer["privacy"] as? String,
                containsSelectedVideos: containsSelectedVideos,
                saved: containsSelectedVideos == "ALL"
            )
        )
        return .continue
    }

    return options
}

private func extractPlaylistOptionCommands(from data: Any) -> [String: [String: InnerTubeCommand?]] {
    var commands: [String: [String: InnerTubeCommand?]] = [:]

    visitJSONObjects(in: data) { node in
        guard let renderer = node["playlistAddToOptionRenderer"] as? JSONDictionary else { return .continue }
        guard let playlistID = renderer["playlistId"] as? String, !playlistID.isEmpty else { return .continue }

        commands[playlistID] = [
            "add": normalizePlaylistEditEndpoint(renderer["addToPlaylistServiceEndpoint"]),
            "remove": normalizePlaylistEditEndpoint(renderer["removeFromPlaylistServiceEndpoint"]),
        ]
        return .continue
    }

    return commands
}

private func extractSubscriptionCommands(from data: Any) -> [String: InnerTubeCommand?] {
    var result: [String: InnerTubeCommand?] = [
        "subscribe": nil,
        "unsubscribe": nil,
    ]

    visitJSONObjects(in: data) { node in
        guard let subscribeButton = node["subscribeButton"] as? JSONDictionary else { return .continue }
        guard let renderer = subscribeButton["subscribeButtonRenderer"] as? JSONDictionary else { return .continue }

        let subscribeEndpoints = renderer["onSubscribeEndpoints"] as? [Any] ?? []
        result["subscribe"] = normalizeSubscribeEndpoint(firstDictionary(in: subscribeEndpoints), unsubscribe: false)

        let unsubscribeEndpoints = renderer["onUnsubscribeEndpoints"] as? [Any] ?? []
        let unsubscribeEndpoint = firstDictionary(in: unsubscribeEndpoints)
        var unsubscribeCommand = normalizeSubscribeEndpoint(unsubscribeEndpoint, unsubscribe: true)

        if unsubscribeCommand == nil, let unsubscribeEndpoint {
            let actions = ((((unsubscribeEndpoint["signalServiceEndpoint"] as? JSONDictionary)?["actions"] as? [Any])) ?? [])
            if let signalAction = firstDictionary(in: actions) {
                let confirmServiceEndpoint = popupConfirmServiceEndpoint(from: signalAction)
                unsubscribeCommand = normalizeSubscribeEndpoint(confirmServiceEndpoint, unsubscribe: true)
            }
        }

        if unsubscribeCommand == nil {
            let notificationButton = renderer["notificationPreferenceButton"] as? JSONDictionary
            let commandExecutorSource =
                ((notificationButton?["subscriptionNotificationToggleButtonRenderer"] as? JSONDictionary)?["command"] as? JSONDictionary)?["commandExecutorCommand"] as? JSONDictionary
            let commandExecutor = commandExecutorSource?["commands"] as? [Any] ?? []
            let signalServiceEndpoint = findInnerTubeCommand(in: commandExecutor, endpointKey: "signalServiceEndpoint")?["signalServiceEndpoint"]
            let actions = ((signalServiceEndpoint as? JSONDictionary)?["actions"] as? [Any]) ?? []
            if let signalAction = firstDictionary(in: actions) {
                let confirmServiceEndpoint = popupConfirmServiceEndpoint(from: signalAction)
                unsubscribeCommand = normalizeSubscribeEndpoint(confirmServiceEndpoint, unsubscribe: true)
            }
        }

        result["unsubscribe"] = unsubscribeCommand
        return .stop
    }

    return result
}

private func extractRatingCommands(from data: Any) -> [String: InnerTubeCommand?] {
    var result: [String: InnerTubeCommand?] = [
        "like": nil,
        "dislike": nil,
        "removeLike": nil,
        "removeDislike": nil,
    ]

    visitJSONObjects(in: data) { node in
        guard let viewModel = node["segmentedLikeDislikeButtonViewModel"] as? JSONDictionary else { return .continue }

        let likeToggle = nestedToggleButton(from: viewModel["likeButtonViewModel"])
        let dislikeToggle = nestedToggleButton(from: viewModel["dislikeButtonViewModel"])

        let likeDefaultCommands =
            ((((likeToggle?["defaultButtonViewModel"] as? JSONDictionary)?["buttonViewModel"] as? JSONDictionary)?["onTap"] as? JSONDictionary)?["serialCommand"] as? JSONDictionary)?["commands"] as? [Any] ?? []
        let likeToggledCommands =
            ((((likeToggle?["toggledButtonViewModel"] as? JSONDictionary)?["buttonViewModel"] as? JSONDictionary)?["onTap"] as? JSONDictionary)?["serialCommand"] as? JSONDictionary)?["commands"] as? [Any] ?? []
        let dislikeDefaultCommands =
            ((((dislikeToggle?["defaultButtonViewModel"] as? JSONDictionary)?["buttonViewModel"] as? JSONDictionary)?["onTap"] as? JSONDictionary)?["serialCommand"] as? JSONDictionary)?["commands"] as? [Any] ?? []
        let dislikeToggledCommands =
            ((((dislikeToggle?["toggledButtonViewModel"] as? JSONDictionary)?["buttonViewModel"] as? JSONDictionary)?["onTap"] as? JSONDictionary)?["serialCommand"] as? JSONDictionary)?["commands"] as? [Any] ?? []

        result["like"] = normalizeLikeEndpoint(findInnerTubeCommand(in: likeDefaultCommands, endpointKey: "likeEndpoint"))
        result["removeLike"] = normalizeLikeEndpoint(findInnerTubeCommand(in: likeToggledCommands, endpointKey: "likeEndpoint"))
        result["dislike"] = normalizeLikeEndpoint(findInnerTubeCommand(in: dislikeDefaultCommands, endpointKey: "likeEndpoint"))
        result["removeDislike"] = normalizeLikeEndpoint(findInnerTubeCommand(in: dislikeToggledCommands, endpointKey: "likeEndpoint"))

        return .stop
    }

    return result
}

private func extractCommentsToken(from data: Any) -> String? {
    var result: String?

    visitJSONObjects(in: data) { node in
        if let panel = node["engagementPanelSectionListRenderer"] as? JSONDictionary,
           (panel["targetId"] as? String) == "engagement-panel-comments-section" {
            let contents = ((((panel["content"] as? JSONDictionary)?["sectionListRenderer"] as? JSONDictionary)?["contents"] as? [Any])) ?? []
            for item in contents {
                let itemContents = ((((item as? JSONDictionary)?["itemSectionRenderer"] as? JSONDictionary)?["contents"] as? [Any])) ?? []
                for sectionItem in itemContents {
                    if let continuation = continuationToken(in: sectionItem), !continuation.isEmpty {
                        result = continuation
                        return .stop
                    }
                }
            }
        }

        let continuationItems = (((node["appendContinuationItemsAction"] as? JSONDictionary)?["continuationItems"] as? [Any]))
            ?? (((node["reloadContinuationItemsCommand"] as? JSONDictionary)?["continuationItems"] as? [Any]))
            ?? []

        if continuationItems.contains(where: { (($0 as? JSONDictionary)?["commentThreadRenderer"]) != nil }) {
            for item in continuationItems {
                if let continuation = continuationToken(in: item), !continuation.isEmpty {
                    result = continuation
                    return .stop
                }
            }
        }

        return .continue
    }

    return result
}

private func extractComments(from data: Any, limit: Int = 20) -> [CommentItem] {
    let updates = ((((data as? JSONDictionary)?["frameworkUpdates"] as? JSONDictionary)?["entityBatchUpdate"] as? JSONDictionary))
    let mutations = updates?["mutations"] as? [Any] ?? []
    var entities: [String: JSONDictionary] = [:]

    for mutation in mutations {
        guard let mutation = mutation as? JSONDictionary else { continue }
        guard let entityKey = mutation["entityKey"] as? String else { continue }
        guard let payload = mutation["payload"] as? JSONDictionary else { continue }
        entities[entityKey] = payload
    }

    var comments: [CommentItem] = []
    var seen = Set<String>()

    visitJSONObjects(in: data) { node in
        guard let thread = node["commentThreadRenderer"] as? JSONDictionary else { return .continue }
        let viewModel = ((thread["commentViewModel"] as? JSONDictionary)?["commentViewModel"] as? JSONDictionary)
        let commentKey = viewModel?["commentKey"] as? String
        let entity = (((entities[commentKey ?? ""])?["commentEntityPayload"] as? JSONDictionary))
        guard let entity else { return .continue }

        let properties = entity["properties"] as? JSONDictionary
        let commentID = properties?["commentId"] as? String
        let body = contentTextValue(from: properties?["content"])
        let author = ((entity["author"] as? JSONDictionary)?["displayName"] as? String) ?? "Unknown"

        guard let commentID, let body, !body.isEmpty else { return .continue }
        guard seen.insert(commentID).inserted else { return .continue }

        let toolbar = entity["toolbar"] as? JSONDictionary
        comments.append(
            CommentItem(
                id: commentID,
                author: author,
                avatarUrl: (entity["author"] as? JSONDictionary)?["avatarThumbnailUrl"] as? String,
                body: body,
                likeCountText: (toolbar?["likeCountNotliked"] as? String) ?? (toolbar?["likeCountLiked"] as? String),
                publishedTimeText: properties?["publishedTime"] as? String,
                replyCountText: toolbar?["replyCount"] as? String,
                pinnedText: viewModel?["pinnedText"] as? String
            )
        )

        return comments.count >= limit ? .stop : .continue
    }

    return comments
}

private func extractStoryboard(from playerData: Any, liveTimeline: LiveStoryboardTimeline? = nil) -> StoryboardSpec? {
    guard let playerData = playerData as? JSONDictionary else { return nil }

    if let liveSpec = ((((playerData["storyboards"] as? JSONDictionary)?["playerLiveStoryboardSpecRenderer"] as? JSONDictionary)?["spec"] as? String)),
       liveSpec.isEmpty == false,
       let liveTimeline {
        let fields = liveSpec.components(separatedBy: "#")
        guard fields.count >= 5,
              let tileWidth = Int(fields[1]),
              let tileHeight = Int(fields[2]),
              let cols = Int(fields[3]),
              let rows = Int(fields[4]),
              tileWidth > 0,
              tileHeight > 0,
              cols > 0,
              rows > 0 else {
            return nil
        }

        let framesPerSheet = cols * rows
        let adjustedLiveTimeline = LiveStoryboardTimeline(
            firstSequence: liveTimeline.firstSequence,
            segmentDurations: liveTimeline.segmentDurations,
            trailingHiddenSegmentCount: max(liveTimeline.trailingHiddenSegmentCount, framesPerSheet * 2)
        )

        return StoryboardSpec(
            urls: [],
            urlPattern: fields[0],
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            frameCount: adjustedLiveTimeline.segmentDurations.count,
            cols: cols,
            rows: rows,
            intervalSeconds: adjustedLiveTimeline.segmentDurations.first ?? 0,
            liveTimeline: adjustedLiveTimeline
        )
    }

    guard let spec = ((((playerData["storyboards"] as? JSONDictionary)?["playerStoryboardSpecRenderer"] as? JSONDictionary)?["spec"] as? String)),
          !spec.isEmpty else { return nil }

    let parts = spec.split(separator: "|").map(String.init)
    guard parts.count >= 2 else { return nil }

    let baseURL = parts[0]
    let levelSpecs = Array(parts.dropFirst())

    var best: (Int, Int, Int, Int, Int, Int, Int, String, String)?
    for (index, level) in levelSpecs.enumerated() {
        let fields = level.components(separatedBy: "#")
        guard fields.count >= 8 else { continue }

        guard
            let tileWidth = Int(fields[0]),
            let tileHeight = Int(fields[1]),
            let frameCount = Int(fields[2]),
            let cols = Int(fields[3]),
            let rows = Int(fields[4]),
            let intervalMS = Int(fields[5]),
            tileWidth > 0,
            tileHeight > 0,
            frameCount > 0,
            cols > 0,
            rows > 0,
            intervalMS > 0
        else {
            continue
        }

        best = (index, tileWidth, tileHeight, frameCount, cols, rows, intervalMS, fields[6], fields[7])
    }

    guard let best else { return nil }
    let framesPerFile = best.4 * best.5
    let fileCount = Int(ceil(Double(best.3) / Double(framesPerFile)))
    let urlBase = baseURL.replacingOccurrences(of: "$L", with: String(best.0)).replacingOccurrences(of: "$N", with: best.7)
    let sighSuffix = best.8.isEmpty ? "" : "&sigh=\(best.8)"

    return StoryboardSpec(
        urls: (0..<fileCount).map { urlBase.replacingOccurrences(of: "$M", with: String($0)) + sighSuffix },
        urlPattern: nil,
        tileWidth: best.1,
        tileHeight: best.2,
        frameCount: best.3,
        cols: best.4,
        rows: best.5,
        intervalSeconds: Double(best.6) / 1000,
        liveTimeline: nil
    )
}

private func loadLiveManifestMetadata(from playerData: JSONDictionary, api: YouTubeAPI) async -> LiveManifestMetadata? {
    guard let streamingData = playerData["streamingData"] as? JSONDictionary,
          let dashManifestURLString = streamingData["dashManifestUrl"] as? String,
          let dashManifestURL = URL(string: dashManifestURLString),
          dashManifestURLString.isEmpty == false,
          let manifest = try? await api.fetchText(from: dashManifestURL, authenticated: false) else {
        return nil
    }

    return LiveManifestMetadata(
        windowDurationSeconds: parseLiveManifestWindowDuration(from: manifest),
        storyboardTimeline: parseLiveStoryboardTimeline(from: manifest)
    )
}

private func parseLiveManifestWindowDuration(from manifest: String) -> Double? {
    guard let depth = firstMatch(in: manifest, pattern: #"timeShiftBufferDepth="([^"]+)""#, group: 1) else {
        return nil
    }
    return parseISO8601DurationSeconds(depth)
}

private func parseLiveStoryboardTimeline(from manifest: String) -> LiveStoryboardTimeline? {
    guard
        let startNumberString = firstMatch(in: manifest, pattern: #"<SegmentList\b[^>]*startNumber="(\d+)""#, group: 1),
        let startNumber = Int(startNumberString),
        let timescaleString = firstMatch(in: manifest, pattern: #"<SegmentList\b[^>]*timescale="(\d+)""#, group: 1),
        let timescale = Double(timescaleString),
        timescale > 0,
        let timelineBody = firstMatch(in: manifest, pattern: #"<SegmentTimeline>(.*?)</SegmentTimeline>"#, group: 1, options: [.dotMatchesLineSeparators])
    else {
        return nil
    }

    let pattern = #"<S\b[^>]*d="(\d+)"(?:[^>]*r="(-?\d+)")?[^>]*/?>"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsRange = NSRange(timelineBody.startIndex..<timelineBody.endIndex, in: timelineBody)

    var segmentDurations: [Double] = []
    regex.enumerateMatches(in: timelineBody, options: [], range: nsRange) { match, _, _ in
        guard let match,
              let durationRange = Range(match.range(at: 1), in: timelineBody),
              let durationUnits = Double(timelineBody[durationRange]) else {
            return
        }

        let repeatCount: Int
        if let repeatRange = Range(match.range(at: 2), in: timelineBody),
           let rawRepeatCount = Int(timelineBody[repeatRange]),
           rawRepeatCount >= 0 {
            repeatCount = rawRepeatCount
        } else {
            repeatCount = 0
        }

        let durationSeconds = durationUnits / timescale
        segmentDurations.append(contentsOf: repeatElement(durationSeconds, count: repeatCount + 1))
    }

    guard segmentDurations.isEmpty == false else { return nil }
    return LiveStoryboardTimeline(
        firstSequence: startNumber,
        segmentDurations: segmentDurations,
        trailingHiddenSegmentCount: 18
    )
}

private func parseISO8601DurationSeconds(_ value: String) -> Double? {
    guard value.hasPrefix("PT") else { return nil }
    let pattern = #"^PT(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = regex.firstMatch(in: value, options: [], range: nsRange) else { return nil }

    func component(_ index: Int) -> Double {
        guard let range = Range(match.range(at: index), in: value) else { return 0 }
        return Double(value[range]) ?? 0
    }

    let hours = component(1)
    let minutes = component(2)
    let seconds = component(3)
    let total = (hours * 3600) + (minutes * 60) + seconds
    return total > 0 ? total : nil
}

private func firstMatch(
    in source: String,
    pattern: String,
    group: Int = 1,
    options: NSRegularExpression.Options = []
) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
    let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
    guard let match = regex.firstMatch(in: source, options: [], range: nsRange),
          group < match.numberOfRanges,
          let range = Range(match.range(at: group), in: source) else {
        return nil
    }
    return String(source[range])
}

private func findPlaylistOption(in options: [PlaylistOption], playlistID: String) -> PlaylistOption? {
    options.first(where: { $0.playlistId == playlistID })
}

private func parseLockupVideoItem(_ lockup: JSONDictionary) -> VideoItem? {
    guard (lockup["contentType"] as? String) == "LOCKUP_CONTENT_TYPE_VIDEO" else { return nil }

    let videoID = (lockup["contentId"] as? String)
        ?? (((((((lockup["rendererContext"] as? JSONDictionary)?["commandContext"] as? JSONDictionary)?["onTap"] as? JSONDictionary)?["innertubeCommand"] as? JSONDictionary)?["watchEndpoint"] as? JSONDictionary)?["videoId"] as? String))
    guard let videoID, !videoID.isEmpty else { return nil }

    let metadata = (((lockup["metadata"] as? JSONDictionary)?["lockupMetadataViewModel"] as? JSONDictionary))
    let rows = (((metadata?["metadata"] as? JSONDictionary)?["contentMetadataViewModel"] as? JSONDictionary)?["metadataRows"] as? [Any]) ?? []
    let channelRow = rows.indices.contains(0) ? rowTextParts(rows[0]) : []
    let statsRow = rows.indices.contains(1) ? rowTextParts(rows[1]) : []
    let thumbnailImage = ((lockup["contentImage"] as? JSONDictionary)?["thumbnailViewModel"] as? JSONDictionary)?["image"]
    let durationText = extractLockupDuration(from: lockup)

    return VideoItem(
        id: videoID,
        title: (metadata?["title"] as? JSONDictionary)?["content"] as? String ?? "Untitled",
        channel: channelRow.first,
        channelId: channelID(from: lockup),
        channelAvatarUrl: channelAvatarURL(from: lockup),
        viewCountText: statsRow.first,
        publishedTimeText: statsRow.count > 1 ? statsRow[1] : nil,
        durationText: durationText,
        thumbnails: sourceThumbnails(from: thumbnailImage),
        progress: makeRemoteProgress(
            youtubeFraction: extractWatchProgressFraction(from: lockup),
            durationText: durationText
        ),
        tags: extractVideoTags(from: lockup)
    )
}

private func extractHistoryDeleteCommand(from value: Any?) -> InnerTubeCommand? {
    let listItems: [Any] = {
        guard let lockup = value as? JSONDictionary else { return [] }
        let metadata = (lockup["metadata"] as? JSONDictionary)?["lockupMetadataViewModel"] as? JSONDictionary
        let menuButton = metadata?["menuButton"] as? JSONDictionary
        let buttonViewModel = menuButton?["buttonViewModel"] as? JSONDictionary
        let onTap = buttonViewModel?["onTap"] as? JSONDictionary
        let innertubeCommand = onTap?["innertubeCommand"] as? JSONDictionary
        let showSheetCommand = innertubeCommand?["showSheetCommand"] as? JSONDictionary
        let panelLoadingStrategy = showSheetCommand?["panelLoadingStrategy"] as? JSONDictionary
        let inlineContent = panelLoadingStrategy?["inlineContent"] as? JSONDictionary
        let sheetViewModel = inlineContent?["sheetViewModel"] as? JSONDictionary
        let content = sheetViewModel?["content"] as? JSONDictionary
        let listViewModel = content?["listViewModel"] as? JSONDictionary
        return listViewModel?["listItems"] as? [Any] ?? []
    }()

    for item in listItems {
        guard let item = item as? JSONDictionary else { continue }
        guard let viewModel = item["listItemViewModel"] as? JSONDictionary else { continue }
        let title = contentTextValue(from: viewModel["title"])?.lowercased()
        let command = ((((viewModel["rendererContext"] as? JSONDictionary)?["commandContext"] as? JSONDictionary)?["onTap"] as? JSONDictionary)?["innertubeCommand"] as? JSONDictionary)
        guard let command,
              let feedbackEndpoint = command["feedbackEndpoint"] as? JSONDictionary else {
            continue
        }

        let hasRemoveAction = title?.contains("watch history") == true
            || feedbackEndpoint["contentId"] != nil
            || jsonContainsHistoryRemove(feedbackEndpoint)
        guard hasRemoveAction else { continue }

        return buildCommand(
            apiPath: commandMetadataAPIPath(from: command) ?? "feedback",
            payload: feedbackRequestPayload(from: feedbackEndpoint)
        )
    }

    return nil
}

private func feedbackRequestPayload(from endpoint: JSONDictionary) -> JSONDictionary {
    var feedbackTokens: [Any] = []

    if let feedbackToken = endpoint["feedbackToken"] as? String, !feedbackToken.isEmpty {
        feedbackTokens.append(feedbackToken)
    }

    if let existingTokens = endpoint["feedbackTokens"] as? [Any] {
        feedbackTokens.append(contentsOf: existingTokens)
    }

    var payload: JSONDictionary = [
        "feedbackTokens": feedbackTokens,
        "shouldMerge": feedbackTokens.count > 1,
    ]

    if let cpn = endpoint["cpn"] as? String, !cpn.isEmpty {
        payload["feedbackContext"] = ["cpn": cpn]
    }

    if let isUnencrypted = endpoint["isFeedbackTokenUnencrypted"] {
        payload["isFeedbackTokenUnencrypted"] = isUnencrypted
    }

    return payload
}

private func jsonContainsHistoryRemove(_ value: Any) -> Bool {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value),
          let text = String(data: data, encoding: .utf8)?.lowercased() else {
        return false
    }

    return text.contains("local_watch_history_command_type_remove")
        || text.contains("remove from watch history")
        || text.contains("all views of this video removed from history")
}

private func parseLockupPlaylistItem(_ lockup: JSONDictionary) -> PlaylistSummary? {
    guard (lockup["contentType"] as? String) == "LOCKUP_CONTENT_TYPE_PLAYLIST" else { return nil }

    let playlistID = (lockup["contentId"] as? String)
        ?? (((((((lockup["rendererContext"] as? JSONDictionary)?["commandContext"] as? JSONDictionary)?["onTap"] as? JSONDictionary)?["innertubeCommand"] as? JSONDictionary)?["watchEndpoint"] as? JSONDictionary)?["playlistId"] as? String))
    guard let playlistID, !playlistID.isEmpty else { return nil }

    let metadata = (((lockup["metadata"] as? JSONDictionary)?["lockupMetadataViewModel"] as? JSONDictionary))
    guard let title = (metadata?["title"] as? JSONDictionary)?["content"] as? String, !title.isEmpty else {
        return nil
    }

    let rows = (((metadata?["metadata"] as? JSONDictionary)?["contentMetadataViewModel"] as? JSONDictionary)?["metadataRows"] as? [Any]) ?? []
    var privacy: String?
    var itemCountText: String?
    var updatedText: String?

    if rows.indices.contains(0) {
        let firstRow = rowTextParts(rows[0])
        if !firstRow.isEmpty {
            privacy = firstRow[0]
            if firstRow.count > 1, firstRow[1].localizedCaseInsensitiveContains("video") {
                itemCountText = firstRow[1]
            }
        }
    }

    if rows.indices.contains(1) {
        updatedText = rowTextParts(rows[1]).first
    }

    let primaryThumbnail =
        ((((lockup["contentImage"] as? JSONDictionary)?["collectionThumbnailViewModel"] as? JSONDictionary)?["primaryThumbnail"] as? JSONDictionary)?["thumbnailViewModel"] as? JSONDictionary)?["image"]
    let thumbnails = sourceThumbnails(from: primaryThumbnail)

    return PlaylistSummary(
        playlistId: playlistID,
        title: title,
        privacy: privacy,
        itemCountText: itemCountText,
        updatedText: updatedText,
        thumbnails: thumbnails
    )
}

private func extractLockupDuration(from lockup: JSONDictionary) -> String? {
    let overlays = (((((lockup["contentImage"] as? JSONDictionary)?["thumbnailViewModel"] as? JSONDictionary)?["overlays"] as? [Any])) ?? [])
    for overlay in overlays {
        let badges = ((((overlay as? JSONDictionary)?["thumbnailBottomOverlayViewModel"] as? JSONDictionary)?["badges"] as? [Any]) ?? [])
        for badge in badges {
            if let text = ((((badge as? JSONDictionary)?["thumbnailBadgeViewModel"] as? JSONDictionary)?["text"] as? String)), !text.isEmpty {
                return text
            }
        }
    }
    return nil
}

private func extractWatchProgressFraction(from data: Any?) -> Double? {
    guard let data else { return nil }
    var fraction: Double?

    visitJSONObjects(in: data) { node in
        if let renderer = node["thumbnailOverlayResumePlaybackRenderer"] as? JSONDictionary {
            if let percent = doubleValue(renderer["percentDurationWatched"]) {
                fraction = percent
                return .stop
            }
        }

        if let renderer = node["thumbnailOverlayProgressBarViewModel"] as? JSONDictionary {
            if let percent = doubleValue(renderer["startPercent"]) {
                fraction = percent
                return .stop
            }
        }
        return .continue
    }

    return fraction
}

private func trackedURL(
    from baseURL: URL?,
    cpn: String,
    currentTime: Double,
    startTime: Double?,
    endTime: Double?
) -> URL? {
    guard let baseURL else { return nil }
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }

    var items = components.queryItems ?? []

    func setQueryItem(name: String, value: String?) {
        items.removeAll { $0.name == name }
        guard let value else { return }
        items.append(URLQueryItem(name: name, value: value))
    }

    setQueryItem(name: "ver", value: "2")
    setQueryItem(name: "cpn", value: cpn)
    setQueryItem(name: "cmt", value: String(max(currentTime.rounded(.down), 0)))
    setQueryItem(name: "el", value: "detailpage")

    if let startTime {
        setQueryItem(name: "st", value: String(max(startTime.rounded(.down), 0)))
    }
    if let endTime {
        setQueryItem(name: "et", value: String(max(endTime.rounded(.down), 0)))
    }

    components.queryItems = items
    return components.url
}

private struct SignedInAccountProfile {
    var displayName: String?
    var email: String?
    var handle: String?
    var avatarURL: String?

    mutating func merge(_ other: SignedInAccountProfile) {
        displayName = displayName ?? other.displayName
        email = email ?? other.email
        handle = handle ?? other.handle
        avatarURL = avatarURL ?? other.avatarURL
    }
}

private struct BrowserAccountProbe {
    let displayName: String
    let identifier: String?
    let avatarURL: String?
    let source: BrowserAccountSource
}

private func probeBrowserAccount(_ browser: BrowserLoginOption) async -> BrowserAccountProbe? {
    do {
        let authManager = YouTubeAuthManager()
        let material = try await authManager.probeMaterial(for: browser)
        _ = await authManager.activateProbeMaterial(material)
        let api = YouTubeAPI(authManager: authManager)
        let profile = await signedInAccountProfile(using: api)
        try? FileManager.default.removeItem(at: material.cookieFileURL)

        let displayName = profile.displayName?.nonEmptyTrimmed
            ?? profile.email?.nonEmptyTrimmed
            ?? profile.handle?.nonEmptyTrimmed
            ?? browser.displayName
        let source = BrowserAccountSource(
            browser: browser.rawValue,
            browserLabel: browser.displayName,
            bundleIdentifier: browser.primaryBundleIdentifier
        )

        return BrowserAccountProbe(
            displayName: displayName,
            identifier: profile.email?.nonEmptyTrimmed ?? profile.handle?.nonEmptyTrimmed,
            avatarURL: profile.avatarURL?.nonEmptyTrimmed,
            source: source
        )
    } catch {
        return nil
    }
}

private func groupedBrowserAccounts(from probes: [BrowserAccountProbe]) -> [BrowserAccountDiscoveryResponse] {
    var grouped: [String: [BrowserAccountProbe]] = [:]

    for probe in probes {
        let key = browserAccountGroupingKey(for: probe)
        grouped[key, default: []].append(probe)
    }

    return grouped.map { key, probes in
        let sortedProbes = probes.sorted { lhs, rhs in
            let lhsRank = BrowserLoginOption(rawValue: lhs.source.browser)?.sortRank ?? 999
            let rhsRank = BrowserLoginOption(rawValue: rhs.source.browser)?.sortRank ?? 999
            return lhsRank < rhsRank
        }
        let first = sortedProbes[0]
        let sources = sortedProbes.map(\.source)

        return BrowserAccountDiscoveryResponse(
            id: key,
            displayName: first.displayName,
            identifier: first.identifier,
            avatarUrl: first.avatarURL,
            sources: sources
        )
    }
    .sorted { lhs, rhs in
        lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}

private func browserAccountGroupingKey(for probe: BrowserAccountProbe) -> String {
    let rawKey = probe.identifier?.nonEmptyTrimmed
        ?? probe.avatarURL?.nonEmptyTrimmed
        ?? probe.displayName.nonEmptyTrimmed
        ?? probe.source.browser
    return rawKey.lowercased()
}

private func signedInAccountProfile(using api: YouTubeAPI) async -> SignedInAccountProfile {
    var profile = SignedInAccountProfile()

    if let accountMenu = try? await api.accountMenu(authenticated: true) {
        profile.merge(extractSignedInAccountProfile(from: accountMenu))
    }

    if profile.avatarURL == nil || profile.email == nil || profile.displayName == nil {
        if let payload = try? await api.browse(browseID: "FEwhat_to_watch", authenticated: true) {
            profile.merge(extractSignedInAccountProfile(from: payload))
        }
    }

    return profile
}

private func extractSignedInAccountProfile(from data: Any) -> SignedInAccountProfile {
    var profile = SignedInAccountProfile()

    visitJSONObjects(in: data) { node in
        if let renderer = node["topbarMenuButtonRenderer"] as? JSONDictionary,
           let url = bestThumbnailURL(thumbnails(from: renderer["avatar"])) {
            profile.avatarURL = profile.avatarURL ?? url
        }

        if let renderer = node["activeAccountHeaderRenderer"] as? JSONDictionary {
            profile.displayName = profile.displayName ?? textValue(from: renderer["accountName"])
            profile.email = profile.email ?? textValue(from: renderer["email"])
            profile.handle = profile.handle
                ?? textValue(from: renderer["channelHandle"])
                ?? textValue(from: renderer["handle"])
                ?? textValue(from: renderer["accountHandle"])
            profile.avatarURL = profile.avatarURL
                ?? bestThumbnailURL(thumbnails(from: renderer["accountPhoto"]))
                ?? bestThumbnailURL(thumbnails(from: renderer["avatar"]))
        }

        if let renderer = node["accountItem"] as? JSONDictionary {
            profile.displayName = profile.displayName
                ?? textValue(from: renderer["accountName"])
                ?? textValue(from: renderer["name"])
                ?? textValue(from: renderer["title"])
            profile.email = profile.email
                ?? textValue(from: renderer["email"])
                ?? textValue(from: renderer["accountEmail"])
                ?? emailCandidate(from: textValue(from: renderer["subtitle"]))
            profile.handle = profile.handle
                ?? textValue(from: renderer["channelHandle"])
                ?? textValue(from: renderer["handle"])
                ?? textValue(from: renderer["accountHandle"])
                ?? handleCandidate(from: textValue(from: renderer["subtitle"]))
            profile.avatarURL = profile.avatarURL
                ?? bestThumbnailURL(thumbnails(from: renderer["accountPhoto"]))
                ?? bestThumbnailURL(thumbnails(from: renderer["avatar"]))
                ?? bestThumbnailURL(thumbnails(from: renderer["thumbnail"]))
        }

        if profile.handle == nil {
            profile.handle = handleCandidate(from: textValue(from: node["channelHandle"]))
                ?? handleCandidate(from: textValue(from: node["handle"]))
                ?? handleCandidate(from: textValue(from: node["ownerHandle"]))
                ?? firstHandleCandidate(in: node)
        }

        if (profile.email != nil || profile.handle != nil), profile.displayName != nil, profile.avatarURL != nil {
            return .stop
        }

        return .continue
    }

    return profile
}

private func emailCandidate(from value: String?) -> String? {
    guard let value = value?.nonEmptyTrimmed, value.contains("@"), value.contains(".") else {
        return nil
    }
    return value
}

private func handleCandidate(from value: String?) -> String? {
    guard let value = value?.nonEmptyTrimmed else { return nil }
    let components = value.components(separatedBy: .whitespacesAndNewlines)
    return components.first { component in
        component.hasPrefix("@") && component.count > 1
    } ?? (value.hasPrefix("@") && value.count > 1 ? value : nil)
}

private func firstHandleCandidate(in value: Any) -> String? {
    if let string = value as? String {
        return handleCandidate(from: string)
    }

    if let array = value as? [Any] {
        for item in array {
            if let handle = firstHandleCandidate(in: item) {
                return handle
            }
        }
    }

    if let dictionary = value as? JSONDictionary {
        for item in dictionary.values {
            if let handle = firstHandleCandidate(in: item) {
                return handle
            }
        }
    }

    return nil
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private func randomPlaybackNonce() -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    return String((0..<16).map { _ in alphabet.randomElement() ?? "a" })
}

private func extractWatchTracking(from watchPageHTML: String?, fallbackDuration: Double?) -> WatchTrackingSnapshot? {
    guard let watchPageHTML,
          let playerResponse = extractInitialPlayerResponse(from: watchPageHTML),
          let tracking = playerResponse["playbackTracking"] as? JSONDictionary else {
        return nil
    }

    let playbackURL = urlFromJSONString(tracking["videostatsPlaybackUrl"])
    let watchtimeURL = urlFromJSONString(tracking["videostatsWatchtimeUrl"])
    let resolvedDuration = fallbackDuration
        ?? doubleValue(((playerResponse["videoDetails"] as? JSONDictionary)?["lengthSeconds"]))

    if playbackURL == nil, watchtimeURL == nil {
        return nil
    }

    return WatchTrackingSnapshot(
        playbackURL: playbackURL,
        watchtimeURL: watchtimeURL,
        durationSeconds: resolvedDuration
    )
}

private func extractInitialPlayerResponse(from html: String) -> JSONDictionary? {
    let markers = [
        "var ytInitialPlayerResponse = ",
        "ytInitialPlayerResponse = ",
    ]

    for marker in markers {
        guard let markerRange = html.range(of: marker) else { continue }
        guard let json = extractBalancedJSONObject(in: html, startingAt: markerRange.upperBound) else { continue }
        guard let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? JSONDictionary else {
            continue
        }
        return payload
    }

    return nil
}

private func extractVisitorData(from html: String) -> String? {
    firstMatch(in: html, pattern: #""visitorData"\s*:\s*"([^"]+)""#)?
        .replacingOccurrences(of: #"\/"#, with: "/")
        .replacingOccurrences(of: #"\\u0026"#, with: "&")
}

private func extractBalancedJSONObject(in source: String, startingAt startIndex: String.Index) -> String? {
    guard let objectStart = source[startIndex...].firstIndex(of: "{") else { return nil }

    var depth = 0
    var inString = false
    var isEscaped = false
    var index = objectStart

    while index < source.endIndex {
        let character = source[index]

        if inString {
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                inString = false
            }
        } else {
            if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[objectStart...index])
                }
            }
        }

        index = source.index(after: index)
    }

    return nil
}

private func urlFromJSONString(_ value: Any?) -> URL? {
    guard let baseURL = ((value as? JSONDictionary)?["baseUrl"] as? String),
          !baseURL.isEmpty else {
        return nil
    }
    return URL(string: baseURL)
}

private func playlistItemMenuFlags(from value: Any?) -> (remove: Bool, moveTop: Bool, moveBottom: Bool) {
    var remove = false
    var moveTop = false
    var moveBottom = false

    for item in menuServiceItemRenderers(from: value) {
        guard let command = normalizePlaylistEditEndpoint(item["serviceEndpoint"]) else { continue }
        guard let actions = command.payload["actions"] as? [Any], let firstAction = actions.first as? JSONDictionary else { continue }

        switch firstAction["action"] as? String {
        case "ACTION_REMOVE_VIDEO":
            remove = true
        case "ACTION_MOVE_VIDEO_AFTER":
            moveTop = true
        case "ACTION_MOVE_VIDEO_BEFORE":
            moveBottom = true
        default:
            break
        }
    }

    return (remove, moveTop, moveBottom)
}

private func menuServiceItemRenderers(from value: Any?) -> [JSONDictionary] {
    guard let menu = value as? JSONDictionary else { return [] }
    guard let renderer = menu["menuRenderer"] as? JSONDictionary else { return [] }
    guard let items = renderer["items"] as? [Any] else { return [] }
    return items.compactMap { ($0 as? JSONDictionary)?["menuServiceItemRenderer"] as? JSONDictionary }
}

private func commandMetadataAPIPath(from value: Any?) -> String? {
    (((value as? JSONDictionary)?["commandMetadata"] as? JSONDictionary)?["webCommandMetadata"] as? JSONDictionary)?["apiUrl"] as? String
}

private func normalizeAPIPath(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value.replacingOccurrences(of: "/youtubei/v1/", with: "")
}

private func buildCommand(apiPath: String?, payload: JSONDictionary) -> InnerTubeCommand? {
    guard let apiPath = normalizeAPIPath(apiPath) else { return nil }
    return InnerTubeCommand(apiPath: apiPath, payload: payload)
}

private func normalizeSubscribeEndpoint(_ value: Any?, unsubscribe: Bool) -> InnerTubeCommand? {
    guard let endpoint = value as? JSONDictionary else { return nil }
    let key = unsubscribe ? "unsubscribeEndpoint" : "subscribeEndpoint"
    guard let raw = endpoint[key] as? JSONDictionary else { return nil }

    var payload: JSONDictionary = [:]
    for field in ["channelIds", "siloName", "params", "botguardResponse"] {
        if let value = raw[field] {
            payload[field] = value
        }
    }
    if let feature = raw["feature"] {
        payload["clientFeature"] = feature
    }

    return buildCommand(
        apiPath: commandMetadataAPIPath(from: endpoint) ?? (unsubscribe ? "subscription/unsubscribe" : "subscription/subscribe"),
        payload: payload
    )
}

private func normalizeLikeEndpoint(_ value: Any?) -> InnerTubeCommand? {
    guard let endpoint = value as? JSONDictionary else { return nil }
    guard let raw = endpoint["likeEndpoint"] as? JSONDictionary else { return nil }

    var payload: JSONDictionary = [:]
    if let target = raw["target"] {
        payload["target"] = target
    }

    let status = raw["status"] as? String
    let paramsField: String?
    switch status {
    case "LIKE":
        paramsField = "likeParams"
    case "DISLIKE":
        paramsField = "dislikeParams"
    case "INDIFFERENT":
        paramsField = "removeLikeParams"
    default:
        paramsField = nil
    }

    if let paramsField, let params = raw[paramsField] {
        payload["params"] = params
    }

    let defaultPath: String?
    switch status {
    case "LIKE":
        defaultPath = "like/like"
    case "DISLIKE":
        defaultPath = "like/dislike"
    case "INDIFFERENT":
        defaultPath = "like/removelike"
    default:
        defaultPath = nil
    }

    return buildCommand(apiPath: commandMetadataAPIPath(from: endpoint) ?? defaultPath, payload: payload)
}

private func normalizeAddToPlaylistEndpoint(_ value: Any?) -> InnerTubeCommand? {
    guard let endpoint = value as? JSONDictionary else { return nil }
    guard let raw = endpoint["addToPlaylistServiceEndpoint"] as? JSONDictionary else { return nil }

    let videoIDs: [Any]
    if let existing = raw["videoIds"] as? [Any] {
        videoIDs = existing
    } else if let videoID = raw["videoId"] {
        videoIDs = [videoID]
    } else {
        videoIDs = []
    }

    var payload: JSONDictionary = ["videoIds": videoIDs]
    for field in ["playlistId", "params"] {
        if let value = raw[field] {
            payload[field] = value
        }
    }
    payload["excludeWatchLater"] = raw["excludeWatchLater"] as? Bool ?? false

    return buildCommand(
        apiPath: commandMetadataAPIPath(from: endpoint) ?? "playlist/get_add_to_playlist",
        payload: payload
    )
}

private func normalizePlaylistEditEndpoint(_ value: Any?) -> InnerTubeCommand? {
    guard let endpoint = value as? JSONDictionary else { return nil }
    guard let raw = endpoint["playlistEditEndpoint"] as? JSONDictionary else { return nil }

    var payload: JSONDictionary = [:]
    for field in ["playlistId", "actions", "params"] {
        if let value = raw[field] {
            payload[field] = value
        }
    }

    return buildCommand(
        apiPath: commandMetadataAPIPath(from: endpoint) ?? "browse/edit_playlist",
        payload: payload
    )
}

private func firstDictionary(in items: [Any]) -> JSONDictionary? {
    items.first { $0 is JSONDictionary } as? JSONDictionary
}

private func findInnerTubeCommand(in commands: [Any], endpointKey: String) -> JSONDictionary? {
    for command in commands {
        guard let command = command as? JSONDictionary else { continue }
        guard let innerTubeCommand = command["innertubeCommand"] as? JSONDictionary else { continue }
        if innerTubeCommand[endpointKey] != nil {
            return innerTubeCommand
        }
    }
    return nil
}

private func continuationLists(from node: JSONDictionary) -> [[Any]] {
    var lists: [[Any]] = []

    if let itemSectionContents = ((node["itemSectionRenderer"] as? JSONDictionary)?["contents"] as? [Any]) {
        lists.append(itemSectionContents)
    }

    if let appendItems = ((node["appendContinuationItemsAction"] as? JSONDictionary)?["continuationItems"] as? [Any]) {
        lists.append(appendItems)
    }

    if let reloadItems = ((node["reloadContinuationItemsCommand"] as? JSONDictionary)?["continuationItems"] as? [Any]) {
        lists.append(reloadItems)
    }

    if let continuationContents = node["continuationContents"] as? JSONDictionary {
        for key in ["itemSectionContinuation", "sectionListContinuation"] {
            if let contents = ((continuationContents[key] as? JSONDictionary)?["contents"] as? [Any]) {
                lists.append(contents)
            }
        }
    }

    return lists
}

private func continuationToken(in value: Any) -> String? {
    ((((value as? JSONDictionary)?["continuationItemRenderer"] as? JSONDictionary)?["continuationEndpoint"] as? JSONDictionary)?["continuationCommand"] as? JSONDictionary)?["token"] as? String
}

private func popupConfirmServiceEndpoint(from value: Any?) -> Any? {
    let buttonRenderer =
        (((((value as? JSONDictionary)?["openPopupAction"] as? JSONDictionary)?["popup"] as? JSONDictionary)?["confirmDialogRenderer"] as? JSONDictionary)?["confirmButton"] as? JSONDictionary)?["buttonRenderer"] as? JSONDictionary
    return buttonRenderer?["serviceEndpoint"]
}

private func nestedToggleButton(from value: Any?) -> JSONDictionary? {
    guard let container = value as? JSONDictionary else { return nil }
    let inner = container.values.compactMap { $0 as? JSONDictionary }.first
    return ((inner?["toggleButtonViewModel"] as? JSONDictionary)?["toggleButtonViewModel"] as? JSONDictionary)
}

private func itemHasVideoPayload(_ value: Any) -> Bool {
    guard let item = value as? JSONDictionary else { return false }
    if item["compactVideoRenderer"] != nil
        || item["videoRenderer"] != nil
        || item["playlistPanelVideoRenderer"] != nil
        || item["gridVideoRenderer"] != nil
        || item["richItemRenderer"] != nil {
        return true
    }

    return ((item["lockupViewModel"] as? JSONDictionary)?["contentType"] as? String) == "LOCKUP_CONTENT_TYPE_VIDEO"
}

private func parseMimeType(_ mimeType: String?) -> (container: String?, videoCodec: String?, audioCodec: String?) {
    guard let mimeType, !mimeType.isEmpty else {
        return (nil, nil, nil)
    }

    let parts = mimeType.components(separatedBy: ";")
    let base = parts[0]
    let container = base.contains("/") ? base.components(separatedBy: "/")[safe: 1]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : nil

    let codecsRange = mimeType.range(of: "codecs=\"")
    let codecsValue: String
    if let codecsRange {
        let suffix = mimeType[codecsRange.upperBound...]
        codecsValue = String(suffix.prefix { $0 != "\"" })
    } else {
        codecsValue = ""
    }

    let codecs = codecsValue
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

    let audioPrefixes = ["mp4a", "opus", "vorbis", "aac"]
    let videoCodec = codecs.first { codec in
        !audioPrefixes.contains(where: { codec.hasPrefix($0) })
    }
    let audioCodec = codecs.first { codec in
        audioPrefixes.contains(where: { codec.hasPrefix($0) })
    }

    return (container, videoCodec, audioCodec)
}

private func isManifestURL(_ url: String) -> Bool {
    let lowered = url.lowercased()
    return lowered.contains("manifest.googlevideo.com")
        || lowered.contains("/api/manifest/")
        || lowered.hasSuffix(".m3u8")
        || lowered.contains("/playlist/index.m3u8")
}

private func streamKind(for url: String, hasAudio: Bool, hasVideo: Bool) -> String {
    if isManifestURL(url) { return "manifest" }
    if hasVideo && hasAudio { return "muxed" }
    if hasVideo { return "video" }
    if hasAudio { return "audio" }
    return "muxed"
}

private func codecScore(_ codec: String?) -> Int {
    guard let codec else { return 0 }
    if codec.hasPrefix("avc1") { return 5 }
    if codec.hasPrefix("hvc1") || codec.hasPrefix("hev1") { return 4 }
    if codec.hasPrefix("av01") { return 3 }
    if codec.hasPrefix("vp9") { return 2 }
    if codec.hasPrefix("mp4a") { return 4 }
    if codec.hasPrefix("opus") { return 3 }
    return 1
}

private func manifestSourcePreference(_ stream: StreamInfo) -> Int {
    switch stream.httpHeaders?["X-YouTube-Client-Name"] {
    case "88":
        return 2
    case "1":
        return 1
    default:
        return 0
    }
}

private func manifestStreamScore(_ stream: StreamInfo, preferHLS: Bool = false) -> [Int] {
    let manifestProtocolPreference: Int
    if preferHLS {
        // YouTube's live HLS manifests load reliably through mpv/FFmpeg, while
        // the paired live DASH manifest often fails before the player becomes ready.
        manifestProtocolPreference = stream.container?.lowercased() == "m3u8" ? 1 : 0
    } else {
        manifestProtocolPreference = stream.formatId == "dash-manifest" ? 1 : 0
    }

    return [
        manifestProtocolPreference,
        preferHLS ? manifestSourcePreference(stream) : 0,
        stream.hasAudio ? 1 : 0,
        stream.hasVideo ? 1 : 0,
        stream.height ?? 0,
        stream.fps ?? 0,
        stream.bitrate ?? 0
    ]
}

private func streamScore(_ stream: StreamInfo) -> (Int, Int, Int, Int, Int) {
    (
        stream.height ?? 0,
        stream.fps ?? 0,
        stream.bitrate ?? 0,
        codecScore(stream.videoCodec),
        codecScore(stream.audioCodec)
    )
}

private func simpleStreamScore(_ stream: StreamInfo) -> (Int, Int, Int, Int) {
    (
        stream.hasAudio ? 1 : 0,
        stream.hasVideo ? 1 : 0,
        stream.height ?? 0,
        stream.bitrate ?? 0
    )
}

private func adaptiveAudioScore(_ stream: StreamInfo) -> (Int, Int, Int, Int) {
    let channels = stream.audioChannels ?? 0
    let channelPreference: Int
    let channelTiebreaker: Int

    switch channels {
    case 2:
        channelPreference = 3
        channelTiebreaker = 0
    case 1:
        channelPreference = 2
        channelTiebreaker = 0
    case let value where value > 2:
        channelPreference = 1
        channelTiebreaker = -value
    default:
        channelPreference = 0
        channelTiebreaker = 0
    }

    return (
        channelPreference,
        codecScore(stream.audioCodec),
        channelTiebreaker,
        stream.bitrate ?? 0
    )
}

private func isSupportedVideoCodec(_ codec: String?) -> Bool {
    guard let codec else { return false }
    return codec.hasPrefix("avc1")
        || codec.hasPrefix("av01")
        || codec.hasPrefix("hvc1")
        || codec.hasPrefix("hev1")
}

private func mimeTypeFromYTDLP(format: JSONDictionary) -> String? {
    guard let ext = format["ext"] as? String else { return nil }
    let videoCodec = format["vcodec"] as? String
    let audioCodec = format["acodec"] as? String

    if videoCodec != nil && videoCodec != "none" {
        return "video/\(ext)"
    }
    if audioCodec != nil && audioCodec != "none" {
        return "audio/\(ext)"
    }
    return nil
}

private func languageLabel(for code: String) -> String {
    let labels: [String: String] = [
        "en": "English", "es": "Spanish", "fr": "French", "de": "German",
        "pt": "Portuguese", "it": "Italian", "ja": "Japanese", "ko": "Korean",
        "zh": "Chinese", "zh-Hans": "Chinese (Simplified)", "zh-Hant": "Chinese (Traditional)",
        "ru": "Russian", "ar": "Arabic", "hi": "Hindi", "nl": "Dutch",
        "sv": "Swedish", "pl": "Polish", "tr": "Turkish", "vi": "Vietnamese",
        "th": "Thai", "id": "Indonesian", "uk": "Ukrainian", "cs": "Czech",
        "ro": "Romanian", "el": "Greek", "hu": "Hungarian", "da": "Danish",
        "fi": "Finnish", "no": "Norwegian", "he": "Hebrew", "ms": "Malay",
        "fil": "Filipino", "bn": "Bengali", "ta": "Tamil", "te": "Telugu",
    ]

    if let exact = labels[code] {
        return exact
    }
    let base = code.components(separatedBy: "-").first ?? code
    if let baseLabel = labels[base] {
        let subtags = code.components(separatedBy: "-")
        if subtags.count == 2, subtags[1].count == 2 {
            return "\(baseLabel) (\(subtags[1].uppercased()))"
        }
        return "\(baseLabel) (\(code))"
    }
    return code.uppercased()
}

private func audioLanguage(from data: JSONDictionary, url: String) -> String? {
    if let audioTrack = data["audioTrack"] as? JSONDictionary {
        if let languageCode = stringify(audioTrack["languageCode"]) {
            return languageCode
        }
        if let id = stringify(audioTrack["id"]),
           let language = audioLanguage(fromAudioTrackID: id) {
            return language
        }
    }

    if let language = stringify(data["LANGUAGE"]) ?? stringify(data["language"]) {
        return language
    }

    return audioTrackAttributes(from: url)["lang"]
}

private func audioLanguage(from data: [String: String], url: String) -> String? {
    data["LANGUAGE"] ?? data["language"] ?? audioTrackAttributes(from: url)["lang"]
}

private func audioTrackKind(from data: JSONDictionary, url: String) -> String? {
    if let audioTrack = data["audioTrack"] as? JSONDictionary {
        if let kind = stringify(audioTrack["audioTrackKind"]) ?? stringify(audioTrack["kind"]) {
            return kind
        }
    }

    if let note = stringify(data["format_note"])?.lowercased() {
        if note.contains("original") {
            return "original"
        }
        if note.contains("dubbed") || note.contains("translated") {
            return "dubbed-auto"
        }
    }

    return audioTrackAttributes(from: url)["acont"]
}

private func audioTrackKind(from data: [String: String], url: String) -> String? {
    data["ACONT"] ?? data["acont"] ?? audioTrackAttributes(from: url)["acont"]
}

private func audioIsDefault(from data: JSONDictionary, url: String) -> Bool? {
    if let audioTrack = data["audioTrack"] as? JSONDictionary,
       let value = audioTrack["audioIsDefault"] as? Bool {
        return value
    }

    if let note = stringify(data["format_note"])?.lowercased(),
       note.contains("default") {
        return true
    }

    let attributes = audioTrackAttributes(from: url)
    if attributes["acont"] == "original", attributes["lang"]?.hasPrefix("en") == true {
        return true
    }

    return nil
}

private func audioLanguage(fromAudioTrackID id: String) -> String? {
    let parts = id.split(separator: ".").map(String.init)
    return parts.first { part in
        part.range(of: #"^[a-z]{2,3}(-[A-Za-z0-9]+)?$"#, options: .regularExpression) != nil
    }
}

private func audioTrackAttributes(from url: String) -> [String: String] {
    guard let components = URLComponents(string: url),
          let xtags = components.queryItems?.first(where: { $0.name == "xtags" })?.value else {
        return [:]
    }

    return xtags
        .split(separator: ":")
        .reduce(into: [String: String]()) { result, part in
            let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { return }
            result[pieces[0]] = pieces[1]
        }
}

private func stringify(_ value: Any?) -> String? {
    if let value = value as? String {
        return value
    }
    if let value = value as? Int {
        return String(value)
    }
    if let value = value as? Double {
        return String(Int(value))
    }
    return nil
}

private func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int {
        return value
    }
    if let value = value as? Double {
        return Int(value)
    }
    if let value = value as? String {
        return Int(value)
    }
    return nil
}

private func doubleValue(_ value: Any?) -> Double? {
    if let value = value as? Double {
        return value
    }
    if let value = value as? Int {
        return Double(value)
    }
    if let value = value as? String {
        return Double(value)
    }
    return nil
}

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
