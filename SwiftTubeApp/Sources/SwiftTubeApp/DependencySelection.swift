import Foundation

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
    let systemMPVKit: DependencyCandidate?
    let provisionedMPVKit: DependencyCandidate?

    static let empty = DependencyDetectionSnapshot(
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
            systemMPVKit: detectSystemMPVKit(fileManager: fileManager, environment: environment),
            provisionedMPVKit: DependencyCandidate(
                path: "embedded",
                label: "MPVKit \(requiredMPVKitVersion)"
            )
        )
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
