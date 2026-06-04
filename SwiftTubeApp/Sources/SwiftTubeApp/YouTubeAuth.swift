import CryptoKit
import Foundation

private enum AuthConstants {
    static let youtubeOrigin = "https://www.youtube.com"
    static let supportedBrowsers = Dictionary(
        uniqueKeysWithValues: BrowserLoginOption.allCases.map { ($0.rawValue, $0.displayName) }
    )
}

struct AuthSessionConfig: Codable, Sendable {
    let browser: String
    let browserLabel: String
    var avatarURL: String?
    var displayName: String?
    var email: String?
    var handle: String?
}

struct AuthMaterial: Sendable {
    let config: AuthSessionConfig
    let cookieFileURL: URL
    let sapisid: String
    let cookies: [NetscapeCookie]

    var browser: String { config.browser }
    var browserLabel: String { config.browserLabel }
}

struct AuthSessionSnapshot: Sendable {
    let config: AuthSessionConfig?
    let material: AuthMaterial?
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
            return signedOutStatus(message: message)
        }

        return AuthStatusResponse(
            authenticated: true,
            browser: material.browser,
            browserLabel: material.browserLabel,
            message: message ?? "Personalized recommendations and authenticated playback are on.",
            avatarUrl: config?.avatarURL,
            displayName: config?.displayName,
            email: config?.email,
            handle: config?.handle
        )
    }

    func signedOutStatus(message: String? = nil) -> AuthStatusResponse {
        AuthStatusResponse(
            authenticated: false,
            browser: config?.browser,
            browserLabel: config?.browserLabel,
            message: message,
            avatarUrl: nil,
            displayName: nil,
            email: nil,
            handle: nil
        )
    }

    func currentMaterial() -> AuthMaterial? {
        material
    }

    func needsAccountIdentifierRefresh() -> Bool {
        guard material != nil else { return false }
        return config?.email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            && config?.handle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    func connect(browser: String) async throws -> AuthStatusResponse {
        let browserKey = browser.lowercased()
        guard let browserOption = BrowserLoginOption(rawValue: browserKey),
              let cookieSource = browserOption.cookieSource else {
            throw BackendClientError(message: "Unsupported browser or browser profile.")
        }
        let browserLabel = browserOption.displayName

        try await YTDLPTool.exportCookies(from: cookieSource, to: cookieFileURL, timeout: 30)
        let config = AuthSessionConfig(
            browser: browserKey,
            browserLabel: browserLabel,
            avatarURL: self.config?.avatarURL,
            displayName: self.config?.displayName,
            email: self.config?.email,
            handle: self.config?.handle
        )
        let material = try Self.loadMaterial(config: config, cookieFileURL: cookieFileURL)

        self.config = config
        self.material = material
        try Self.saveConfig(config, to: configURL)
        return authStatus()
    }

    func refreshLastUsedBrowserSession() async throws -> AuthStatusResponse {
        guard let config else {
            return signedOutStatus()
        }
        guard let browserOption = BrowserLoginOption(rawValue: config.browser),
              let cookieSource = browserOption.cookieSource else {
            return signedOutStatus(message: "The saved browser profile is no longer available.")
        }

        try await YTDLPTool.exportCookies(from: cookieSource, to: cookieFileURL, timeout: 30)
        let material = try Self.loadMaterial(config: config, cookieFileURL: cookieFileURL)
        self.material = material
        return authStatus()
    }

    func updateAvatarURL(_ avatarURL: String?) throws {
        guard var config else { return }
        guard config.avatarURL != avatarURL else { return }
        config.avatarURL = avatarURL
        self.config = config
        try Self.saveConfig(config, to: configURL)
    }

    func updateAccountProfile(displayName: String?, email: String?, handle: String?, avatarURL: String?) throws {
        guard var config else { return }
        guard config.displayName != displayName || config.email != email || config.handle != handle || config.avatarURL != avatarURL else { return }
        config.displayName = displayName
        config.email = email
        config.handle = handle
        config.avatarURL = avatarURL
        self.config = config
        try Self.saveConfig(config, to: configURL)
    }

    func clear(preserveBrowserChoice: Bool = true) throws -> AuthStatusResponse {
        material = nil

        if preserveBrowserChoice {
            try? updateAvatarURL(nil)
        } else {
            config = nil
        }

        if !preserveBrowserChoice,
           FileManager.default.fileExists(atPath: configURL.path) {
            try FileManager.default.removeItem(at: configURL)
        }

        if FileManager.default.fileExists(atPath: cookieFileURL.path) {
            try FileManager.default.removeItem(at: cookieFileURL)
        }

        return signedOutStatus()
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

    func probeMaterial(for browser: BrowserLoginOption, timeout: TimeInterval = 8) async throws -> AuthMaterial {
        guard let cookieSource = browser.cookieSource else {
            throw BackendClientError(message: "\(browser.displayName) does not expose a readable profile.")
        }

        let probesDirectory = supportDirectoryURL.appendingPathComponent("CookieProbes", isDirectory: true)
        try FileManager.default.createDirectory(at: probesDirectory, withIntermediateDirectories: true)
        let probeCookieURL = probesDirectory.appendingPathComponent("\(browser.rawValue)-\(UUID().uuidString).txt")
        try await YTDLPTool.exportCookies(from: cookieSource, to: probeCookieURL, timeout: timeout)

        let config = AuthSessionConfig(
            browser: browser.rawValue,
            browserLabel: browser.displayName,
            avatarURL: nil,
            displayName: nil,
            email: nil,
            handle: nil
        )
        return try Self.loadMaterial(config: config, cookieFileURL: probeCookieURL)
    }

    func activateProbeMaterial(_ material: AuthMaterial) -> AuthSessionSnapshot {
        let snapshot = AuthSessionSnapshot(config: config, material: self.material)
        config = material.config
        self.material = material
        return snapshot
    }

    func restoreProbeMaterial(_ snapshot: AuthSessionSnapshot) {
        config = snapshot.config
        material = snapshot.material
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

        let authCookieNames = ["SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID", "APISID"]
        let sapisid = authCookieNames.lazy.compactMap { name in
            cookies.first(where: { $0.name == name && $0.domain.contains("youtube") })?.value
                ?? cookies.first(where: { $0.name == name && $0.domain.contains("google") })?.value
        }.first

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
    static func exportCookies(from browser: String, to destinationURL: URL, timeout: TimeInterval? = nil) async throws {
        let settings = AppSettings.shared
        let toolPath = try SwiftTubeDependencyManager.resolvedYTDLPExecutableForCookieImport(
            preferredSource: settings.ytDLPDependencySource,
            customPath: settings.ytDLPCustomPath
        )
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
            ],
            timeout: timeout,
            timeoutMessage: "\(browser) cookie import timed out."
        )

        let exportedCookies = FileManager.default.fileExists(atPath: destinationURL.path)
        guard result.exitCode == 0 || exportedCookies else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BackendClientError(message: message.isEmpty ? "Failed to import browser cookies with yt-dlp." : message)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
    }

    static func resolvePath() throws -> URL {
        let settings = AppSettings.shared
        guard let url = try SwiftTubeDependencyManager.resolvedYTDLPExecutable(
            source: settings.ytDLPDependencySource,
            customPath: settings.ytDLPCustomPath
        ) else {
            throw BackendClientError(message: "Native Swift extraction does not use yt-dlp.")
        }
        return url
    }

    static func resolveFallbackExecutablePath() throws -> URL {
        let settings = AppSettings.shared
        return try SwiftTubeDependencyManager.resolvedYTDLPExecutableForCookieImport(
            preferredSource: settings.ytDLPDependencySource,
            customPath: settings.ytDLPCustomPath
        )
    }
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
        process.environment = executableEnvironment()

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
        process.environment = executableEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return ProcessOutput(exitCode: process.terminationStatus, output: output)
    }

    private static func executableEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let fallbackPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existingPaths = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        var mergedPaths = existingPaths
        for path in fallbackPaths where mergedPaths.contains(path) == false {
            mergedPaths.append(path)
        }
        environment["PATH"] = mergedPaths.joined(separator: ":")
        return environment
    }
}
