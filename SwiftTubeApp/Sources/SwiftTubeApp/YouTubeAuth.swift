import CryptoKit
import Foundation

private enum AuthConstants {
    static let youtubeOrigin = "https://www.youtube.com"
    static let supportedBrowsers: [String: String] = [
        "chrome": "Chrome",
        "safari": "Safari",
    ]
}

struct AuthSessionConfig: Codable, Sendable {
    let browser: String
    let browserLabel: String
}

struct AuthMaterial: Sendable {
    let config: AuthSessionConfig
    let cookieFileURL: URL
    let sapisid: String
    let cookies: [NetscapeCookie]

    var browser: String { config.browser }
    var browserLabel: String { config.browserLabel }
}

actor YouTubeAuthManager {
    private let supportDirectoryURL: URL
    private let configURL: URL
    private let cookieFileURL: URL
    private var config: AuthSessionConfig?
    private var material: AuthMaterial?

    init() {
        let supportDirectoryURL = swiftTubeSupportDirectory()
        self.supportDirectoryURL = supportDirectoryURL
        self.configURL = supportDirectoryURL.appendingPathComponent("auth.json")
        self.cookieFileURL = supportDirectoryURL.appendingPathComponent("youtube-cookies.txt")
        self.config = Self.loadConfig(at: self.configURL)
        if let config = self.config {
            self.material = try? Self.loadMaterial(config: config, cookieFileURL: self.cookieFileURL)
        }
    }

    var supportDirectory: URL {
        supportDirectoryURL
    }

    func authStatus(message: String? = nil) -> AuthStatusResponse {
        guard let material else {
            return .signedOut
        }

        return AuthStatusResponse(
            authenticated: true,
            browser: material.browser,
            browserLabel: material.browserLabel,
            message: message ?? "Personalized recommendations and authenticated playback are on."
        )
    }

    func currentMaterial() -> AuthMaterial? {
        material
    }

    func connect(browser: String) async throws -> AuthStatusResponse {
        let browserKey = browser.lowercased()
        guard let browserLabel = AuthConstants.supportedBrowsers[browserKey] else {
            throw BackendClientError(message: "Unsupported browser. Choose Safari or Chrome.")
        }

        try await YTDLPTool.exportCookies(from: browserKey, to: cookieFileURL)
        let config = AuthSessionConfig(browser: browserKey, browserLabel: browserLabel)
        let material = try Self.loadMaterial(config: config, cookieFileURL: cookieFileURL)

        self.config = config
        self.material = material
        try Self.saveConfig(config, to: configURL)
        return authStatus()
    }

    func clear() throws -> AuthStatusResponse {
        material = nil
        config = nil

        if FileManager.default.fileExists(atPath: configURL.path) {
            try FileManager.default.removeItem(at: configURL)
        }

        if FileManager.default.fileExists(atPath: cookieFileURL.path) {
            try FileManager.default.removeItem(at: cookieFileURL)
        }

        return .signedOut
    }

    func authHeaders(origin: String, url: URL) throws -> [String: String] {
        guard let material else {
            throw BackendClientError(message: "Sign in to YouTube to use this action.")
        }

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let source = "\(timestamp) \(material.sapisid) \(origin)"
        let digest = Insecure.SHA1.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let cookieHeader = try cookieHeader(for: material.cookies, url: url)

        return [
            "Authorization": "SAPISIDHASH \(timestamp)_\(digest)",
            "Cookie": cookieHeader,
            "Origin": origin,
            "X-Origin": origin,
            "X-Youtube-Bootstrap-Logged-In": "true",
        ]
    }

    func playbackCookieFileURL() -> URL? {
        material?.cookieFileURL
    }

    private static func loadConfig(at url: URL) -> AuthSessionConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AuthSessionConfig.self, from: data)
    }

    private static func saveConfig(_ config: AuthSessionConfig, to url: URL) throws {
        let data = try JSONEncoder().encode(config)
        try data.write(to: url, options: .atomic)
    }

    private static func loadMaterial(config: AuthSessionConfig, cookieFileURL: URL) throws -> AuthMaterial {
        guard FileManager.default.fileExists(atPath: cookieFileURL.path) else {
            throw BackendClientError(message: "The saved YouTube cookie file is missing.")
        }

        let contents = try String(contentsOf: cookieFileURL, encoding: .utf8)
        let cookies = contents
            .split(whereSeparator: \.isNewline)
            .compactMap(parseCookieLine)

        let sapisid = cookies.first(where: { $0.name == "SAPISID" && $0.domain.contains("youtube") })?.value
            ?? cookies.first(where: { $0.name == "SAPISID" && $0.domain.contains("google") })?.value

        guard let sapisid, !sapisid.isEmpty else {
            throw BackendClientError(message: "Your browser session is missing the SAPISID cookie needed for authenticated YouTube requests.")
        }

        let relevantCookies = cookies.filter {
            $0.domain.contains("youtube") || $0.domain.contains("google")
        }
        guard !relevantCookies.isEmpty else {
            throw BackendClientError(message: "No usable YouTube cookies were found in the exported browser session.")
        }

        return AuthMaterial(
            config: config,
            cookieFileURL: cookieFileURL,
            sapisid: sapisid,
            cookies: relevantCookies
        )
    }

    private func cookieHeader(for cookies: [NetscapeCookie], url: URL) throws -> String {
        let matchedCookies = cookies
            .filter { $0.matches(url: url) }
            .map { "\($0.name)=\($0.value)" }

        guard !matchedCookies.isEmpty else {
            throw BackendClientError(message: "The imported browser session does not include any cookies that apply to YouTube.")
        }

        return matchedCookies.joined(separator: "; ")
    }
}

struct NetscapeCookie: Sendable {
    let domain: String
    let path: String
    let isSecure: Bool
    let name: String
    let value: String

    func matches(url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }

        let normalizedDomain = domain
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedDomain.isEmpty else { return false }

        let path = self.path.isEmpty ? "/" : self.path
        let requestPath = url.path.isEmpty ? "/" : url.path
        let domainMatches = host == normalizedDomain || host.hasSuffix(".\(normalizedDomain)")
        let pathMatches = requestPath.hasPrefix(path)
        let secureMatches = !isSecure || url.scheme?.lowercased() == "https"

        return domainMatches && pathMatches && secureMatches
    }
}

private func parseCookieLine(_ line: Substring) -> NetscapeCookie? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

    let components = trimmed.components(separatedBy: "\t")
    guard components.count >= 7 else { return nil }

    return NetscapeCookie(
        domain: components[0],
        path: components[2],
        isSecure: components[3].lowercased() == "true",
        name: components[5],
        value: components[6]
    )
}

enum YTDLPTool {
    static func exportCookies(from browser: String, to destinationURL: URL) async throws {
        let toolPath = try resolvePath()
        try? FileManager.default.removeItem(at: destinationURL)

        let result = try await ProcessRunner.run(
            executableURL: toolPath,
            arguments: [
                "--cookies-from-browser", browser,
                "--cookies", destinationURL.path,
                "--skip-download",
                "--simulate",
                "--quiet",
                "--no-warnings",
                "--ignore-no-formats-error",
                "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            ]
        )

        let exportedCookies = FileManager.default.fileExists(atPath: destinationURL.path)
        guard result.exitCode == 0 || exportedCookies else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BackendClientError(message: message.isEmpty ? "Failed to import browser cookies with yt-dlp." : message)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
    }

    static func resolvePath() throws -> URL {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment

        let candidateStrings = [
            environment["SWIFTTUBE_YT_DLP_PATH"],
            swiftTubeSupportDirectory().appendingPathComponent("venv/bin/yt-dlp").path,
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp",
        ].compactMap { $0 }

        for candidate in candidateStrings {
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        let whichResult = try? awaitableWhich("yt-dlp")
        if let whichResult {
            return whichResult
        }

        throw BackendClientError(message: "yt-dlp is required for browser sign-in, but it wasn’t found on this Mac.")
    }

    private static func awaitableWhich(_ name: String) throws -> URL? {
        let output = try ProcessRunner.runSync(
            executableURL: URL(fileURLWithPath: "/usr/bin/which"),
            arguments: [name]
        )
        guard output.exitCode == 0 else { return nil }
        let path = output.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}

private func swiftTubeSupportDirectory() -> URL {
    if let override = ProcessInfo.processInfo.environment["SWIFTTUBE_APP_SUPPORT_DIR"], !override.isEmpty {
        let url = URL(fileURLWithPath: override, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: ("~/Library/Application Support" as NSString).expandingTildeInPath, isDirectory: true)
    let target = baseURL.appendingPathComponent("SwiftTube", isDirectory: true)
    try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    return target
}

struct ProcessOutput: Sendable {
    let exitCode: Int32
    let output: String
}

enum ProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval? = nil,
        timeoutMessage: String? = nil
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let outputTask = Task.detached(priority: .utility) {
            pipe.fileHandleForReading.readDataToEndOfFile()
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                final class ResumeState: @unchecked Sendable {
                    let lock = NSLock()
                    var didResume = false
                }
                let state = ResumeState()

                @Sendable func finish(_ result: Result<ProcessOutput, Error>) {
                    state.lock.lock()
                    defer { state.lock.unlock() }
                    guard !state.didResume else { return }
                    state.didResume = true

                    switch result {
                    case .success(let output):
                        continuation.resume(returning: output)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                let timeoutTask = timeout.map { timeout in
                    Task.detached(priority: .utility) {
                        let duration = max(timeout, 0)
                        let nanoseconds = UInt64(duration * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: nanoseconds)
                        guard !Task.isCancelled else { return }
                        if process.isRunning {
                            process.terminate()
                        }

                        let data = await outputTask.value
                        let output = String(data: data, encoding: .utf8) ?? ""
                        let message = timeoutMessage ?? "Process timed out."
                        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        finish(.failure(BackendClientError(
                            message: trimmedOutput.isEmpty ? message : "\(message) \(trimmedOutput)"
                        )))
                    }
                }

                process.terminationHandler = { process in
                    Task {
                        timeoutTask?.cancel()
                        let data = await outputTask.value
                        let output = String(data: data, encoding: .utf8) ?? ""
                        finish(.success(ProcessOutput(exitCode: process.terminationStatus, output: output)))
                    }
                }

                do {
                    try process.run()
                } catch {
                    timeoutTask?.cancel()
                    outputTask.cancel()
                    finish(.failure(error))
                }
            }
        }, onCancel: {
            if process.isRunning {
                process.terminate()
            }
        })
    }

    static func runSync(
        executableURL: URL,
        arguments: [String]
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return ProcessOutput(exitCode: process.terminationStatus, output: output)
    }
}
