import Foundation

struct Thumbnail: Codable, Hashable, Sendable {
    let url: String
    let width: Int?
    let height: Int?
}

struct VideoProgress: Codable, Hashable, Sendable {
    let youtubeFraction: Double?
    let localElapsedSeconds: Double?
    let durationSeconds: Double?
    let lastUpdatedAt: Date?
    let localCompleted: Bool

    var normalizedYouTubeFraction: Double? {
        guard let youtubeFraction else { return nil }
        return min(max(youtubeFraction, 0), 1)
    }

    var normalizedLocalFraction: Double? {
        guard let localElapsedSeconds,
              let durationSeconds,
              durationSeconds > 0 else {
            return localCompleted ? 1 : nil
        }
        return min(max(localElapsedSeconds / durationSeconds, 0), 1)
    }

    var youtubeResumeSeconds: Double? {
        guard let fraction = normalizedYouTubeFraction,
              let durationSeconds,
              durationSeconds > 0,
              fraction < 0.98 else {
            return nil
        }
        return durationSeconds * fraction
    }

    var bestResumeSeconds: Double? {
        if localCompleted {
            return nil
        }

        switch (localElapsedSeconds, youtubeResumeSeconds) {
        case (.some(let local), .some(let youtube)):
            return max(local, youtube)
        case (.some(let local), .none):
            return local
        case (.none, .some(let youtube)):
            return youtube
        case (.none, .none):
            return nil
        }
    }

    func mergingLocal(_ local: VideoProgress?) -> VideoProgress {
        guard let local else { return self }
        return VideoProgress(
            youtubeFraction: youtubeFraction,
            localElapsedSeconds: local.localElapsedSeconds,
            durationSeconds: durationSeconds ?? local.durationSeconds,
            lastUpdatedAt: local.lastUpdatedAt,
            localCompleted: local.localCompleted
        )
    }
}

struct VideoItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let channel: String?
    let channelId: String?
    let channelAvatarUrl: String?
    let viewCountText: String?
    let publishedTimeText: String?
    let durationText: String?
    let thumbnails: [Thumbnail]
    var playlistSetVideoId: String? = nil
    var playlistIndexText: String? = nil
    var playlistSelected: Bool? = nil
    var playlistCanRemove: Bool = false
    var playlistCanMoveToTop: Bool = false
    var playlistCanMoveToBottom: Bool = false
    var progress: VideoProgress? = nil
    var tags: [VideoTag] = []

    var thumbnailURL: URL? {
        guard let urlString = thumbnails.last?.url else { return nil }
        return URL(string: urlString)
    }

    var channelAvatarURL: URL? {
        guard let channelAvatarUrl else { return nil }
        return URL(string: channelAvatarUrl)
    }

    var channelReference: ChannelReference? {
        guard let channelId else { return nil }
        return ChannelReference(channelId: channelId, title: channel, canonicalBaseUrl: nil)
    }

    var isMembersOnly: Bool {
        tags.contains(where: \.isMembersOnly)
    }

    var isLive: Bool {
        tags.contains(where: \.isLive)
    }

    var playlistIdentity: String {
        playlistSetVideoId ?? id
    }

    func withResolvedChannelIdentity(
        channel: String? = nil,
        channelId: String? = nil,
        channelAvatarUrl: String? = nil
    ) -> VideoItem {
        VideoItem(
            id: id,
            title: title,
            channel: channel ?? self.channel,
            channelId: channelId ?? self.channelId,
            channelAvatarUrl: channelAvatarUrl ?? self.channelAvatarUrl,
            viewCountText: viewCountText,
            publishedTimeText: publishedTimeText,
            durationText: durationText,
            thumbnails: thumbnails,
            playlistSetVideoId: playlistSetVideoId,
            playlistIndexText: playlistIndexText,
            playlistSelected: playlistSelected,
            playlistCanRemove: playlistCanRemove,
            playlistCanMoveToTop: playlistCanMoveToTop,
            playlistCanMoveToBottom: playlistCanMoveToBottom,
            progress: progress,
            tags: tags
        )
    }
}

struct RecommendationsResponse: Codable, Sendable {
    let items: [VideoItem]
    let continuation: String?
    let note: String?
}

struct ChannelAvatarResponse: Codable, Sendable {
    let channelId: String
    let avatarUrl: String?

    var avatarURL: URL? {
        guard let avatarUrl else { return nil }
        return URL(string: avatarUrl)
    }
}

struct SearchResponse: Codable, Sendable {
    let items: [VideoItem]
    let channels: [SearchChannelItem]
    let playlists: [PlaylistSummary]
    let filterGroups: [SearchFilterGroup]
    let continuation: String?
    let query: String
}

struct SearchChannelItem: Codable, Hashable, Identifiable, Sendable {
    let channelId: String
    let title: String
    let handle: String?
    let subscriberCountText: String?
    let descriptionText: String?
    let avatarUrl: String?
    let canonicalBaseUrl: String?

    var id: String { channelId }
    var avatarURL: URL? { avatarUrl.flatMap(URL.init(string:)) }
    var reference: ChannelReference {
        ChannelReference(channelId: channelId, title: title, canonicalBaseUrl: canonicalBaseUrl)
    }
}

struct SearchFilterGroup: Codable, Hashable, Identifiable, Sendable {
    let title: String
    let options: [SearchFilterOption]

    var id: String { title }
}

struct SearchFilterOption: Codable, Hashable, Identifiable, Sendable {
    let title: String
    let params: String?
    let selected: Bool

    var id: String { "\(title)|\(params ?? "selected")" }
}

struct WatchHistoryResponse: Codable, Sendable {
    let items: [VideoItem]
    let continuation: String?
}

enum WatchHistoryTrimRange: String, Codable, CaseIterable, Sendable {
    case hour
    case day
    case week
}

struct SearchSuggestionsResponse: Codable, Sendable {
    let query: String
    let suggestions: [String]
}

struct ChannelReference: Codable, Hashable, Identifiable, Sendable {
    let channelId: String
    let title: String?
    let canonicalBaseUrl: String?

    var id: String { channelId }
}

enum ChannelTabKind: String, CaseIterable, Codable, Hashable, Sendable {
    case videos
    case shorts
    case live
    case playlists
    case posts
    case about
    case search

    var title: String {
        switch self {
        case .videos:
            return "Videos"
        case .shorts:
            return "Shorts"
        case .live:
            return "Live"
        case .playlists:
            return "Playlists"
        case .posts:
            return "Posts"
        case .about:
            return "About"
        case .search:
            return "Search"
        }
    }
}

struct ChannelTabSummary: Codable, Hashable, Identifiable, Sendable {
    let kind: ChannelTabKind
    let title: String

    var id: String { kind.rawValue }
}

struct ChannelSortOption: Codable, Hashable, Identifiable, Sendable {
    let title: String
    let continuationToken: String
    let isSelected: Bool

    var id: String { title }
}

struct ChannelHeader: Codable, Hashable, Sendable {
    let channel: ChannelReference
    let handleText: String?
    let avatarUrl: String?
    let bannerUrl: String?
    let descriptionPreview: String?
    let subscriberCountText: String?
    let videoCountText: String?
    let subscribeButtonTitle: String?
    let aboutContinuationToken: String?

    var avatarURL: URL? {
        guard let avatarUrl else { return nil }
        return URL(string: avatarUrl)
    }

    var bannerURL: URL? {
        guard let bannerUrl else { return nil }
        return URL(string: bannerUrl)
    }
}

struct ChannelLink: Codable, Hashable, Identifiable, Sendable {
    let title: String
    let url: String
    let faviconUrl: String?

    var id: String { "\(title)|\(url)" }

    var resolvedURL: URL? {
        if let direct = URL(string: url), isYouTubeRedirect(direct),
           let components = URLComponents(url: direct, resolvingAgainstBaseURL: false),
           let target = components.queryItems?.first(where: { $0.name == "q" })?.value,
           let decoded = Optional(target.removingPercentEncoding ?? target),
           let resolved = URL(string: decoded) {
            return resolved
        }

        return URL(string: url)
    }

    var displayURL: String {
        guard let resolvedURL else {
            return url
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "mailto:", with: "")
        }

        if resolvedURL.scheme == "mailto" {
            return resolvedURL.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        }

        let host = resolvedURL.host ?? resolvedURL.absoluteString
        let path = resolvedURL.path == "/" ? "" : resolvedURL.path
        let condensed = "\(host)\(path)"
        return condensed.replacingOccurrences(of: "//", with: "/")
    }

    var faviconURL: URL? {
        guard let faviconUrl else { return nil }
        return URL(string: faviconUrl)
    }

    private func isYouTubeRedirect(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("youtube.com") && url.path == "/redirect"
    }
}

struct ChannelAbout: Codable, Hashable, Sendable {
    let description: String?
    let canonicalChannelUrl: String?
    let displayCanonicalChannelUrl: String?
    let joinedDateText: String?
    let subscriberCountText: String?
    let videoCountText: String?
    let viewCountText: String?
    let country: String?
    let linksLabel: String?
    let links: [ChannelLink]
    let businessEmailPrompt: String?
    let businessEmailURL: String?
}

struct ChannelPost: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let author: String
    let authorChannelId: String?
    let authorAvatarUrl: String?
    let content: String
    let publishedTimeText: String?
    let likeCountText: String?
    let commentCountText: String?
    let attachedVideo: VideoItem?

    var authorAvatarURL: URL? {
        guard let authorAvatarUrl else { return nil }
        return URL(string: authorAvatarUrl)
    }
}

enum ChannelContentItem: Hashable, Identifiable, Sendable {
    case video(VideoItem)
    case playlist(PlaylistSummary)
    case post(ChannelPost)

    var id: String {
        switch self {
        case .video(let video):
            return "video:\(video.id)"
        case .playlist(let playlist):
            return "playlist:\(playlist.id)"
        case .post(let post):
            return "post:\(post.id)"
        }
    }
}

struct ChannelPageResponse: Sendable {
    let header: ChannelHeader
    let tabs: [ChannelTabSummary]
    let selectedTab: ChannelTabKind
    let items: [ChannelContentItem]
    let sortOptions: [ChannelSortOption]
    let filterOptions: [ChannelSortOption]
    let continuation: String?
    let searchQuery: String?
    let subscription: SubscriptionState?
    let subscriptionCommands: [String: InnerTubeCommand?]
}

struct ChannelPageContinuationResponse: Sendable {
    let items: [ChannelContentItem]
    let sortOptions: [ChannelSortOption]
    let filterOptions: [ChannelSortOption]
    let continuation: String?
}

struct ChannelAboutResponse: Sendable {
    let about: ChannelAbout
}

struct StreamInfo: Codable, Hashable, Sendable {
    let url: String
    let formatId: String?
    let mimeType: String?
    let qualityLabel: String?
    let httpHeaders: [String: String]?
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let fps: Int?
    let audioChannels: Int?
    let audioCodec: String?
    let videoCodec: String?
    let container: String?
    let hasAudio: Bool
    let hasVideo: Bool
    let isAdaptive: Bool
    let streamKind: String
    let audioLanguage: String?
    let audioTrackKind: String?
    let audioLanguagePreference: Int?
    let audioIsDefault: Bool?

    init(
        url: String,
        formatId: String?,
        mimeType: String?,
        qualityLabel: String?,
        httpHeaders: [String: String]?,
        bitrate: Int?,
        width: Int?,
        height: Int?,
        fps: Int?,
        audioChannels: Int?,
        audioCodec: String?,
        videoCodec: String?,
        container: String?,
        hasAudio: Bool,
        hasVideo: Bool,
        isAdaptive: Bool,
        streamKind: String,
        audioLanguage: String? = nil,
        audioTrackKind: String? = nil,
        audioLanguagePreference: Int? = nil,
        audioIsDefault: Bool? = nil
    ) {
        self.url = url
        self.formatId = formatId
        self.mimeType = mimeType
        self.qualityLabel = qualityLabel
        self.httpHeaders = httpHeaders
        self.bitrate = bitrate
        self.width = width
        self.height = height
        self.fps = fps
        self.audioChannels = audioChannels
        self.audioCodec = audioCodec
        self.videoCodec = videoCodec
        self.container = container
        self.hasAudio = hasAudio
        self.hasVideo = hasVideo
        self.isAdaptive = isAdaptive
        self.streamKind = streamKind
        self.audioLanguage = audioLanguage
        self.audioTrackKind = audioTrackKind
        self.audioLanguagePreference = audioLanguagePreference
        self.audioIsDefault = audioIsDefault
    }
}

struct InlinePlaybackPayload: Sendable {
    let id: String
    let title: String?
    let durationText: String?
    let durationSeconds: Double?
    let videoStream: StreamInfo
    let audioStream: StreamInfo?
    let storyboard: StoryboardSpec?
    let progress: VideoProgress?
}

struct VideoTagColor: Codable, Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double

    init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }
}

struct VideoTag: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let label: String
    let systemImageName: String
    let foregroundColor: VideoTagColor
    let backgroundColor: VideoTagColor

    var isLive: Bool {
        id == "live"
    }

    var isMembersOnly: Bool {
        id == "members-only"
    }

    static let live = VideoTag(
        id: "live",
        label: "Live",
        systemImageName: "dot.radiowaves.left.and.right",
        foregroundColor: VideoTagColor(red: 1, green: 1, blue: 1, opacity: 1),
        backgroundColor: VideoTagColor(red: 1, green: 0, blue: 0.2, opacity: 0.96)
    )

    static let membersOnly = VideoTag(
        id: "members-only",
        label: "Members only",
        systemImageName: "star.circle.fill",
        foregroundColor: VideoTagColor(red: 0.18, green: 0.82, blue: 0.34, opacity: 1),
        backgroundColor: VideoTagColor(red: 0.12, green: 0.26, blue: 0.14, opacity: 0.94)
    )
}

enum VideoAccessIssueKind: String, Codable, Hashable, Sendable {
    case membersOnly
    case unavailable
}

struct VideoAccessIssue: Codable, Hashable, Sendable {
    let kind: VideoAccessIssueKind
    let title: String
    let message: String
}

struct CommentItem: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let author: String
    let avatarUrl: String?
    let body: String
    let likeCountText: String?
    let publishedTimeText: String?
    let replyCountText: String?
    let pinnedText: String?

    var avatarURL: URL? {
        guard let avatarUrl else { return nil }
        return URL(string: avatarUrl)
    }
}

struct CommentsResponse: Codable, Sendable {
    let comments: [CommentItem]
    let commentCountText: String?
    let continuation: String?
}

enum LiveChatMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case top
    case live

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top:
            return "Top chat"
        case .live:
            return "Live chat"
        }
    }
}

struct LiveChatSession: Codable, Hashable, Sendable {
    let initialContinuation: String?
    let topChatContinuation: String?
    let liveChatContinuation: String?
    let defaultMode: LiveChatMode
    let isReplay: Bool

    var tabTitle: String {
        isReplay ? "Live Chat Replay" : "Live Chat"
    }
}

enum LiveChatMessageFragmentKind: String, Codable, Hashable, Sendable {
    case text
    case mention
    case link
    case emoji
}

struct LiveChatMessageFragment: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let text: String
    let kind: LiveChatMessageFragmentKind
    let url: String?
    let emojiImageUrl: String?
}

enum LiveChatMessageKind: String, Codable, Hashable, Sendable {
    case text
    case paid
    case paidSticker
    case membership
    case system
}

struct LiveChatMessage: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let kind: LiveChatMessageKind
    let author: String?
    let authorChannelId: String?
    let avatarUrl: String?
    let fragments: [LiveChatMessageFragment]
    let timestampUsec: String?
    let purchaseAmountText: String?
    let isVerified: Bool
    let isOwner: Bool
    let isModerator: Bool
    let isMember: Bool
    let isPending: Bool

    var avatarURL: URL? {
        guard let avatarUrl else { return nil }
        return URL(string: avatarUrl)
    }

    var plainText: String {
        fragments.map(\.text).joined()
    }
}

struct LiveChatComposer: Codable, Hashable, Sendable {
    let authorName: String?
    let placeholder: String?
    let maxCharacterLimit: Int
    let sendParams: String?
    let clientIdPrefix: String?
    let datasyncId: String?
    let restrictedMessage: String?
}

struct LiveChatResponse: Codable, Sendable {
    let mode: LiveChatMode
    let messages: [LiveChatMessage]
    let replacedMessages: [LiveChatMessage]
    let removedMessageIDs: [String]
    let continuation: String?
    let timeoutMs: Int?
    let composer: LiveChatComposer?
    let viewerName: String?
}

struct TranscriptSegment: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let startTime: Double
    let duration: Double
    let text: String
}

struct TranscriptResponse: Codable, Sendable {
    let track: SubtitleTrack?
    let segments: [TranscriptSegment]
}

struct LiveStoryboardTimeline: Codable, Hashable, Sendable {
    let firstSequence: Int
    let segmentDurations: [Double]
    let trailingHiddenSegmentCount: Int

    var coveredDurationSeconds: Double {
        segmentDurations.reduce(0) { $0 + max($1, 0) }
    }

    var lastSequence: Int? {
        guard segmentDurations.isEmpty == false else { return nil }
        return firstSequence + segmentDurations.count - 1
    }

    func sequence(at seconds: Double) -> Int? {
        guard let lastSequence else { return nil }

        let latestVisibleSequence = lastSequence - max(trailingHiddenSegmentCount, 0)
        guard latestVisibleSequence >= firstSequence else { return nil }

        var remaining = max(seconds, 0)
        for (offset, duration) in segmentDurations.enumerated() {
            let clampedDuration = max(duration, 0.001)
            let sequence = firstSequence + offset
            if remaining < clampedDuration || offset == segmentDurations.count - 1 {
                return sequence <= latestVisibleSequence ? sequence : nil
            }
            remaining -= clampedDuration
        }

        return nil
    }
}

struct StoryboardSpec: Codable, Sendable {
    let urls: [String]           // one URL per sprite-sheet file (file index = array index)
    let urlPattern: String?
    let tileWidth: Int
    let tileHeight: Int
    let frameCount: Int
    let cols: Int
    let rows: Int
    let intervalSeconds: Double
    let liveTimeline: LiveStoryboardTimeline?

    var coveredDurationSeconds: Double {
        if let liveTimeline {
            return liveTimeline.coveredDurationSeconds
        }
        guard frameCount > 0, intervalSeconds > 0 else { return 0 }
        return Double(frameCount) * intervalSeconds
    }

    /// Returns the sprite-sheet URL, column, and row for the tile that covers `seconds`.
    func tileInfo(at seconds: Double) -> (url: URL, col: Int, row: Int)? {
        let framesPerFile = cols * rows
        guard cols > 0, rows > 0, frameCount > 0, framesPerFile > 0 else { return nil }

        if let liveTimeline, let urlPattern {
            guard let sequence = liveTimeline.sequence(at: seconds) else { return nil }
            let fileIndex = sequence / framesPerFile
            let posInFile = sequence % framesPerFile
            guard let url = URL(string: urlPattern.replacingOccurrences(of: "$M", with: String(fileIndex))) else {
                return nil
            }
            return (url, posInFile % cols, posInFile / cols)
        }

        guard intervalSeconds > 0, !urls.isEmpty else { return nil }
        let frameIndex = Int(seconds / intervalSeconds)
        guard frameIndex >= 0, frameIndex < frameCount else { return nil }
        let fileIndex = frameIndex / framesPerFile
        guard fileIndex < urls.count, let url = URL(string: urls[fileIndex]) else { return nil }
        let posInFile = frameIndex % framesPerFile
        return (url, posInFile % cols, posInFile / cols)
    }
}

struct SponsorBlockSegment: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let category: String
    let actionType: String
    let startTime: Double
    let endTime: Double
    let votes: Int
    let description: String

    var duration: Double {
        max(endTime - startTime, 0)
    }
}

struct SubtitleTrack: Codable, Hashable, Sendable {
    let language: String
    let label: String
    let url: String
    let isAutoGenerated: Bool
}

struct SubscriptionState: Codable, Hashable, Sendable {
    let channelId: String
    let buttonText: String?
    let subscribed: Bool
    let enabled: Bool
    let subscriberCountText: String?
}

struct RatingState: Codable, Hashable, Sendable {
    let status: String
    let likeCountText: String?
}

struct PlaylistOption: Codable, Hashable, Identifiable, Sendable {
    let playlistId: String
    let title: String
    let privacy: String?
    let containsSelectedVideos: String
    let saved: Bool

    var id: String { playlistId }
}

struct PlaylistSummary: Codable, Hashable, Identifiable, Sendable {
    let playlistId: String
    let title: String
    let privacy: String?
    let itemCountText: String?
    let updatedText: String?
    let thumbnails: [Thumbnail]

    var id: String { playlistId }

    var thumbnailURL: URL? {
        guard let urlString = thumbnails.last?.url else { return nil }
        return URL(string: urlString)
    }

    var artworkAspectRatio: Double {
        guard let thumbnail = thumbnails.last,
              let width = thumbnail.width,
              let height = thumbnail.height,
              height > 0 else {
            return 16.0 / 9.0
        }
        let ratio = Double(width) / Double(height)
        return (0.78...1.28).contains(ratio) ? 1 : 16.0 / 9.0
    }

    var hasSquareArtwork: Bool {
        artworkAspectRatio == 1
    }

    var referenceKind: PlaylistReference.Kind {
        switch playlistId {
        case "WL":
            return .watchLater
        case "LL":
            return .likedVideos
        default:
            return .userPlaylist
        }
    }
}

struct PlaylistFeed: Codable, Sendable {
    let playlistId: String
    let title: String
    let ownerText: String?
    let privacy: String?
    let itemCountText: String?
    let items: [VideoItem]
    let continuation: String?

    func with(
        title: String? = nil,
        ownerText: String? = nil,
        privacy: String? = nil,
        itemCountText: String? = nil,
        items: [VideoItem]? = nil,
        continuation: String? = nil
    ) -> PlaylistFeed {
        PlaylistFeed(
            playlistId: playlistId,
            title: title ?? self.title,
            ownerText: ownerText ?? self.ownerText,
            privacy: privacy ?? self.privacy,
            itemCountText: itemCountText ?? self.itemCountText,
            items: items ?? self.items,
            continuation: continuation ?? self.continuation
        )
    }
}

enum PlaylistLoopMode: String, Codable, CaseIterable {
    case off
    case all
    case one

    var title: String {
        switch self {
        case .off: return "Loop Off"
        case .all: return "Loop Playlist"
        case .one: return "Loop Video"
        }
    }

    var symbolName: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

struct VideoPlayback: Codable, Sendable {
    let id: String
    let title: String?
    let channel: String?
    let channelId: String?
    let channelAvatarUrl: String?
    let subscriberCountText: String?
    let viewCountText: String?
    let publishedTimeText: String?
    let publishedDateText: String?
    let likeCountText: String?
    let durationText: String?
    let description: String?
    let commentCountText: String?
    let streams: [StreamInfo]
    let recommendations: [VideoItem]
    let comments: [CommentItem]
    let playbackStrategy: String
    let preferredManifestStream: StreamInfo?
    let preferredMuxedStream: StreamInfo?
    let preferredVideoStream: StreamInfo?
    let preferredAudioStream: StreamInfo?
    let bestStreamUrl: String?
    let bestStream: StreamInfo?
    let subtitles: [SubtitleTrack]?
    let storyboard: StoryboardSpec?
    let sponsorSegments: [SponsorBlockSegment]
    let progress: VideoProgress?
    let resumeStartTimeSeconds: Double?
    let subscription: SubscriptionState?
    let rating: RatingState?
    let watchLater: PlaylistOption?
    let playlistSaveEnabled: Bool
    let recommendationsContinuation: String?
    let tags: [VideoTag]
    let accessIssue: VideoAccessIssue?
    let isLive: Bool
    let isUpcoming: Bool
    let liveWindowDurationSeconds: Double?
    let liveChat: LiveChatSession?

    var channelAvatarURL: URL? {
        guard let channelAvatarUrl else { return nil }
        return URL(string: channelAvatarUrl)
    }

    var channelReference: ChannelReference? {
        guard let channelId else { return nil }
        return ChannelReference(channelId: channelId, title: channel, canonicalBaseUrl: nil)
    }

    func with(
        subscriberCountText: String? = nil,
        likeCountText: String? = nil,
        subscription: SubscriptionState? = nil,
        rating: RatingState? = nil,
        watchLater: PlaylistOption? = nil,
        progress: VideoProgress? = nil,
        resumeStartTimeSeconds: Double? = nil,
        sponsorSegments: [SponsorBlockSegment]? = nil
    ) -> VideoPlayback {
        VideoPlayback(
            id: id,
            title: title,
            channel: channel,
            channelId: channelId,
            channelAvatarUrl: channelAvatarUrl,
            subscriberCountText: subscriberCountText ?? self.subscriberCountText,
            viewCountText: viewCountText,
            publishedTimeText: publishedTimeText,
            publishedDateText: publishedDateText,
            likeCountText: likeCountText ?? self.likeCountText,
            durationText: durationText,
            description: description,
            commentCountText: commentCountText,
            streams: streams,
            recommendations: recommendations,
            comments: comments,
            playbackStrategy: playbackStrategy,
            preferredManifestStream: preferredManifestStream,
            preferredMuxedStream: preferredMuxedStream,
            preferredVideoStream: preferredVideoStream,
            preferredAudioStream: preferredAudioStream,
            bestStreamUrl: bestStreamUrl,
            bestStream: bestStream,
            subtitles: subtitles,
            storyboard: storyboard,
            sponsorSegments: sponsorSegments ?? self.sponsorSegments,
            progress: progress ?? self.progress,
            resumeStartTimeSeconds: resumeStartTimeSeconds ?? self.resumeStartTimeSeconds,
            subscription: subscription ?? self.subscription,
            rating: rating ?? self.rating,
            watchLater: watchLater ?? self.watchLater,
            playlistSaveEnabled: playlistSaveEnabled,
            recommendationsContinuation: recommendationsContinuation,
            tags: tags,
            accessIssue: accessIssue,
            isLive: isLive,
            isUpcoming: isUpcoming,
            liveWindowDurationSeconds: liveWindowDurationSeconds,
            liveChat: liveChat
        )
    }
}

struct AuthStatusResponse: Codable, Equatable, Sendable {
    let authenticated: Bool
    let browser: String?
    let browserLabel: String?
    let message: String?
    let avatarUrl: String?
    let displayName: String?
    let email: String?
    let handle: String?

    var avatarURL: URL? {
        guard let avatarUrl else { return nil }
        return URL(string: avatarUrl)
    }

    var accountIdentifier: String? {
        email?.nonEmptyModelText ?? handle?.nonEmptyModelText
    }

    static let signedOut = AuthStatusResponse(
        authenticated: false,
        browser: nil,
        browserLabel: nil,
        message: nil,
        avatarUrl: nil,
        displayName: nil,
        email: nil,
        handle: nil
    )
}

private extension String {
    var nonEmptyModelText: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct BrowserAccountSource: Codable, Hashable, Identifiable, Sendable {
    let browser: String
    let browserLabel: String
    let bundleIdentifier: String?
    let profilePath: String?

    init(browser: String, browserLabel: String, bundleIdentifier: String?, profilePath: String? = nil) {
        self.browser = browser
        self.browserLabel = browserLabel
        self.bundleIdentifier = bundleIdentifier
        self.profilePath = profilePath
    }

    var id: String { "\(browser)|\(profilePath ?? "default")" }
}

struct BrowserAccountDiscoveryResponse: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let identifier: String?
    let avatarUrl: String?
    let sources: [BrowserAccountSource]

    var avatarURL: URL? {
        guard let avatarUrl else { return nil }
        return URL(string: avatarUrl)
    }
}

struct PlaylistOptionsResponse: Codable, Sendable {
    let options: [PlaylistOption]
}

struct PlaylistLibraryResponse: Codable, Sendable {
    let items: [PlaylistSummary]
    let continuation: String?
}

struct PlaybackProgressMutationResponse: Codable, Sendable {
    let progress: VideoProgress?
}

struct SubscriptionResponse: Codable, Sendable {
    let subscription: SubscriptionState?
}

struct RatingResponse: Codable, Sendable {
    let rating: RatingState?
}

struct WatchLaterResponse: Codable, Sendable {
    let watchLater: PlaylistOption?
}

struct PlaylistMutationResponse: Codable, Sendable {
    let playlist: PlaylistOption?
}

struct PlaylistItemMutationResponse: Codable, Sendable {
    let success: Bool
}

struct WatchHistoryMutationResponse: Codable, Sendable {
    let success: Bool
    let removedVideoIDs: [String]
    let removedCount: Int
}
