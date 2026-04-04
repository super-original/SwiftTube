import Foundation

actor SwiftTubeBackend {
    static let shared = SwiftTubeBackend()

    private let authManager = YouTubeAuthManager()
    private lazy var api = YouTubeAPI(authManager: authManager)
    private var channelAvatarCache: [String: String?] = [:]

    func start() async throws {
        // The in-process backend has no bootstrap work; auth validation happens on demand.
    }

    func authStatus() async throws -> AuthStatusResponse {
        guard await authManager.currentMaterial() != nil else {
            return .signedOut
        }

        do {
            try await api.validateAuthentication()
            return await authManager.authStatus()
        } catch {
            _ = try? await authManager.clear()
            return AuthStatusResponse(
                authenticated: false,
                browser: nil,
                browserLabel: nil,
                message: error.localizedDescription
            )
        }
    }

    func connectBrowserAuth(browser: String) async throws -> AuthStatusResponse {
        let status = try await authManager.connect(browser: browser)
        do {
            try await api.validateAuthentication()
            return status
        } catch {
            _ = try? await authManager.clear()
            throw error
        }
    }

    func clearAuthSession() async throws -> AuthStatusResponse {
        try await authManager.clear()
    }

    func fetchRecommendations(continuation: String? = nil) async throws -> RecommendationsResponse {
        var note: String?
        let usingAuth = await authManager.currentMaterial() != nil

        let data: JSONDictionary
        if usingAuth {
            do {
                data = try await loadRecommendations(continuation: continuation, authenticated: true)
            } catch {
                _ = try? await authManager.clear()
                note = "Your saved YouTube session expired. Showing public picks instead."
                data = try await loadRecommendations(continuation: continuation, authenticated: false)
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
                note = "History is off on YouTube. Showing Explore picks instead."
                items = fallbackItems
                token = nil
            }
        }

        return RecommendationsResponse(items: items, continuation: token, note: note)
    }

    func fetchSearch(query: String, continuation: String? = nil) async throws -> SearchResponse {
        let usingAuth = await authManager.currentMaterial() != nil

        let data: JSONDictionary
        if usingAuth {
            do {
                data = try await api.search(query: continuation == nil ? query : nil, continuation: continuation, authenticated: true)
            } catch {
                _ = try? await authManager.clear()
                data = try await api.search(query: continuation == nil ? query : nil, continuation: continuation, authenticated: false)
            }
        } else {
            data = try await api.search(query: continuation == nil ? query : nil, continuation: continuation, authenticated: false)
        }

        return SearchResponse(
            items: extractVideoItems(from: data),
            continuation: extractContinuationToken(from: data),
            query: query
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

    func fetchVideo(id videoID: String) async throws -> VideoPlayback {
        let usingAuth = await authManager.currentMaterial() != nil

        if usingAuth {
            do {
                return try await buildVideoPlayback(videoID: videoID, authenticated: true)
            } catch {
                _ = try? await authManager.clear()
            }
        }

        return try await buildVideoPlayback(videoID: videoID, authenticated: false)
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
                    _ = try? await authManager.clear()
                }
                throw error
            }
        }

        let usingAuth = await authManager.currentMaterial() != nil
        if usingAuth {
            do {
                return try await buildCommentsResponse(videoID: videoID, authenticated: true)
            } catch {
                _ = try? await authManager.clear()
            }
        }

        return try await buildCommentsResponse(videoID: videoID, authenticated: false)
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

    func fetchPlaylistFeed(id playlistID: String, continuation: String? = nil) async throws -> PlaylistFeed {
        _ = try await requireAuthenticatedMaterial()
        let browseID = playlistID.hasPrefix("VL") ? playlistID : "VL\(playlistID)"
        let data = try await api.browse(
            browseID: continuation == nil ? browseID : nil,
            continuation: continuation,
            authenticated: true
        )
        return extractPlaylistFeed(from: data, playlistID: playlistID.removingPrefix("VL"))
    }

    func fetchRelatedVideos(id videoID: String, continuation: String? = nil) async throws -> RecommendationsResponse {
        let usingAuth = await authManager.currentMaterial() != nil
        if usingAuth {
            do {
                return try await buildRelatedResponse(videoID: videoID, continuation: continuation, authenticated: true)
            } catch {
                _ = try? await authManager.clear()
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
            items: extractRelatedVideos(from: data, currentVideoID: videoID),
            continuation: extractRelatedContinuationToken(from: data),
            note: nil
        )
    }

    private func buildVideoPlayback(videoID: String, authenticated: Bool) async throws -> VideoPlayback {
        async let watchTask = api.next(videoID: videoID, authenticated: authenticated)
        async let playerTask = api.player(videoID: videoID, profile: .webParentTools, authenticated: authenticated)
        async let webPlayerTask = api.player(videoID: videoID, profile: .web, authenticated: authenticated)

        let watchData = try await watchTask
        let playerData = try await playerTask
        let webPlayerData = (try? await webPlayerTask) ?? [:]

        let metadata = extractWatchMetadata(from: watchData)
        var playlistOptions: [PlaylistOption] = []
        if authenticated, extractWatchPageSaveCommand(from: watchData) != nil {
            if let sheet = try? await loadPlaylistSheet(from: watchData) {
                playlistOptions = extractPlaylistOptions(from: sheet)
            }
        }

        let playerStreams = mergeStreams(parseStreams(from: playerData))
        let playerSubtitles = extractSubtitles(from: playerData)
        let playerBundle = buildPlaybackBundle(
            streams: playerStreams,
            subtitles: playerSubtitles
        )

        let fallbackPlayback: YTDLPPlaybackData?
        if shouldUseYTDLPPlayback(for: playerBundle, streams: playerStreams) {
            fallbackPlayback = try await extractYTDLPPlayback(
                videoID: videoID,
                cookieFileURL: authenticated ? await authManager.playbackCookieFileURL() : nil
            )
        } else {
            fallbackPlayback = nil
        }
        let resolvedStreams = ((fallbackPlayback?.streams.isEmpty == false) ? fallbackPlayback?.streams : nil)
            ?? playerStreams
        guard !resolvedStreams.isEmpty else {
            throw BackendClientError(message: "No playable streams found")
        }

        let playbackBundle = buildPlaybackBundle(
            streams: resolvedStreams,
            subtitles: playerSubtitles + (fallbackPlayback?.subtitles ?? [])
        )
        let bestStream = pickBestStream(in: resolvedStreams)
        let details = playerData["videoDetails"] as? JSONDictionary
        let title: String? = metadata["title"] ?? fallbackPlayback?.title ?? (details?["title"] as? String)
        let duration = fallbackPlayback?.durationText ?? metadataDurationText(from: details)

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
            recommendations: extractRelatedVideos(from: watchData, currentVideoID: videoID),
            comments: [],
            playbackStrategy: playbackBundle.playbackStrategy,
            preferredManifestStream: playbackBundle.preferredManifestStream,
            preferredMuxedStream: playbackBundle.preferredMuxedStream ?? bestStream,
            preferredVideoStream: playbackBundle.preferredVideoStream,
            preferredAudioStream: playbackBundle.preferredAudioStream,
            bestStreamUrl: (playbackBundle.bestStream ?? bestStream)?.url,
            bestStream: playbackBundle.bestStream ?? bestStream,
            subtitles: deduplicatedSubtitles(playbackBundle.subtitles),
            storyboard: extractStoryboard(from: webPlayerData.isEmpty ? playerData : webPlayerData) ?? extractStoryboard(from: playerData),
            subscription: extractSubscriptionState(from: watchData, metadata: metadata),
            rating: extractRatingState(from: watchData),
            watchLater: findPlaylistOption(in: playlistOptions, playlistID: "WL"),
            playlistSaveEnabled: extractWatchPageSaveCommand(from: watchData) != nil,
            recommendationsContinuation: extractRelatedContinuationToken(from: watchData)
        )
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

    private func requireAuthenticatedMaterial() async throws -> AuthMaterial {
        guard let material = await authManager.currentMaterial() else {
            throw BackendClientError(message: "Sign in to YouTube to use this action.")
        }
        return material
    }

    private func loadRecommendations(continuation: String?, authenticated: Bool) async throws -> JSONDictionary {
        if let continuation {
            return try await api.browse(continuation: continuation, authenticated: authenticated)
        }
        return try await api.browse(browseID: "FEwhat_to_watch", authenticated: authenticated)
    }

    private func playlistBrowseID(for playlistID: String) -> String {
        playlistID.hasPrefix("VL") ? playlistID : "VL\(playlistID)"
    }
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

private struct YTDLPPlaybackData {
    let title: String?
    let durationText: String?
    let streams: [StreamInfo]
    let subtitles: [SubtitleTrack]
}

private func extractYTDLPPlayback(videoID: String, cookieFileURL: URL?) async throws -> YTDLPPlaybackData? {
    let ytDLPPath: URL
    do {
        ytDLPPath = try YTDLPTool.resolvePath()
    } catch {
        return nil
    }

    var arguments = [
        "-J",
        "--skip-download",
        "--quiet",
        "--no-warnings",
        "https://www.youtube.com/watch?v=\(videoID)",
    ]

    if let cookieFile = cookieFileURL {
        arguments.insert(contentsOf: ["--cookies", cookieFile.path], at: 0)
    }

    let result = try await ProcessRunner.run(executableURL: ytDLPPath, arguments: arguments)
    guard result.exitCode == 0, let data = result.output.data(using: .utf8) else { return nil }

    guard let payload = try JSONSerialization.jsonObject(with: data) as? JSONDictionary else {
        return nil
    }

    let streams = parseYTDLPStreams(from: payload)
    let subtitles = parseYTDLPSubtitles(from: payload)

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
    var merged: [StreamInfo] = []
    var seen = Set<String>()

    for group in groups {
        for stream in group {
            let key = "\(stream.url)|\(stream.formatId ?? "")|\(stream.streamKind)"
            if seen.insert(key).inserted {
                merged.append(stream)
            }
        }
    }

    return merged
}

private func deduplicatedSubtitles(_ subtitles: [SubtitleTrack]) -> [SubtitleTrack] {
    var seen = Set<String>()
    var merged: [SubtitleTrack] = []

    for subtitle in subtitles {
        let key = "\(subtitle.language)|\(subtitle.url)|\(subtitle.isAutoGenerated)"
        if seen.insert(key).inserted {
            merged.append(subtitle)
        }
    }

    return merged
}

private func buildPlaybackBundle(
    streams: [StreamInfo],
    subtitles: [SubtitleTrack]
) -> PlaybackBundle {
    PlaybackBundle(
        streams: streams,
        preferredManifestStream: bestManifestStream(in: streams),
        preferredMuxedStream: bestMuxedStream(in: streams),
        preferredVideoStream: bestVideoStream(in: streams),
        preferredAudioStream: bestAudioStream(in: streams),
        subtitles: subtitles
    )
}

private func shouldUseYTDLPPlayback(for bundle: PlaybackBundle, streams: [StreamInfo]) -> Bool {
    guard !streams.isEmpty else { return true }
    guard bundle.preferredManifestStream == nil else { return false }
    return bundle.preferredVideoStream == nil || bundle.preferredAudioStream == nil
}

private func bestManifestStream(in streams: [StreamInfo]) -> StreamInfo? {
    streams
        .filter { $0.streamKind == "manifest" && $0.hasVideo }
        .max(by: { manifestStreamScore($0) < manifestStreamScore($1) })
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

private func parseStreams(from playerResponse: JSONDictionary) -> [StreamInfo] {
    guard let streaming = playerResponse["streamingData"] as? JSONDictionary else {
        return []
    }

    var results: [StreamInfo] = []

    for key in ["formats", "adaptiveFormats"] {
        guard let entries = streaming[key] as? [Any] else { continue }
        for entry in entries {
            guard let entry = entry as? JSONDictionary else { continue }
            guard let url = entry["url"] as? String, !url.isEmpty else { continue }

            let mimeType = entry["mimeType"] as? String
            let parsedMime = parseMimeType(mimeType)
            let hasAudio = parsedMime.audioCodec != nil
                || entry["audioQuality"] != nil
                || entry["audioChannels"] != nil
                || (mimeType?.contains("audio/") == true)
            let hasVideo = parsedMime.videoCodec != nil
                || entry["qualityLabel"] != nil
                || (mimeType?.contains("video/") == true)

            results.append(
                StreamInfo(
                    url: url,
                    formatId: stringify(entry["itag"]),
                    mimeType: mimeType,
                    qualityLabel: entry["qualityLabel"] as? String,
                    httpHeaders: nil,
                    bitrate: intValue(entry["bitrate"]),
                    width: intValue(entry["width"]),
                    height: intValue(entry["height"]),
                    fps: intValue(entry["fps"]),
                    audioChannels: intValue(entry["audioChannels"]),
                    audioCodec: parsedMime.audioCodec ?? (entry["audioQuality"] as? String),
                    videoCodec: parsedMime.videoCodec,
                    container: parsedMime.container ?? (entry["container"] as? String),
                    hasAudio: hasAudio,
                    hasVideo: hasVideo,
                    isAdaptive: key == "adaptiveFormats",
                    streamKind: streamKind(for: url, hasAudio: hasAudio, hasVideo: hasVideo)
                )
            )
        }
    }

    return results
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
            streamKind: streamKind(for: url, hasAudio: hasAudio, hasVideo: hasVideo)
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
        guard let renderer else { return .continue }

        guard let videoID = renderer["videoId"] as? String, !videoID.isEmpty else {
            return .continue
        }
        guard seen.insert(videoID).inserted else { return .continue }

        let metadataParts = splitMetadataText(textValue(from: renderer["metadataText"]))
        items.append(
            VideoItem(
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
                durationText: textValue(from: renderer["lengthText"]),
                thumbnails: thumbnails(from: renderer["thumbnail"])
            )
        )

        return items.count >= limit ? .stop : .continue
    }

    return items
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
                thumbnails: sourceThumbnails(from: thumbnailImage)
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
                playlistCanMoveToBottom: menuFlags.moveBottom
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

private func extractStoryboard(from playerData: Any) -> StoryboardSpec? {
    guard let playerData = playerData as? JSONDictionary else { return nil }
    guard let spec = ((((playerData["storyboards"] as? JSONDictionary)?["playerStoryboardSpecRenderer"] as? JSONDictionary)?["spec"] as? String)), !spec.isEmpty else {
        return nil
    }

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
        tileWidth: best.1,
        tileHeight: best.2,
        cols: best.4,
        rows: best.5,
        intervalSeconds: Double(best.6) / 1000
    )
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

    return VideoItem(
        id: videoID,
        title: (metadata?["title"] as? JSONDictionary)?["content"] as? String ?? "Untitled",
        channel: channelRow.first,
        channelId: channelID(from: lockup),
        channelAvatarUrl: channelAvatarURL(from: lockup),
        viewCountText: statsRow.first,
        publishedTimeText: statsRow.count > 1 ? statsRow[1] : nil,
        durationText: extractLockupDuration(from: lockup),
        thumbnails: sourceThumbnails(from: thumbnailImage)
    )
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

private func manifestStreamScore(_ stream: StreamInfo) -> (Int, Int, Int, Int, Int, Int) {
    (
        stream.hasAudio ? 1 : 0,
        stream.hasVideo ? 1 : 0,
        stream.height ?? 0,
        stream.fps ?? 0,
        stream.bitrate ?? 0,
        codecScore(stream.videoCodec)
    )
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
        return "\(baseLabel) (\(code))"
    }
    return code.uppercased()
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
