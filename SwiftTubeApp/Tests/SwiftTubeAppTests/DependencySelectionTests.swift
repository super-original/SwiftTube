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
        XCTAssertEqual(selections.first?.stream.url, androidVideo.url)
        XCTAssertEqual(selections.first?.audioStream?.url, androidAudio.url)
        XCTAssertFalse(selections.contains { selection in
            selection.stream.url == iosVideo.url && selection.audioStream?.url == androidAudio.url
        })
        XCTAssertFalse(selections.contains { selection in
            selection.stream.url == androidVideo.url && selection.audioStream?.url == iosAudio.url
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

    func testAutomaticQualityPrefersAndroidSplitStreamOverVODHLSAtStartup() throws {
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

        let playback = playback(streams: [hls, video, audio])
        let startupSelections = debugAutomaticStartupMPVSelectionsForTesting(playback: playback)
        let selections = debugAutomaticSteadyStateMPVSelectionsForTesting(playback: playback)

        XCTAssertEqual(startupSelections.first?.stream.url, video.url)
        XCTAssertEqual(startupSelections.first?.audioStream?.url, audio.url)
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

    func testQualityOptionsExposeConcreteQualitiesWithoutAuto() async throws {
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
        let video = stream(
            url: "https://example.com/1080.mp4",
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
            url: "https://example.com/audio.m4a",
            formatId: "140",
            headers: ["X-YouTube-Client-Name": "3"],
            height: nil,
            audioCodec: "mp4a.40.2",
            videoCodec: nil,
            container: "m4a",
            hasAudio: true,
            hasVideo: false,
            streamKind: "audio",
            bitrate: 130_000
        )

        let testPlayback = playback(streams: [muxed, video, audio])
        let options = await MainActor.run {
            PlayerPlaybackCoordinator().debugQualityOptionsForTesting(playback: testPlayback)
        }

        XCTAssertEqual(options.map(\.title), ["1080p", "360p"])
        XCTAssertFalse(options.contains { $0.title == "Auto" })
    }

    func testQualityOptionsExposeAutoOnlyForMasterHLSManifest() async throws {
        let manifest = stream(
            url: "https://example.com/master.m3u8",
            formatId: "hls-manifest",
            headers: ["X-YouTube-Client-Name": "5"],
            height: nil,
            audioCodec: "mp4a.40.2",
            videoCodec: "avc1.640028",
            container: "m3u8",
            hasAudio: true,
            hasVideo: true,
            streamKind: "manifest",
            bitrate: nil
        )
        let variant = stream(
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
            bitrate: 2_000_000
        )
        let testPlayback = playback(streams: [variant, manifest])
        let options = await MainActor.run {
            PlayerPlaybackCoordinator().debugQualityOptionsForTesting(playback: testPlayback)
        }

        XCTAssertEqual(options.first?.id, QualityOption.adaptiveID)
        XCTAssertEqual(options.first?.title, "Auto")
        XCTAssertTrue(options.first?.isAdaptive == true)
        XCTAssertEqual(options.first?.playbackSelection.stream.url, manifest.url)
    }

    func testAdaptivePolicyDownshiftsOnLowBuffer() throws {
        var policy = AdaptiveQualityPolicy()
        let low = adaptiveRendition(id: 1, height: 360, bitrate: 800_000, selected: false)
        let mid = adaptiveRendition(id: 2, height: 720, bitrate: 2_000_000, selected: true)
        let high = adaptiveRendition(id: 3, height: 1080, bitrate: 4_500_000, selected: false)
        let telemetry = adaptiveTelemetry(
            renditions: [low, mid, high],
            selectedID: mid.id,
            rawInputRateBytesPerSecond: 250_000,
            bufferAheadSeconds: 1.5
        )

        let decision = policy.evaluate(telemetry: telemetry, viewportHeight: 1080, now: 10)

        XCTAssertEqual(decision?.rendition.id, low.id)
        XCTAssertEqual(decision?.reason, .emergencyDownshift)
    }

    func testAdaptivePolicyUpshiftsAfterStableBufferAndThroughput() throws {
        var policy = AdaptiveQualityPolicy()
        let low = adaptiveRendition(id: 1, height: 360, bitrate: 800_000, selected: true)
        let high = adaptiveRendition(id: 2, height: 720, bitrate: 2_000_000, selected: false)
        let telemetry = adaptiveTelemetry(
            renditions: [low, high],
            selectedID: low.id,
            rawInputRateBytesPerSecond: 500_000,
            bufferAheadSeconds: 20
        )

        XCTAssertNil(policy.evaluate(telemetry: telemetry, viewportHeight: 720, now: 0))
        let decision = policy.evaluate(telemetry: telemetry, viewportHeight: 720, now: 21)

        XCTAssertEqual(decision?.rendition.id, high.id)
        XCTAssertEqual(decision?.reason, .sustainedUpshift)
    }

    func testAdaptivePolicyRespectsViewportCap() throws {
        var policy = AdaptiveQualityPolicy()
        let low = adaptiveRendition(id: 1, height: 720, bitrate: 2_000_000, selected: true)
        let high = adaptiveRendition(id: 2, height: 2160, bitrate: 14_000_000, selected: false)
        let telemetry = adaptiveTelemetry(
            renditions: [low, high],
            selectedID: low.id,
            rawInputRateBytesPerSecond: 5_000_000,
            bufferAheadSeconds: 20
        )

        XCTAssertNil(policy.evaluate(telemetry: telemetry, viewportHeight: 720, now: 0))
        XCTAssertNil(policy.evaluate(telemetry: telemetry, viewportHeight: 720, now: 21))
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

        let selection = option.playbackSelection
        XCTAssertEqual(selection.stream.url, iosVideo.url)
        XCTAssertEqual(selection.audioStream?.url, iosAudio.url)
    }

    func testNativeSwiftExtractorLoadsRealYouTubeWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["SWIFTTUBE_RUN_REAL_YOUTUBE_TESTS"] == "1" else {
            throw XCTSkip("Set SWIFTTUBE_RUN_REAL_YOUTUBE_TESTS=1 to hit real YouTube.")
        }

        let videoID = ProcessInfo.processInfo.environment["SWIFTTUBE_REAL_YOUTUBE_VIDEO_ID"] ?? "dQw4w9WgXcQ"
        let nativeStart = Date()
        let nativePlayback = try await SwiftTubeBackend.shared.fetchVideo(id: videoID)
        let nativeElapsed = Date().timeIntervalSince(nativeStart)

        XCTAssertFalse(nativePlayback.streams.isEmpty)
        XCTAssertNotNil(nativePlayback.bestStream)
        XCTAssertFalse(nativePlayback.playbackStrategy.isEmpty)

        var checkedURLs = Set<String>()
        for stream in [
            nativePlayback.preferredMuxedStream,
            nativePlayback.preferredVideoStream,
            nativePlayback.preferredAudioStream,
        ].compactMap({ $0 }) where checkedURLs.insert(stream.url).inserted {
            try await assertStreamAcceptsRangeRequest(stream)
        }

        print("Native YouTube extraction: \(nativeElapsed)s, \(nativePlayback.streams.count) streams")
    }

    private func assertStreamAcceptsRangeRequest(
        _ stream: StreamInfo,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let url = try XCTUnwrap(URL(string: stream.url), file: file, line: line)
        var request = URLRequest(url: url)
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        for (header, value) in stream.httpHeaders ?? [:] {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let (_, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse, file: file, line: line)
        XCTAssertTrue(
            [200, 206].contains(httpResponse.statusCode),
            "Format \(stream.formatId ?? "unknown") returned HTTP \(httpResponse.statusCode)",
            file: file,
            line: line
        )
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
        parityComparableStreams(from: playback).compactMap(\.formatId)
    }

    private func streamDescriptors(from playback: VideoPlayback) -> [String] {
        parityComparableStreams(from: playback).map { stream in
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

    private func parityComparableStreams(from playback: VideoPlayback) -> [StreamInfo] {
        playback.streams.filter { isAdaptiveMasterManifest($0) == false }
    }

    private func isAdaptiveMasterManifest(_ stream: StreamInfo) -> Bool {
        stream.formatId == "hls-manifest"
            && stream.streamKind == "manifest"
            && stream.container?.lowercased() == "m3u8"
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
                guard option.isAdaptive == false else { return }
                result[option.title] = selectionKey(option.playbackSelection)
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

    private func adaptiveRendition(
        id: Int64,
        height: Int,
        bitrate: Int,
        selected: Bool
    ) -> AdaptiveRendition {
        AdaptiveRendition(
            id: id,
            width: nil,
            height: height,
            fps: nil,
            bitrate: bitrate,
            codec: "h264",
            selected: selected
        )
    }

    private func adaptiveTelemetry(
        renditions: [AdaptiveRendition],
        selectedID: Int64,
        rawInputRateBytesPerSecond: Int64,
        bufferAheadSeconds: Double,
        pausedForCache: Bool = false,
        underrun: Bool = false
    ) -> AdaptivePlaybackTelemetry {
        AdaptivePlaybackTelemetry(
            renditions: renditions,
            selectedRenditionID: selectedID,
            rawInputRateBytesPerSecond: rawInputRateBytesPerSecond,
            cacheDuration: bufferAheadSeconds,
            cacheEnd: nil,
            bufferAheadSeconds: bufferAheadSeconds,
            isPausedForCache: pausedForCache,
            cacheBufferingState: nil,
            isUnderrun: underrun
        )
    }
}
