import Foundation
@testable import SwiftTubeApp
import XCTest

final class DependencySelectionTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testNativeSwiftYTDLPSelectionDoesNotResolveExecutable() throws {
        let resolved = try SwiftTubeDependencyManager.resolvedYTDLPExecutable(
            source: .nativeSwift,
            customPath: nil,
            environment: [:]
        )
        XCTAssertNil(resolved)
    }

    func testSystemYTDLPDetectionUsesEnvironmentOverride() throws {
        let executable = try temporaryExecutable(named: "yt-dlp")
        let candidate = SwiftTubeDependencyManager.detectSystemYTDLP(
            environment: ["SWIFTTUBE_YT_DLP_PATH": executable.path]
        )

        XCTAssertEqual(candidate?.path, executable.path)
    }

    func testProvisionedYTDLPDetectionUsesSupportDirectory() throws {
        let support = try temporaryDirectory()
        let executable = support
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent("yt-dlp")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let candidate = SwiftTubeDependencyManager.detectProvisionedYTDLP(
            environment: ["SWIFTTUBE_APP_SUPPORT_DIR": support.path]
        )

        XCTAssertEqual(candidate?.path, executable.path)
    }

    func testCustomYTDLPPathMustBeExecutable() throws {
        let executable = try temporaryExecutable(named: "custom-yt-dlp")
        let resolved = try SwiftTubeDependencyManager.resolvedYTDLPExecutable(
            source: .custom,
            customPath: executable.path,
            environment: [:]
        )

        XCTAssertEqual(resolved?.path, executable.path)
    }

    func testSystemMPVKitDetectionUsesEnvironmentOverride() throws {
        let framework = try temporaryLibmpvFramework()
        let candidate = SwiftTubeDependencyManager.detectSystemMPVKit(
            environment: ["SWIFTTUBE_MPVKIT_PATH": framework.path]
        )

        XCTAssertEqual(candidate?.path, framework.path)
    }

    func testCustomMPVKitFrameworkResolvesAsLoadablePath() throws {
        let framework = try temporaryLibmpvFramework()
        let resolved = try SwiftTubeDependencyManager.resolvedMPVLibraryPath(
            source: .custom,
            customPath: framework.path,
            environment: [:]
        )

        XCTAssertEqual(resolved, framework.path)
        XCTAssertEqual(
            SwiftTubeDependencyManager.mpvLoadablePath(for: framework.path),
            framework.appendingPathComponent("Libmpv").path
        )
    }

    func testProvisionedMPVKitUsesBundledFallback() throws {
        let resolved = try SwiftTubeDependencyManager.resolvedMPVLibraryPath(
            source: .provisioned,
            customPath: nil,
            environment: [:]
        )

        XCTAssertNil(resolved)
    }

    func testNativeSwiftExtractorLoadsRealYouTubeWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["SWIFTTUBE_RUN_REAL_YOUTUBE_TESTS"] == "1" else {
            throw XCTSkip("Set SWIFTTUBE_RUN_REAL_YOUTUBE_TESTS=1 to hit real YouTube.")
        }

        let settings = AppSettings.shared
        let previousSource = settings.ytDLPDependencySource
        let previousCustomPath = settings.ytDLPCustomPath
        defer {
            settings.ytDLPDependencySource = previousSource
            settings.ytDLPCustomPath = previousCustomPath
        }

        settings.ytDLPDependencySource = .nativeSwift
        let nativeStart = Date()
        let nativePlayback = try await SwiftTubeBackend.shared.fetchVideo(id: "dQw4w9WgXcQ")
        let nativeElapsed = Date().timeIntervalSince(nativeStart)

        XCTAssertFalse(nativePlayback.streams.isEmpty)
        XCTAssertNotNil(nativePlayback.bestStream)
        XCTAssertFalse(nativePlayback.playbackStrategy.isEmpty)

        var timings = ["native": nativeElapsed]

        if let systemYTDLP = SwiftTubeDependencyManager.detectSystemYTDLP() {
            settings.ytDLPDependencySource = .system
            let ytdlpStart = Date()
            let ytdlpPlayback = try await SwiftTubeBackend.shared.fetchVideo(id: "dQw4w9WgXcQ")
            let ytdlpElapsed = Date().timeIntervalSince(ytdlpStart)

            XCTAssertFalse(ytdlpPlayback.streams.isEmpty)
            timings["system"] = ytdlpElapsed

            settings.ytDLPCustomPath = systemYTDLP.path
            settings.ytDLPDependencySource = .custom
            let customStart = Date()
            let customPlayback = try await SwiftTubeBackend.shared.fetchVideo(id: "dQw4w9WgXcQ")
            let customElapsed = Date().timeIntervalSince(customStart)

            XCTAssertFalse(customPlayback.streams.isEmpty)
            timings["custom"] = customElapsed

            _ = try await SwiftTubeDependencyManager.installYTDLP()
            settings.ytDLPDependencySource = .provisioned
            let provisionedStart = Date()
            let provisionedPlayback = try await SwiftTubeBackend.shared.fetchVideo(id: "dQw4w9WgXcQ")
            let provisionedElapsed = Date().timeIntervalSince(provisionedStart)

            XCTAssertFalse(provisionedPlayback.streams.isEmpty)
            timings["provisioned"] = provisionedElapsed
        } else {
            print("yt-dlp path skipped")
        }

        print("YouTube extraction timings: \(timings)")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftTubeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func temporaryExecutable(named name: String) throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func temporaryLibmpvFramework() throws -> URL {
        let framework = try temporaryDirectory().appendingPathComponent("Libmpv.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: framework.appendingPathComponent("Libmpv").path, contents: Data())
        return framework
    }
}
