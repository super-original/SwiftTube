import Foundation

enum YTDLPDependencySource: String, CaseIterable, Identifiable {
    case nativeSwift = "nativeSwift"
    case system = "system"
    case provisioned = "provisioned"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nativeSwift: return "Native Swift"
        case .system: return "System yt-dlp"
        case .provisioned: return "Installed yt-dlp"
        case .custom: return "Custom path"
        }
    }
}

enum MPVKitDependencySource: String, CaseIterable, Identifiable {
    case system = "system"
    case provisioned = "provisioned"
    case custom = "custom"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System libmpv"
        case .provisioned: return "Bundled MPVKit"
        case .custom: return "Custom path"
        }
    }
}

struct DependencyCandidate: Hashable, Sendable {
    let path: String
    let label: String
}

struct DependencyDetectionSnapshot: Sendable {
    let systemYTDLP: DependencyCandidate?
    let provisionedYTDLP: DependencyCandidate?
    let systemMPVKit: DependencyCandidate?
    let provisionedMPVKit: DependencyCandidate?

    static let empty = DependencyDetectionSnapshot(
        systemYTDLP: nil,
        provisionedYTDLP: nil,
        systemMPVKit: nil,
        provisionedMPVKit: nil
    )
}

enum DependencyProvisionError: LocalizedError {
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .failed(let message):
            return message
        }
    }
}

enum SwiftTubeDependencyManager {
    static let requiredMPVKitPackageURL = "https://github.com/mpvkit/MPVKit"
    static let requiredMPVKitVersion = "0.41.0"

    static func detectionSnapshot(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DependencyDetectionSnapshot {
        DependencyDetectionSnapshot(
            systemYTDLP: detectSystemYTDLP(fileManager: fileManager, environment: environment),
            provisionedYTDLP: detectProvisionedYTDLP(fileManager: fileManager, environment: environment),
            systemMPVKit: detectSystemMPVKit(fileManager: fileManager, environment: environment),
            provisionedMPVKit: DependencyCandidate(
                path: "embedded",
                label: "MPVKit \(requiredMPVKitVersion)"
            )
        )
    }

    static func resolvedYTDLPExecutable(
        source: YTDLPDependencySource,
        customPath: String?,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL? {
        switch source {
        case .nativeSwift:
            return nil
        case .custom:
            guard let customPath = customPath?.nilIfBlank else {
                throw BackendClientError(message: "Choose a yt-dlp executable.")
            }
            guard fileManager.isExecutableFile(atPath: customPath) else {
                throw BackendClientError(message: "The selected yt-dlp path is not executable.")
            }
            return URL(fileURLWithPath: customPath)
        case .system:
            if let candidate = detectSystemYTDLP(fileManager: fileManager, environment: environment) {
                return URL(fileURLWithPath: candidate.path)
            }
            throw BackendClientError(message: "No system yt-dlp executable was found.")
        case .provisioned:
            if let candidate = detectProvisionedYTDLP(fileManager: fileManager, environment: environment) {
                return URL(fileURLWithPath: candidate.path)
            }
            throw BackendClientError(message: "SwiftTube has not installed yt-dlp yet.")
        }
    }

    static func resolvedYTDLPExecutableForCookieImport(
        preferredSource: YTDLPDependencySource,
        customPath: String?,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if preferredSource != .nativeSwift,
           let selected = try? resolvedYTDLPExecutable(
                source: preferredSource,
                customPath: customPath,
                fileManager: fileManager,
                environment: environment
           ) {
            return selected
        }

        if let provisioned = detectProvisionedYTDLP(fileManager: fileManager, environment: environment) {
            return URL(fileURLWithPath: provisioned.path)
        }
        if let system = detectSystemYTDLP(fileManager: fileManager, environment: environment) {
            return URL(fileURLWithPath: system.path)
        }

        throw BackendClientError(message: "yt-dlp is required for browser sign-in, but it wasn’t found on this Mac.")
    }

    static func resolvedMPVLibraryPath(
        source: MPVKitDependencySource,
        customPath: String?,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String? {
        switch source {
        case .provisioned:
            return nil
        case .custom:
            guard let customPath = customPath?.nilIfBlank else {
                throw BackendClientError(message: "Choose a Libmpv framework or dylib.")
            }
            guard mpvLoadablePath(for: customPath, fileManager: fileManager) != nil else {
                throw BackendClientError(message: "The selected MPVKit path is not loadable.")
            }
            return customPath
        case .system:
            if let candidate = detectSystemMPVKit(fileManager: fileManager, environment: environment) {
                return candidate.path
            }
            throw BackendClientError(message: "No system Libmpv framework or dylib was found.")
        }
    }

    static func detectSystemYTDLP(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DependencyCandidate? {
        let candidates = [
            environment["SWIFTTUBE_YT_DLP_PATH"],
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp",
            which("yt-dlp")
        ].compactMap(\.self)

        return firstExecutableCandidate(candidates, label: "yt-dlp", fileManager: fileManager)
    }

    static func detectProvisionedYTDLP(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DependencyCandidate? {
        let support = swiftTubeSupportDirectory(environment: environment, fileManager: fileManager)
        let candidates = [
            support.appendingPathComponent("Tools/yt-dlp").path,
            support.appendingPathComponent("venv/bin/yt-dlp").path
        ]
        return firstExecutableCandidate(candidates, label: "yt-dlp", fileManager: fileManager)
    }

    static func detectSystemMPVKit(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DependencyCandidate? {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let candidates = [
            environment["SWIFTTUBE_MPVKIT_PATH"],
            "\(home)/Library/Frameworks/Libmpv.framework",
            "/Library/Frameworks/Libmpv.framework",
            "/opt/homebrew/Frameworks/Libmpv.framework",
            "/usr/local/Frameworks/Libmpv.framework",
            "/opt/homebrew/lib/libmpv.dylib",
            "/usr/local/lib/libmpv.dylib"
        ].compactMap(\.self)

        for candidate in candidates {
            guard mpvLoadablePath(for: candidate, fileManager: fileManager) != nil else { continue }
            return DependencyCandidate(path: candidate, label: mpvDisplayName(for: candidate))
        }
        return nil
    }

    static func provisionedYTDLPURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        swiftTubeSupportDirectory(environment: environment, fileManager: fileManager)
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent("yt-dlp")
    }

    static func installYTDLP() async throws -> URL {
        let destination = provisionedYTDLPURL()
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let downloadURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
        let (temporaryURL, response) = try await URLSession.shared.download(from: downloadURL)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw DependencyProvisionError.failed("yt-dlp download failed with status \(httpResponse.statusCode).")
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }

    static func installMPVKit() async throws -> URL? {
        nil
    }

    static func mpvLoadablePath(for path: String, fileManager: FileManager = .default) -> String? {
        let url = URL(fileURLWithPath: path)
        if fileManager.fileExists(atPath: path, isDirectory: nil), path.hasSuffix(".dylib") {
            return path
        }

        if path.hasSuffix(".framework") {
            let name = url.deletingPathExtension().lastPathComponent
            let binary = url.appendingPathComponent(name).path
            if fileManager.fileExists(atPath: binary) {
                return binary
            }
            let libmpv = url.appendingPathComponent("Libmpv").path
            if fileManager.fileExists(atPath: libmpv) {
                return libmpv
            }
        }

        if path.hasSuffix(".xcframework") {
            let framework = url
                .appendingPathComponent("macos-arm64_x86_64")
                .appendingPathComponent("Libmpv.framework")
            return mpvLoadablePath(for: framework.path, fileManager: fileManager)
        }

        return nil
    }

    private static func firstExecutableCandidate(
        _ candidates: [String],
        label: String,
        fileManager: FileManager
    ) -> DependencyCandidate? {
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return DependencyCandidate(path: candidate, label: label)
        }
        return nil
    }

    private static func which(_ name: String) -> String? {
        let output = try? ProcessRunner.runSync(
            executableURL: URL(fileURLWithPath: "/usr/bin/which"),
            arguments: [name]
        )
        guard output?.exitCode == 0 else { return nil }
        let path = output?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    private static func mpvDisplayName(for path: String) -> String {
        if path.hasSuffix(".framework") {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

func swiftTubeSupportDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
) -> URL {
    if let override = environment["SWIFTTUBE_APP_SUPPORT_DIR"], !override.isEmpty {
        let url = URL(fileURLWithPath: override, isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: ("~/Library/Application Support" as NSString).expandingTildeInPath, isDirectory: true)
    let target = baseURL.appendingPathComponent("SwiftTube", isDirectory: true)
    try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
    return target
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
