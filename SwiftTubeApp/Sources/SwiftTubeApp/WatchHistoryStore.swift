import Foundation

private struct LocalWatchProgressEntry: Codable, Sendable {
    let videoID: String
    var localElapsedSeconds: Double
    var durationSeconds: Double?
    var lastUpdatedAt: Date
    var localCompleted: Bool
}

actor WatchHistoryStore {
    private let fileURL: URL
    private var entries: [String: LocalWatchProgressEntry] = [:]
    private var hasLoaded = false

    init(fileURL: URL = watchHistorySupportDirectory().appendingPathComponent("watch-history.json")) {
        self.fileURL = fileURL
    }

    func progressEntry(for videoID: String) async -> VideoProgress? {
        await loadIfNeeded()
        return entries[videoID].map(progress(from:))
    }

    func progressEntries(for videoIDs: [String]) async -> [String: VideoProgress] {
        await loadIfNeeded()
        var result: [String: VideoProgress] = [:]
        for videoID in videoIDs {
            if let entry = entries[videoID] {
                result[videoID] = progress(from: entry)
            }
        }
        return result
    }

    func allProgressEntries() async -> [String: VideoProgress] {
        await loadIfNeeded()
        var result: [String: VideoProgress] = [:]
        for (videoID, entry) in entries {
            result[videoID] = progress(from: entry)
        }
        return result
    }

    func recordProgress(
        videoID: String,
        currentTime: Double,
        duration: Double?,
        didFinish: Bool
    ) async -> VideoProgress {
        await loadIfNeeded()

        let now = Date()
        let clampedDuration = duration.flatMap { $0 > 0 ? $0 : nil }
        let safeCurrentTime = max(currentTime, 0)
        let completed = didFinish || isEffectivelyFinished(currentTime: safeCurrentTime, duration: clampedDuration)
        let storedTime: Double
        if completed, let clampedDuration {
            storedTime = clampedDuration
        } else if let clampedDuration {
            storedTime = min(safeCurrentTime, clampedDuration)
        } else {
            storedTime = safeCurrentTime
        }

        let entry = LocalWatchProgressEntry(
            videoID: videoID,
            localElapsedSeconds: storedTime.rounded(.down),
            durationSeconds: clampedDuration,
            lastUpdatedAt: now,
            localCompleted: completed
        )

        entries[videoID] = entry
        persist()
        return progress(from: entry)
    }

    private func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([String: LocalWatchProgressEntry].self, from: data) else {
            entries = [:]
            return
        }

        entries = decoded
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private func progress(from entry: LocalWatchProgressEntry) -> VideoProgress {
        VideoProgress(
            youtubeFraction: nil,
            localElapsedSeconds: entry.localElapsedSeconds,
            durationSeconds: entry.durationSeconds,
            lastUpdatedAt: entry.lastUpdatedAt,
            localCompleted: entry.localCompleted
        )
    }
}

func parseDurationSeconds(from durationText: String?) -> Double? {
    guard let durationText else { return nil }

    let parts = durationText
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: ":")
        .compactMap { Double($0) }

    guard !parts.isEmpty else { return nil }

    var total: Double = 0
    for part in parts {
        total = (total * 60) + part
    }
    return total > 0 ? total : nil
}

func isEffectivelyFinished(currentTime: Double, duration: Double?) -> Bool {
    guard let duration, duration > 0 else { return false }
    let remaining = max(duration - currentTime, 0)
    return remaining <= 15 || currentTime / duration >= 0.98
}

private func watchHistorySupportDirectory() -> URL {
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
