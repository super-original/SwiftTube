import Foundation

final class BackendClient {
    static let shared = BackendClient()

    private let baseURL = AppConfig.backendBaseURL
    private let decoder = JSONDecoder()

    private init() {}

    func fetchRecommendations(continuation: String? = nil) async throws -> RecommendationsResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("recommendations"), resolvingAgainstBaseURL: false)
        if let continuation {
            components?.queryItems = [URLQueryItem(name: "continuation", value: continuation)]
        }
        let url = components?.url ?? baseURL.appendingPathComponent("recommendations")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response)
        return try decoder.decode(RecommendationsResponse.self, from: data)
    }

    func fetchVideo(id: String) async throws -> VideoPlayback {
        let url = baseURL.appendingPathComponent("video/")
            .appendingPathComponent(id)
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response)
        return try decoder.decode(VideoPlayback.self, from: data)
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if (200..<300).contains(http.statusCode) { return }
        throw URLError(.badServerResponse)
    }
}
