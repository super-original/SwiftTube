import Foundation

struct Thumbnail: Codable, Hashable {
    let url: String
    let width: Int?
    let height: Int?
}

struct VideoItem: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let channel: String?
    let viewCountText: String?
    let publishedTimeText: String?
    let durationText: String?
    let thumbnails: [Thumbnail]

    var thumbnailURL: URL? {
        guard let urlString = thumbnails.last?.url else { return nil }
        return URL(string: urlString)
    }
}

struct RecommendationsResponse: Codable {
    let items: [VideoItem]
    let continuation: String?
    let note: String?
}

struct StreamInfo: Codable, Hashable {
    let url: String
    let formatId: String?
    let mimeType: String?
    let qualityLabel: String?
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let fps: Int?
    let audioCodec: String?
    let videoCodec: String?
    let container: String?
    let hasAudio: Bool
    let hasVideo: Bool
    let isAdaptive: Bool
}

struct CommentItem: Codable, Hashable, Identifiable {
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

struct VideoPlayback: Codable {
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
    let preferredMuxedStream: StreamInfo?
    let preferredVideoStream: StreamInfo?
    let preferredAudioStream: StreamInfo?
    let bestStreamUrl: String?
    let bestStream: StreamInfo?

    var channelAvatarURL: URL? {
        guard let channelAvatarUrl else { return nil }
        return URL(string: channelAvatarUrl)
    }
}
