import Foundation

struct MediaStreamRequest: Hashable, Sendable {
    let url: URL
    let headers: [String: String]

    init(url: URL, headers: [String: String]?) {
        self.url = url
        self.headers = headers ?? [:]
    }
}

struct MPVPlaybackRequest: Hashable, Sendable {
    let video: MediaStreamRequest
    let audio: MediaStreamRequest?
}
