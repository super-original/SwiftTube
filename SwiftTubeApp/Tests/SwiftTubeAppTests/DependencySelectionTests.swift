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

    func testExpandedBrowserLoginOptionsExposeCookieSources() throws {
        XCTAssertEqual(BrowserLoginOption.safari.cookieSource, "safari")
        XCTAssertEqual(BrowserLoginOption.chrome.cookieSource, "chrome")
        XCTAssertEqual(BrowserLoginOption.edge.cookieSource, "edge")
        XCTAssertEqual(BrowserLoginOption.firefox.cookieSource, "firefox")
        XCTAssertEqual(BrowserLoginOption.brave.cookieSource, "brave")
        XCTAssertEqual(BrowserLoginOption.chromium.cookieSource, "chromium")
        XCTAssertEqual(BrowserLoginOption.vivaldi.cookieSource, "vivaldi")
        XCTAssertEqual(BrowserLoginOption.opera.cookieSource, "opera")
        XCTAssertEqual(BrowserLoginOption.whale.cookieSource, "whale")
    }

    func testExtractorSpeedTestModesMapToDependencySources() throws {
        XCTAssertEqual(ExtractorSpeedTestMode.nativeSwift.dependencySource, .nativeSwift)
        XCTAssertEqual(ExtractorSpeedTestMode.systemYTDLP.dependencySource, .system)
        XCTAssertEqual(ExtractorSpeedTestMode.provisionedYTDLP.dependencySource, .provisioned)
    }

    func testNativeStartupPairsVideoWithCompatibleAudioHeaders() throws {
        let iosVideo = stream(
            url: "https://example.com/ios-video.mp4",
            formatId: "137",
            headers: ["X-YouTube-Client-Name": "5"],
            height: 1080,
            audioCodec: nil,
            videoCodec: "avc1.640028",
            container: "mp4",
            hasAudio: false,
            hasVideo: true,
            streamKind: "video"
        )
        let androidVideo = stream(
            url: "https://example.com/android-video.mp4",
            formatId: "137",
            headers: ["X-YouTube-Client-Name": "3"],
            height: 1080,
            audioCodec: nil,
            videoCodec: "avc1.640028",
            container: "mp4",
            hasAudio: false,
            hasVideo: true,
            streamKind: "video"
        )
        let androidAudio = stream(
            url: "https://example.com/android-audio.m4a",
            formatId: "140",
            headers: ["X-YouTube-Client-Name": "3"],
            height: nil,
            audioCodec: "mp4a.40.2",
            videoCodec: nil,
            container: "m4a",
            hasAudio: true,
            hasVideo: false,
            streamKind: "audio"
        )
        let iosAudio = stream(
            url: "https://example.com/ios-audio.m4a",
            formatId: "140",
            headers: ["X-YouTube-Client-Name": "5"],
            height: nil,
            audioCodec: "mp4a.40.2",
            videoCodec: nil,
            container: "m4a",
            hasAudio: true,
            hasVideo: false,
            streamKind: "audio"
        )
        let hls = stream(
            url: "https://example.com/manifest.m3u8",
            formatId: "96",
            headers: ["X-YouTube-Client-Name": "5"],
            height: 1080,
            audioCodec: "mp4a.40.2",
            videoCodec: "avc1.640028",
            container: "m3u8",
            hasAudio: true,
            hasVideo: true,
            streamKind: "manifest"
        )
        let playback = playback(streams: [iosVideo, androidVideo, androidAudio, iosAudio, hls])

        let selections = debugAutomaticStartupMPVSelectionsForTesting(playback: playback)

        XCTAssertFalse(selections.isEmpty)
        XCTAssertEqual(selections.first?.stream.url, iosVideo.url)
        XCTAssertEqual(selections.first?.audioStream?.url, iosAudio.url)
        XCTAssertFalse(selections.contains { selection in
            selection.stream.url == iosVideo.url && selection.audioStream?.url == androidAudio.url
        })
    }

    func testAutomaticPlaybackKeepsDirectVODStreamOverHLSManifest() throws {
        let muxed = stream(
            url: "https://example.com/360.mp4",
            formatId: "18",
            headers: ["X-YouTube-Client-Name": "3"],
            height: 360,
            audioCodec: "mp4a.40.2",
            videoCodec: "avc1.42001e",
            container: "mp4",
            hasAudio: true,
            hasVideo: true,
            streamKind: "muxed",
            bitrate: 400_000
        )
        let hls = stream(
            url: "https://example.com/1080.m3u8",
            formatId: "hls-1080",
            headers: ["X-YouTube-Client-Name": "5"],
            height: 1080,
            audioCodec: "mp4a.40.2",
            videoCodec: "avc1.640028",
            container: "m3u8",
            hasAudio: true,
            hasVideo: true,
            streamKind: "manifest",
            bitrate: 1_500_000
        )
        let playback = playback(streams: [hls, muxed])

        let startupSelections = debugAutomaticStartupMPVSelectionsForTesting(playback: playback)
        let steadySelections = debugAutomaticSteadyStateMPVSelectionsForTesting(playback: playback)

        XCTAssertEqual(startupSelections.first?.stream.url, muxed.url)
        XCTAssertEqual(steadySelections.first?.stream.url, muxed.url)
    }

    func testAutomaticSteadyQualityPrefersAndroidSplitStreamOverVODHLS() throws {
        let video = stream(
            url: "https://example.com/android-1080.mp4",
            formatId: "137",
            headers: ["X-YouTube-Client-Name": "3"],
            height: 1080,
            audioCodec: nil,
            videoCodec: "avc1.640028",
            container: "mp4",
            hasAudio: false,
            hasVideo: true,
            streamKind: "video",
            bitrate: 2_300_000
        )
        let audio = stream(
            url: "https://example.com/android-audio.m4a",
            formatId: "140",
            headers: ["X-YouTube-Client-Name": "3"],
            height: nil,
            audioCodec: "mp4a.40.2",
            videoCodec: nil,
            container: "m4a",
            hasAudio: true,
            hasVideo: false,
            streamKind: "audio",
            bitrate: 130_000,
            audioLanguage: "en-US",
            audioTrackKind: "original",
            audioLanguagePreference: 10,
            audioIsDefault: true
        )
        let hls = stream(
            url: "https://example.com/1080.m3u8",
            formatId: "hls-1080",
            headers: ["X-YouTube-Client-Name": "5"],
            height: 1080,
            audioCodec: "mp4a.40.2",
            videoCodec: "avc1.640028",
            container: "m3u8",
            hasAudio: true,
            hasVideo: true,
            streamKind: "manifest",
            bitrate: 1_500_000
        )

        let selections = debugAutomaticSteadyStateMPVSelectionsForTesting(playback: playback(streams: [hls, video, audio]))

        XCTAssertEqual(selections.first?.stream.url, video.url)
        XCTAssertEqual(selections.first?.audioStream?.url, audio.url)
    }

    func testAutomaticLivePlaybackCanUseHLSManifest() throws {
        let muxed = stream(
            url: "https://example.com/live-360.mp4",
            formatId: "18",
            headers: ["X-YouTube-Client-Name": "3"],
            height: 360,
            audioCodec: "mp4a.40.2",
            videoCodec: "avc1.42001e",
            container: "mp4",
            hasAudio: true,
            hasVideo: true,
            streamKind: "muxed",
            bitrate: 400_000
        )
        let hls = stream(
            url: "https://example.com/live-1080.m3u8",
            formatId: "hls-1080",
            headers: ["X-YouTube-Client-Name": "5"],
            height: 1080,
            audioCodec: "mp4a.40.2",
            videoCodec: "avc1.640028",
            container: "m3u8",
            hasAudio: true,
            hasVideo: true,
            streamKind: "manifest",
            bitrate: 1_500_000
        )

        let selections = debugAutomaticSteadyStateMPVSelectionsForTesting(playback: playback(streams: [muxed, hls], isLive: true))

        XCTAssertEqual(selections.first?.stream.url, hls.url)
    }


    func testManualQualityPrefersOriginalEnglishAudio() throws {
        let video = stream(
            url: "https://example.com/video.mp4",
            formatId: "137",
            headers: ["User-Agent": "test"],
            height: 1080,
            audioCodec: nil,
            videoCodec: "avc1.640028",
            container: "mp4",
            hasAudio: false,
            hasVideo: true,
            streamKind: "video"
        )
        let translatedAudio = stream(
            url: "https://example.com/translated.m4a",
            formatId: "140-it",
            headers: ["User-Agent": "test"],
            height: nil,
            audioCodec: "mp4a.40.2",
            videoCodec: nil,
            container: "m4a",
            hasAudio: true,
            hasVideo: false,
            streamKind: "audio",
            bitrate: 192_000,
            audioLanguage: "it",
            audioTrackKind: "dubbed-auto",
            audioLanguagePreference: 0,
            audioIsDefault: false
        )
        let originalAudio = stream(
            url: "https://example.com/original.m4a",
            formatId: "140-en",
            headers: ["User-Agent": "test"],
            height: nil,
            audioCodec: "mp4a.40.2",
            videoCodec: nil,
            container: "m4a",
            hasAudio: true,
            hasVideo: false,
            streamKind: "audio",
            bitrate: 128_000,
            audioLanguage: "en-US",
            audioTrackKind: "original",
            audioLanguagePreference: 10,
            audioIsDefault: true
        )
        let playback = playback(streams: [video, translatedAudio, originalAudio])

        let selectedAudio = debugManualQualityAudioStreamForTesting(playback: playback, videoStream: video)

        XCTAssertEqual(selectedAudio?.url, originalAudio.url)
    }

    @MainActor
    func testManualQualityIgnoresVODHLSWhenDirectStreamExists() throws {
        let iosVideo = stream(
            url: "https://example.com/ios-1080.mp4",
            formatId: "137",
            headers: ["X-YouTube-Client-Name": "5"],
            height: 1080,
            audioCodec: nil,
            videoCodec: "avc1.640028",
            container: "mp4",
            hasAudio: false,
            hasVideo: true,
            streamKind: "video",
            bitrate: 2_300_000
        )
        let iosAudio = stream(
            url: "https://example.com/ios-audio.m4a",
            formatId: "140",
            headers: ["X-YouTube-Client-Name": "5"],
            height: nil,
            audioCodec: "mp4a.40.2",
            videoCodec: nil,
            container: "m4a",
            hasAudio: true,
            hasVideo: false,
            streamKind: "audio",
            bitrate: 130_000,
            audioLanguage: "en-US",
            audioTrackKind: "original",
            audioLanguagePreference: 10,
            audioIsDefault: true
        )
        let hls = stream(
            url: "https://example.com/1080.m3u8",
            formatId: "hls-1080",
            headers: ["X-YouTube-Client-Name": "5"],
            height: 1080,
            audioCodec: "mp4a.40.2",
            videoCodec: "avc1.640028",
            container: "m3u8",
            hasAudio: true,
            hasVideo: true,
            streamKind: "manifest",
            bitrate: 900_000
        )
        let coordinator = PlayerPlaybackCoordinator()

        let options = coordinator.debugQualityOptionsForTesting(playback: playback(streams: [iosVideo, iosAudio, hls]))
        let option = try XCTUnwrap(options.first { $0.title == "1080p" })

        guard case .manual(let selection) = option.selection else {
            return XCTFail("Expected manual quality option")
        }
        XCTAssertEqual(selection.stream.url, iosVideo.url)
        XCTAssertEqual(selection.audioStream?.url, iosAudio.url)
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
        XCTAssertGreaterThan(nativePlayback.streams.count, 1)
        XCTAssertNotNil(nativePlayback.bestStream)
        XCTAssertFalse(nativePlayback.playbackStrategy.isEmpty)

        var timings = ["native": nativeElapsed]
        var streamCounts = ["native": nativePlayback.streams.count]

        if let systemYTDLP = SwiftTubeDependencyManager.detectSystemYTDLP() {
            settings.ytDLPDependencySource = .system
            let ytdlpStart = Date()
            let ytdlpPlayback = try await SwiftTubeBackend.shared.fetchVideo(id: "dQw4w9WgXcQ")
            let ytdlpElapsed = Date().timeIntervalSince(ytdlpStart)

            XCTAssertFalse(ytdlpPlayback.streams.isEmpty)
            XCTAssertEqual(nativePlayback.streams.count, ytdlpPlayback.streams.count)
            timings["system"] = ytdlpElapsed
            streamCounts["system"] = ytdlpPlayback.streams.count

            settings.ytDLPCustomPath = systemYTDLP.path
            settings.ytDLPDependencySource = .custom
            let customStart = Date()
            let customPlayback = try await SwiftTubeBackend.shared.fetchVideo(id: "dQw4w9WgXcQ")
            let customElapsed = Date().timeIntervalSince(customStart)

            XCTAssertFalse(customPlayback.streams.isEmpty)
            timings["custom"] = customElapsed
            streamCounts["custom"] = customPlayback.streams.count

            _ = try await SwiftTubeDependencyManager.installYTDLP()
            settings.ytDLPDependencySource = .provisioned
            let provisionedStart = Date()
            let provisionedPlayback = try await SwiftTubeBackend.shared.fetchVideo(id: "dQw4w9WgXcQ")
            let provisionedElapsed = Date().timeIntervalSince(provisionedStart)

            XCTAssertFalse(provisionedPlayback.streams.isEmpty)
            timings["provisioned"] = provisionedElapsed
            streamCounts["provisioned"] = provisionedPlayback.streams.count
        } else {
            print("yt-dlp path skipped")
        }

        print("YouTube extraction timings: \(timings)")
        print("YouTube extraction stream counts: \(streamCounts)")
    }

    func testNativeYouTubeExtractorMatchesYTDLPFormatsAndPreferencesWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["SWIFTTUBE_RUN_REAL_YOUTUBE_TESTS"] == "1" else {
            throw XCTSkip("Set SWIFTTUBE_RUN_REAL_YOUTUBE_TESTS=1 to hit real YouTube.")
        }
        guard let systemYTDLP = SwiftTubeDependencyManager.detectSystemYTDLP() else {
            throw XCTSkip("System yt-dlp is required for parity comparison.")
        }

        let explicitVideoIDs: [String]
        if let rawVideoIDs = ProcessInfo.processInfo.environment["SWIFTTUBE_PARITY_VIDEO_IDS"] {
            explicitVideoIDs = rawVideoIDs
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
        } else if let rawVideoID = ProcessInfo.processInfo.environment["SWIFTTUBE_PARITY_VIDEO_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  rawVideoID.isEmpty == false {
            explicitVideoIDs = [rawVideoID]
        } else {
            explicitVideoIDs = []
        }
        let parityVideoIDs = explicitVideoIDs.isEmpty
            ? ["3utEVmyNJuc", "dQw4w9WgXcQ", "jNQXAC9IVRw", "GpQSUjNsNm0", "LXb3EKWsInQ", "bBZF6PWEL0o", "FuuC4dpSQ1M"]
            : explicitVideoIDs
        let settings = AppSettings.shared
        let previousSource = settings.ytDLPDependencySource
        let previousCustomPath = settings.ytDLPCustomPath
        defer {
            settings.ytDLPDependencySource = previousSource
            settings.ytDLPCustomPath = previousCustomPath
        }

        for videoID in parityVideoIDs {
            settings.ytDLPDependencySource = .nativeSwift
            let nativePlayback = try await SwiftTubeBackend.shared.fetchVideo(id: videoID)

            settings.ytDLPDependencySource = .system
            let ytdlpPlayback = try await SwiftTubeBackend.shared.fetchVideo(id: videoID)

            let nativeIDs = playableFormatIDs(from: nativePlayback)
            let ytdlpIDs = playableFormatIDs(from: ytdlpPlayback)
            let rawYTDLPDescriptors = try rawYTDLPPlayableDescriptors(
                videoID: videoID,
                executablePath: systemYTDLP.path
            )
            print("\(videoID) native IDs: \(nativeIDs.joined(separator: ","))")
            print("\(videoID) yt-dlp IDs: \(ytdlpIDs.joined(separator: ","))")
            XCTAssertEqual(nativeIDs, ytdlpIDs, "Format IDs differed for \(videoID)")

            let nativeDescriptors = streamDescriptors(from: nativePlayback)
            let ytdlpDescriptors = streamDescriptors(from: ytdlpPlayback)
            print("\(videoID) native descriptors: \(nativeDescriptors)")
            print("\(videoID) yt-dlp descriptors: \(ytdlpDescriptors)")
            print("\(videoID) raw yt-dlp descriptors: \(rawYTDLPDescriptors)")
            XCTAssertEqual(nativeDescriptors, ytdlpDescriptors, "Stream metadata differed for \(videoID)")
            XCTAssertEqual(nativeDescriptors, rawYTDLPDescriptors, "Raw yt-dlp stream metadata differed for \(videoID)")

            let nativeQualities = await preferredSelectionByQuality(from: nativePlayback)
            let ytdlpQualities = await preferredSelectionByQuality(from: ytdlpPlayback)
            print("\(videoID) native qualities: \(nativeQualities)")
            print("\(videoID) yt-dlp qualities: \(ytdlpQualities)")
            XCTAssertEqual(nativeQualities, ytdlpQualities, "Quality preferences differed for \(videoID)")

            XCTAssertEqual(
                debugAutomaticStartupMPVSelectionsForTesting(playback: nativePlayback).first.map(selectionKey),
                debugAutomaticStartupMPVSelectionsForTesting(playback: ytdlpPlayback).first.map(selectionKey),
                "Automatic startup selection differed for \(videoID)"
            )
            XCTAssertEqual(
                debugAutomaticSteadyStateMPVSelectionsForTesting(playback: nativePlayback).first.map(selectionKey),
                debugAutomaticSteadyStateMPVSelectionsForTesting(playback: ytdlpPlayback).first.map(selectionKey),
                "Automatic steady-state selection differed for \(videoID)"
            )
        }
    }

    func testBrowserAccountDiscoveryWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["SWIFTTUBE_RUN_REAL_ACCOUNT_DISCOVERY_TESTS"] == "1" else {
            throw XCTSkip("Set SWIFTTUBE_RUN_REAL_ACCOUNT_DISCOVERY_TESTS=1 to inspect local browser sessions.")
        }

        let accounts = try await SwiftTubeBackend.shared.discoverBrowserAccounts()
        let summary = accounts.map { account in
            [
                "name": account.displayName,
                "identifier": account.identifier ?? "nil",
                "sources": account.sources.map(\.browserLabel).joined(separator: ","),
            ]
        }
        print("Discovered browser accounts: \(summary)")
        XCTAssertFalse(accounts.isEmpty)
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

    private func playableFormatIDs(from playback: VideoPlayback) -> [String] {
        playback.streams.compactMap(\.formatId)
    }

    private func streamDescriptors(from playback: VideoPlayback) -> [String] {
        playback.streams.map { stream in
            let formatID = stream.formatId ?? "-"
            let qualityLabel = stream.qualityLabel ?? "-"
            let width = stream.width.map(String.init) ?? "-"
            let height = stream.height.map(String.init) ?? "-"
            let fps = stream.fps.map(String.init) ?? "-"
            let container = normalizedContainer(stream.container)
            let videoCodec = normalizedCodec(stream.videoCodec)
            let audioCodec = normalizedCodec(stream.audioCodec)
            let audioLanguage = normalizedAudioLanguage(stream.audioLanguage)
            let audioTrackKind = stream.audioTrackKind ?? "-"
            let audioDefault = stream.audioIsDefault.map { $0 ? "default" : "not-default" } ?? "-"
            return [
                formatID,
                stream.streamKind,
                qualityLabel,
                width,
                height,
                fps,
                container,
                videoCodec,
                audioCodec,
                audioLanguage,
                audioTrackKind,
                audioDefault
            ].joined(separator: "|")
        }
    }

    private func rawYTDLPPlayableDescriptors(videoID: String, executablePath: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--dump-single-json",
            "--skip-download",
            "--no-warnings",
            "https://www.youtube.com/watch?v=\(videoID)"
        ]

        let directory = try temporaryDirectory()
        let outputURL = directory.appendingPathComponent("\(videoID)-yt-dlp.json")
        let errorURL = directory.appendingPathComponent("\(videoID)-yt-dlp.stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try process.run()
        process.waitUntilExit()

        try outputHandle.close()
        try errorHandle.close()
        let output = try Data(contentsOf: outputURL)
        let errorOutput = try Data(contentsOf: errorURL)
        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput, encoding: .utf8) ?? "yt-dlp exited with \(process.terminationStatus)"
            XCTFail("yt-dlp failed for \(videoID): \(message)")
            return []
        }

        guard
            let payload = try JSONSerialization.jsonObject(with: output) as? [String: Any],
            let formats = payload["formats"] as? [[String: Any]]
        else {
            XCTFail("yt-dlp returned malformed JSON for \(videoID)")
            return []
        }

        return formats.compactMap(rawYTDLPStreamDescriptor)
    }

    private func rawYTDLPStreamDescriptor(from format: [String: Any]) -> String? {
        guard let url = format["url"] as? String, url.isEmpty == false else { return nil }
        let protocolValue = format["protocol"] as? String
        guard protocolValue?.hasPrefix("http") == true || protocolValue?.hasPrefix("m3u8") == true else {
            return nil
        }

        let videoCodec = stringify(format["vcodec"])
        let audioCodec = stringify(format["acodec"])
        let hasVideo = videoCodec != nil && videoCodec != "none"
        let hasAudio = audioCodec != nil && audioCodec != "none"
        let qualityLabel = stringify(format["format_note"]) ?? intValue(format["height"]).map { "\($0)p" } ?? "-"
        let streamKind = rawStreamKind(for: url, hasAudio: hasAudio, hasVideo: hasVideo)
        let formatID = stringify(format["format_id"]) ?? "-"
        let width = intValue(format["width"]).map(String.init) ?? "-"
        let height = intValue(format["height"]).map(String.init) ?? "-"
        let fps = intValue(format["fps"]).map(String.init) ?? "-"
        let container = normalizedContainer(stringify(format["container"]) ?? stringify(format["ext"]))
        let normalizedVideoCodec = normalizedCodec(videoCodec)
        let normalizedAudioCodec = normalizedCodec(audioCodec)
        let audioLanguage = normalizedAudioLanguage(stringify(format["language"]))
        let audioTrackKind = rawAudioTrackKind(from: format, url: url) ?? "-"
        let audioDefault = rawAudioIsDefault(from: format, url: url).map { $0 ? "default" : "not-default" } ?? "-"

        return [
            formatID,
            streamKind,
            qualityLabel,
            width,
            height,
            fps,
            container,
            normalizedVideoCodec,
            normalizedAudioCodec,
            audioLanguage,
            audioTrackKind,
            audioDefault
        ].joined(separator: "|")
    }

    private func rawStreamKind(for url: String, hasAudio: Bool, hasVideo: Bool) -> String {
        if url.contains(".m3u8") || url.contains("/hls_") || url.contains("manifest/hls") {
            return "manifest"
        }
        if hasAudio && hasVideo { return "muxed" }
        if hasVideo { return "video" }
        if hasAudio { return "audio" }
        return "unknown"
    }

    private func rawAudioTrackKind(from format: [String: Any], url: String) -> String? {
        if let kind = stringify(format["language_kind"]) ?? stringify(format["audio_track_kind"]) {
            return kind
        }
        if let note = stringify(format["format_note"])?.lowercased() {
            if note.contains("original") {
                return "original"
            }
            if note.contains("dubbed") || note.contains("translated") {
                return "dubbed-auto"
            }
        }
        if url.contains(".dubbed.") { return "dubbed" }
        if url.contains(".descriptive.") { return "descriptive" }
        return nil
    }

    private func rawAudioIsDefault(from format: [String: Any], url: String) -> Bool? {
        if let value = format["is_default"] as? Bool {
            return value
        }
        if let value = format["audio_is_default"] as? Bool {
            return value
        }
        if let note = stringify(format["format_note"])?.lowercased(),
           note.contains("default") {
            return true
        }
        if url.contains(".original.") {
            return true
        }
        if url.contains(".dubbed.") || url.contains(".descriptive.") {
            return false
        }
        return nil
    }

    private func normalizedContainer(_ value: String?) -> String {
        guard let value, value.isEmpty == false else { return "-" }
        return value
            .lowercased()
            .replacingOccurrences(of: "_dash", with: "")
    }

    private func normalizedCodec(_ value: String?) -> String {
        guard let value, value.isEmpty == false, value != "none" else { return "-" }
        let lowercased = value.lowercased()
        if lowercased.hasPrefix("vp09") { return "vp9" }
        if lowercased.hasPrefix("avc1") { return lowercased }
        if lowercased.hasPrefix("av01") { return lowercased }
        if lowercased.hasPrefix("mp4a") { return lowercased }
        if lowercased.hasPrefix("opus") { return "opus" }
        return lowercased
    }

    private func stringify(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.isEmpty ? nil : string
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let double as Double:
            return Int(double)
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(Double(string) ?? .nan)
        default:
            return nil
        }
    }

    private func preferredSelectionByQuality(from playback: VideoPlayback) async -> [String: String] {
        await MainActor.run {
            func normalizedAudioLanguage(_ value: String?) -> String {
                guard let value, value.isEmpty == false else { return "-" }
                return value.lowercased().split(separator: "-").first.map(String.init) ?? value.lowercased()
            }

            func streamSelectionKey(_ stream: StreamInfo) -> String {
                [
                    stream.formatId ?? "-",
                    normalizedAudioLanguage(stream.audioLanguage),
                    stream.audioTrackKind ?? "-",
                    stream.audioIsDefault.map { $0 ? "default" : "not-default" } ?? "-"
                ].joined(separator: ":")
            }

            func selectionKey(_ selection: ManualPlaybackSelection) -> String {
                [
                    streamSelectionKey(selection.stream),
                    selection.audioStream.map(streamSelectionKey) ?? "-"
                ].joined(separator: "+")
            }

            let coordinator = PlayerPlaybackCoordinator()
            return coordinator.debugQualityOptionsForTesting(playback: playback).reduce(into: [String: String]()) { result, option in
                guard option.title != "Auto" else { return }
                switch option.selection {
                case .automatic:
                    break
                case .manual(let selection):
                    result[option.title] = selectionKey(selection)
                }
            }
        }
    }

    private func selectionKey(_ selection: ManualPlaybackSelection) -> String {
        [
            streamSelectionKey(selection.stream),
            selection.audioStream.map(streamSelectionKey) ?? "-"
        ].joined(separator: "+")
    }

    private func streamSelectionKey(_ stream: StreamInfo) -> String {
        [
            stream.formatId ?? "-",
            normalizedAudioLanguage(stream.audioLanguage),
            stream.audioTrackKind ?? "-",
            stream.audioIsDefault.map { $0 ? "default" : "not-default" } ?? "-"
        ].joined(separator: ":")
    }

    private func normalizedAudioLanguage(_ value: String?) -> String {
        guard let value, value.isEmpty == false else { return "-" }
        return value.lowercased().split(separator: "-").first.map(String.init) ?? value.lowercased()
    }

    private func stream(
        url: String,
        formatId: String,
        headers: [String: String],
        height: Int?,
        audioCodec: String?,
        videoCodec: String?,
        container: String,
        hasAudio: Bool,
        hasVideo: Bool,
        streamKind: String,
        bitrate: Int? = nil,
        audioLanguage: String? = nil,
        audioTrackKind: String? = nil,
        audioLanguagePreference: Int? = nil,
        audioIsDefault: Bool? = nil
    ) -> StreamInfo {
        StreamInfo(
            url: url,
            formatId: formatId,
            mimeType: nil,
            qualityLabel: height.map { "\($0)p" },
            httpHeaders: headers,
            bitrate: bitrate,
            width: nil,
            height: height,
            fps: nil,
            audioChannels: hasAudio ? 2 : nil,
            audioCodec: audioCodec,
            videoCodec: videoCodec,
            container: container,
            hasAudio: hasAudio,
            hasVideo: hasVideo,
            isAdaptive: hasAudio != hasVideo,
            streamKind: streamKind,
            audioLanguage: audioLanguage,
            audioTrackKind: audioTrackKind,
            audioLanguagePreference: audioLanguagePreference,
            audioIsDefault: audioIsDefault
        )
    }

    private func playback(streams: [StreamInfo], isLive: Bool = false) -> VideoPlayback {
        VideoPlayback(
            id: "test-video",
            title: "Test Video",
            channel: nil,
            channelId: nil,
            channelAvatarUrl: nil,
            subscriberCountText: nil,
            viewCountText: nil,
            publishedTimeText: nil,
            publishedDateText: nil,
            likeCountText: nil,
            durationText: nil,
            description: nil,
            commentCountText: nil,
            streams: streams,
            recommendations: [],
            comments: [],
            playbackStrategy: "native",
            preferredManifestStream: streams.first { $0.streamKind == "manifest" },
            preferredMuxedStream: nil,
            preferredVideoStream: streams.first { $0.hasVideo && !$0.hasAudio && $0.httpHeaders?["X-YouTube-Client-Name"] == "5" },
            preferredAudioStream: streams.first { $0.hasAudio && !$0.hasVideo && $0.httpHeaders?["X-YouTube-Client-Name"] == "3" },
            bestStreamUrl: streams.first?.url,
            bestStream: streams.first,
            subtitles: nil,
            storyboard: nil,
            sponsorSegments: [],
            progress: nil,
            resumeStartTimeSeconds: nil,
            subscription: nil,
            rating: nil,
            watchLater: nil,
            playlistSaveEnabled: false,
            recommendationsContinuation: nil,
            tags: [],
            accessIssue: nil,
            isLive: isLive,
            isUpcoming: false,
            liveWindowDurationSeconds: nil,
            liveChat: nil
        )
    }
}
