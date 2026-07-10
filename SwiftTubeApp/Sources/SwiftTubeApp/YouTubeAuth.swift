import CryptoKit
import Foundation

struct WebSessionCookie: Sendable {
    let domain: String
    let path: String
    let isSecure: Bool
    let expiresAt: Date?
    let name: String
    let value: String
}

struct AuthSessionConfig: Codable, Sendable {
    let browser: String
    let browserLabel: String
    var profilePath: String?
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

    func connect(webCookies: [WebSessionCookie]) throws -> AuthStatusResponse {
        try Self.writeWebSessionCookies(webCookies, to: cookieFileURL)
        let config = AuthSessionConfig(
            browser: "swifttube",
            browserLabel: "SwiftTube Sign-In",
            profilePath: nil,
            avatarURL: nil,
            displayName: nil,
            email: nil,
            handle: nil
        )
        let material = try Self.loadMaterial(config: config, cookieFileURL: cookieFileURL)

        self.config = config
        self.material = material
        try Self.saveConfig(config, to: configURL)
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

    private static func loadConfig(at url: URL) -> AuthSessionConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AuthSessionConfig.self, from: data)
    }

    private static func saveConfig(_ config: AuthSessionConfig, to url: URL) throws {
        let data = try JSONEncoder().encode(config)
        try data.write(to: url, options: .atomic)
    }

    private static func writeWebSessionCookies(
        _ cookies: [WebSessionCookie],
        to destinationURL: URL
    ) throws {
        let relevantCookies = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            return domain.contains("youtube.com") || domain.contains("google.com")
        }
        guard relevantCookies.isEmpty == false else {
            throw BackendClientError(message: "The sign-in session did not contain any YouTube cookies.")
        }

        let lines = relevantCookies.map { cookie in
            let domain = cookie.domain.replacingOccurrences(of: "\t", with: "")
            let path = (cookie.path.isEmpty ? "/" : cookie.path).replacingOccurrences(of: "\t", with: "")
            let name = cookie.name.replacingOccurrences(of: "\t", with: "")
            let value = cookie.value
                .replacingOccurrences(of: "\t", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
            let expiration = Int(cookie.expiresAt?.timeIntervalSince1970 ?? 0)
            return [
                domain,
                domain.hasPrefix(".") ? "TRUE" : "FALSE",
                path,
                cookie.isSecure ? "TRUE" : "FALSE",
                String(expiration),
                name,
                value,
            ].joined(separator: "\t")
        }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = "# Netscape HTTP Cookie File\n" + lines.joined(separator: "\n") + "\n"
        try contents.write(to: destinationURL, atomically: true, encoding: .utf8)
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
            throw BackendClientError(message: "The Google sign-in session is missing the cookie required for authenticated YouTube requests.")
        }

        let relevantCookies = cookies.filter {
            $0.domain.contains("youtube") || $0.domain.contains("google")
        }
        guard !relevantCookies.isEmpty else {
            throw BackendClientError(message: "No usable YouTube cookies were found in the Google sign-in session.")
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
            throw BackendClientError(message: "The Google sign-in session does not include cookies that apply to YouTube.")
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
