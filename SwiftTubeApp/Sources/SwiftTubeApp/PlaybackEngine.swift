import Foundation

struct MediaStreamRequest: Hashable, Sendable {
    let url: URL
    let headers: [String: String]

    init(url: URL, headers: [String: String]?) {
        self.url = url
        self.headers = headers ?? [:]
    }
}

enum MPVPlaybackMode: Hashable, Sendable {
    case direct
    case adaptiveManifest
}

struct MPVPlaybackRequest: Hashable, Sendable {
    let video: MediaStreamRequest
    let audio: MediaStreamRequest?
    let mode: MPVPlaybackMode

    init(
        video: MediaStreamRequest,
        audio: MediaStreamRequest?,
        mode: MPVPlaybackMode = .direct
    ) {
        self.video = video
        self.audio = audio
        self.mode = mode
    }
}
