import Foundation

enum InnerTubeClientProfile: Hashable, Sendable {
    case web
    case webParentTools
    case mweb
}

private struct InnerTubeClientContext: Sendable {
    let clientName: String
    let clientVersion: String
    let clientID: Int
    let apiKey: String?
    let userAgent: String?
    let referer: String?

    var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "alt", value: "json")]
        if let apiKey {
            items.append(URLQueryItem(name: "key", value: apiKey))
        }
        return items
    }

    var requestHeaders: [String: String] {
        var headers: [String: String] = [
            "X-Goog-Api-Format-Version": "1",
            "X-YouTube-Client-Name": String(clientID),
            "X-YouTube-Client-Version": clientVersion,
        ]
        if let userAgent {
            headers["User-Agent"] = userAgent
        }
        if let referer {
            headers["Referer"] = referer
        }
        return headers
    }

    var requestContext: JSONDictionary {
        [
            "client": [
                "clientName": clientName,
                "clientVersion": clientVersion,
            ],
        ]
    }
}

private enum InnerTubeClients {
    static let web = InnerTubeClientContext(
        clientName: "WEB",
        clientVersion: "2.20250626.01.00",
        clientID: 1,
        apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8",
        userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/74.0.3729.157 Safari/537.36",
        referer: "https://www.youtube.com/"
    )

    static let webParentTools = InnerTubeClientContext(
        clientName: "WEB_PARENT_TOOLS",
        clientVersion: "1.20220403",
        clientID: 88,
        apiKey: nil,
        userAgent: web.userAgent,
        referer: nil
    )

    static let mweb = InnerTubeClientContext(
        clientName: "MWEB",
        clientVersion: "2.20211214.00.00",
        clientID: 2,
        apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8",
        userAgent: "Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/65.0.3325.181 Mobile Safari/537.36",
        referer: "https://m.youtube.com/"
    )

    static func context(for profile: InnerTubeClientProfile) -> InnerTubeClientContext {
        switch profile {
        case .web:
            return web
        case .webParentTools:
            return webParentTools
        case .mweb:
            return mweb
        }
    }
}

private struct VisitorKey: Hashable {
    let profile: InnerTubeClientProfile
    let authenticated: Bool
}

final class YouTubeAPI: @unchecked Sendable {
    private let baseURL = URL(string: "https://youtubei.googleapis.com/youtubei/v1/")!
    private let defaultAuthenticatedBaseURL = URL(string: "https://www.youtube.com/youtubei/v1/")!
    private let session: URLSession
    private let authManager: YouTubeAuthManager
    private var visitorData: [VisitorKey: String] = [:]

    init(authManager: YouTubeAuthManager) {
        self.authManager = authManager

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    func guide(authenticated: Bool = false) async throws -> JSONDictionary {
        try await request(profile: .web, endpoint: "guide", body: [:], authenticated: authenticated)
    }

    func browse(
        profile: InnerTubeClientProfile = .web,
        browseID: String? = nil,
        query: String? = nil,
        params: String? = nil,
        continuation: String? = nil,
        authenticated: Bool = false
    ) async throws -> JSONDictionary {
        var body: JSONDictionary = [:]
        if let browseID {
            body["browseId"] = browseID
        }
        if let query {
            body["query"] = query
        }
        if let params {
            body["params"] = params
        }
        if let continuation {
            body["continuation"] = continuation
        }
        return try await request(profile: profile, endpoint: "browse", body: body, authenticated: authenticated)
    }

    func search(
        query: String? = nil,
        continuation: String? = nil,
        authenticated: Bool = false
    ) async throws -> JSONDictionary {
        var body: JSONDictionary = [
            "query": query ?? "",
        ]
        if let continuation {
            body["continuation"] = continuation
        }
        return try await request(profile: .web, endpoint: "search", body: body, authenticated: authenticated)
    }

    func next(
        videoID: String? = nil,
        continuation: String? = nil,
        authenticated: Bool = false
    ) async throws -> JSONDictionary {
        var body: JSONDictionary = [:]
        if let videoID {
            body["videoId"] = videoID
        }
        if let continuation {
            body["continuation"] = continuation
        }
        return try await request(profile: .web, endpoint: "next", body: body, authenticated: authenticated)
    }

    func liveChat(
        continuation: String,
        isReplay: Bool = false,
        replayOffsetMs: Int? = nil,
        authenticated: Bool = false
    ) async throws -> JSONDictionary {
        var body: JSONDictionary = ["continuation": continuation]
        if isReplay, let replayOffsetMs {
            body["playerOffsetMs"] = replayOffsetMs
        }

        return try await request(
            profile: .web,
            endpoint: isReplay ? "live_chat/get_live_chat_replay" : "live_chat/get_live_chat",
            body: body,
            authenticated: authenticated
        )
    }

    func sendLiveChatMessage(
        message: String,
        params: String,
        clientMessageId: String,
        authenticated: Bool = true
    ) async throws -> JSONDictionary {
        try await request(
            profile: .web,
            endpoint: "live_chat/send_message",
            body: [
                "clientMessageId": clientMessageId,
                "params": params,
                "richMessage": [
                    "textSegments": [
                        [
                            "text": message,
                        ],
                    ],
                ],
            ],
            authenticated: authenticated
        )
    }

    func player(
        videoID: String,
        profile: InnerTubeClientProfile,
        authenticated: Bool = false
    ) async throws -> JSONDictionary {
        try await request(
            profile: profile,
            endpoint: "player",
            body: ["videoId": videoID],
            authenticated: authenticated
        )
    }

    func watchPage(videoID: String, authenticated: Bool = false) async throws -> String {
        let context = InnerTubeClients.context(for: .web)
        var components = URLComponents(string: "https://www.youtube.com/watch")!
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]

        guard let url = components.url else {
            throw BackendClientError(message: "Failed to build the YouTube watch page URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        for (header, value) in context.requestHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }

        if authenticated {
            for (header, value) in try await authManager.authHeaders(origin: "https://www.youtube.com", url: url) {
                request.setValue(value, forHTTPHeaderField: header)
            }
        }

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard let html = String(data: data, encoding: .utf8) else {
            throw BackendClientError(message: "YouTube returned an unreadable watch page.")
        }

        return html
    }

    func sendTrackingEvent(url: URL, videoID: String, authenticated: Bool) async throws {
        let context = InnerTubeClients.context(for: .web)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        for (header, value) in context.requestHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        request.setValue("https://www.youtube.com/watch?v=\(videoID)", forHTTPHeaderField: "Referer")

        if authenticated {
            for (header, value) in try await authManager.authHeaders(origin: "https://www.youtube.com", url: url) {
                request.setValue(value, forHTTPHeaderField: header)
            }
        }

        let (_, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: Data())
    }

    func dispatch(
        profile: InnerTubeClientProfile = .web,
        command: InnerTubeCommand,
        authenticated: Bool = true
    ) async throws -> JSONDictionary {
        try await request(profile: profile, endpoint: command.apiPath, body: command.payload, authenticated: authenticated)
    }

    func searchSuggestions(query: String) async throws -> [String] {
        var components = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "firefox"),
            URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "q", value: query),
        ]

        guard let url = components.url else {
            throw BackendClientError(message: "Failed to build the suggestions request.")
        }

        let (data, response) = try await session.data(for: URLRequest(url: url))
        try validateHTTPResponse(response, data: data)

        let object = try JSONSerialization.jsonObject(with: data)
        guard let array = object as? [Any], array.count > 1, let values = array[1] as? [Any] else {
            return []
        }

        var results: [String] = []
        var seen = Set<String>()

        for value in values {
            guard let value = value as? String else { continue }
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            if seen.insert(cleaned).inserted {
                results.append(cleaned)
            }
            if results.count >= 8 {
                break
            }
        }

        return results
    }

    func validateAuthentication() async throws {
        let payload = try await browse(browseID: "FEwhat_to_watch", authenticated: true)
        let authenticated = responseAuthenticated(payload)
        guard authenticated == true else {
            throw BackendClientError(message: "SwiftTube could read the browser cookies, but YouTube did not accept them as a signed-in session.")
        }
    }

    func streamRequestHeaders(for profile: InnerTubeClientProfile) -> [String: String] {
        let context = InnerTubeClients.context(for: profile)
        var headers: [String: String] = [
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-us,en;q=0.5",
            "Sec-Fetch-Mode": "navigate",
        ]

        if let userAgent = context.userAgent {
            headers["User-Agent"] = userAgent
        }

        if let referer = context.referer {
            headers["Referer"] = referer
        }

        return headers
    }

    func fetchText(from url: URL, authenticated: Bool = false) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        if authenticated {
            for (header, value) in try await authManager.authHeaders(origin: "https://www.youtube.com", url: url) {
                request.setValue(value, forHTTPHeaderField: header)
            }
        }

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        guard let text = String(data: data, encoding: .utf8) else {
            throw BackendClientError(message: "YouTube returned unreadable text data.")
        }

        return text
    }

    private func request(
        profile: InnerTubeClientProfile,
        endpoint: String,
        body: JSONDictionary,
        extraContext: JSONDictionary = [:],
        authenticated: Bool
    ) async throws -> JSONDictionary {
        let context = InnerTubeClients.context(for: profile)
        let visitorKey = VisitorKey(profile: profile, authenticated: authenticated)
        let requestBaseURL = authenticated ? authenticatedBaseURL(for: context) : baseURL
        let requestOrigin = authenticated ? authenticatedOrigin(for: context) : nil

        var components = URLComponents(url: requestBaseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = context.queryItems

        guard let url = components.url else {
            throw BackendClientError(message: "Failed to build the YouTube request URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        for (header, value) in context.requestHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }

        if let visitor = visitorData[visitorKey] {
            request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        if authenticated {
            for (header, value) in try await authManager.authHeaders(
                origin: requestOrigin ?? "https://www.youtube.com",
                url: url
            ) {
                request.setValue(value, forHTTPHeaderField: header)
            }
        }

        var payload = body
        var requestContext = context.requestContext
        for (key, value) in extraContext {
            requestContext[key] = value
        }
        payload["context"] = requestContext
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? JSONDictionary else {
            throw BackendClientError(message: "YouTube returned an unexpected response format.")
        }

        if let visitor = responseVisitorData(dictionary) {
            visitorData[visitorKey] = visitor
        }

        if let error = dictionary["error"] as? JSONDictionary,
           let message = error["message"] as? String, !message.isEmpty {
            throw BackendClientError(message: message)
        }

        return dictionary
    }

    private func authenticatedBaseURL(for context: InnerTubeClientContext) -> URL {
        guard let referer = context.referer,
              let refererURL = URL(string: referer) else {
            return defaultAuthenticatedBaseURL
        }

        return refererURL.appending(path: "youtubei/v1/")
    }

    private func authenticatedOrigin(for context: InnerTubeClientContext) -> String {
        guard let referer = context.referer,
              let refererURL = URL(string: referer),
              let scheme = refererURL.scheme,
              let host = refererURL.host else {
            return "https://www.youtube.com"
        }

        return "\(scheme)://\(host)"
    }
}

private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
    guard let response = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(response.statusCode) else {
        if
            let object = try? JSONSerialization.jsonObject(with: data) as? JSONDictionary,
            let error = object["error"] as? JSONDictionary,
            let message = error["message"] as? String,
            !message.isEmpty
        {
            throw BackendClientError(message: message)
        }

        throw BackendClientError(message: "YouTube request failed with status \(response.statusCode).")
    }
}

private func responseVisitorData(_ payload: JSONDictionary) -> String? {
    ((payload["responseContext"] as? JSONDictionary)?["visitorData"] as? String)
}

private func responseAuthenticated(_ payload: JSONDictionary) -> Bool? {
    if let loggedOut = responseLoggedOut(payload) {
        return !loggedOut
    }

    return responseLoggedIn(payload)
}

private func responseLoggedOut(_ payload: JSONDictionary) -> Bool? {
    guard let responseContext = payload["responseContext"] as? JSONDictionary else { return nil }
    return ((responseContext["mainAppWebResponseContext"] as? JSONDictionary)?["loggedOut"] as? Bool)
}

private func responseLoggedIn(_ payload: JSONDictionary) -> Bool? {
    guard let responseContext = payload["responseContext"] as? JSONDictionary else { return nil }
    guard let tracking = responseContext["serviceTrackingParams"] as? [Any] else { return nil }

    for item in tracking {
        guard let item = item as? JSONDictionary else { continue }
        guard (item["service"] as? String) == "GFEEDBACK" else { continue }
        guard let params = item["params"] as? [Any] else { continue }

        for param in params {
            guard let param = param as? JSONDictionary else { continue }
            if (param["key"] as? String) == "logged_in",
               let value = param["value"] as? String {
                return value == "1"
            }
        }
    }

    return nil
}
