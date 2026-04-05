import Foundation

private struct SponsorBlockSegmentPayload: Decodable {
    let segment: [Double]
    let UUID: String
    let category: String
    let videoDuration: Double
    let actionType: String
    let votes: Int
    let description: String
}

actor SponsorBlockClient {
    static let shared = SponsorBlockClient()

    private let session: URLSession
    private var cache: [String: [SponsorBlockSegment]] = [:]

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: configuration)
    }

    func fetchSegments(videoID: String, duration: Double?) async -> [SponsorBlockSegment] {
        if let cached = cache[videoID] {
            return cached
        }

        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments")!
        components.queryItems = [
            URLQueryItem(name: "videoID", value: videoID),
            URLQueryItem(name: "category", value: "sponsor"),
            URLQueryItem(name: "actionType", value: "skip"),
            URLQueryItem(name: "service", value: "YouTube")
        ]

        guard let url = components.url else {
            cache[videoID] = []
            return []
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                cache[videoID] = []
                return []
            }

            if httpResponse.statusCode == 404 {
                cache[videoID] = []
                return []
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                cache[videoID] = []
                return []
            }

            let payload = try JSONDecoder().decode([SponsorBlockSegmentPayload].self, from: data)
            let segments = payload.compactMap { item -> SponsorBlockSegment? in
                guard item.segment.count == 2 else { return nil }
                let start = max(item.segment[0], 0)
                let end = max(item.segment[1], 0)
                guard end - start >= 0.35 else { return nil }
                guard item.category == "sponsor", item.actionType == "skip" else { return nil }

                if let duration,
                   duration > 0,
                   item.videoDuration > 0,
                   abs(item.videoDuration - duration) > max(5, duration * 0.12) {
                    return nil
                }

                return SponsorBlockSegment(
                    id: item.UUID,
                    category: item.category,
                    actionType: item.actionType,
                    startTime: start,
                    endTime: end,
                    votes: item.votes,
                    description: item.description
                )
            }
            .sorted { lhs, rhs in
                lhs.startTime == rhs.startTime
                    ? lhs.endTime < rhs.endTime
                    : lhs.startTime < rhs.startTime
            }

            cache[videoID] = segments
            return segments
        } catch {
            cache[videoID] = []
            return []
        }
    }
}
