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
    let thumbnails: [Thumbnail]
}

struct RecommendationsResponse: Codable {
    let items: [VideoItem]
    let continuation: String?
    let note: String?
}

struct StreamInfo: Codable, Hashable {
    let url: String
    let mimeType: String?
    let qualityLabel: String?
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let fps: Int?
    let hasAudio: Bool
    let hasVideo: Bool
    let isAdaptive: Bool
}

struct VideoPlayback: Codable {
    let id: String
    let title: String?
    let streams: [StreamInfo]
    let bestStreamUrl: String?
    let bestStream: StreamInfo?
}
