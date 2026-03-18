import Foundation

@MainActor
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
        return try await performRequest(url: url)
    }

    func fetchVideo(id: String) async throws -> VideoPlayback {
        let url = baseURL.appendingPathComponent("video/")
            .appendingPathComponent(id)
        return try await performRequest(url: url)
    }

    func fetchComments(id: String) async throws -> CommentsResponse {
        let url = baseURL.appendingPathComponent("video/")
            .appendingPathComponent(id)
            .appendingPathComponent("comments")
        return try await performRequest(url: url)
    }

    func fetchAuthStatus() async throws -> AuthStatusResponse {
        try await performRequest(url: baseURL.appendingPathComponent("auth/status"))
    }

    func connectBrowserAuth(browser: String) async throws -> AuthStatusResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/browser"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["browser": browser])
        return try await performRequest(request: request)
    }

    func clearAuthSession() async throws -> AuthStatusResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/session"))
        request.httpMethod = "DELETE"
        return try await performRequest(request: request)
    }

    private func performRequest<T: Decodable>(url: URL) async throws -> T {
        try await performRequest(request: URLRequest(url: url))
    }

    private func performRequest<T: Decodable>(request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if (200..<300).contains(http.statusCode) { return }

        if let payload = try? decoder.decode(BackendErrorPayload.self, from: data) {
            throw BackendClientError(message: payload.detail)
        }

        throw BackendClientError(message: "The backend request failed.")
    }
}

struct BackendClientError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private struct BackendErrorPayload: Decodable {
    let detail: String
}
