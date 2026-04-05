import Foundation

enum PlaybackDebugLogger {
    private static let queue = DispatchQueue(label: "SwiftTube.playback-debug-log")
    private static let isEnabled = ProcessInfo.processInfo.environment["SWIFTTUBE_PLAYBACK_DEBUG_LOG"] == "1"
    private static let logURL: URL = {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("SwiftTube", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        return logsDirectory.appendingPathComponent("playback.log", isDirectory: false)
    }()

    static var path: String {
        logURL.path
    }

    static func log(
        _ message: @autoclosure () -> String,
        file: StaticString = #fileID,
        line: Int = #line
    ) {
        guard isEnabled else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let entry = "[\(timestamp)] [\(file):\(line)] \(message())\n"
        print(entry, terminator: "")

        queue.async {
            let data = Data(entry.utf8)

            if FileManager.default.fileExists(atPath: logURL.path) == false {
                FileManager.default.createFile(atPath: logURL.path, contents: data)
                return
            }

            do {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                print("[PlaybackDebugLogger] Failed to write log: \(error)")
            }
        }
    }
}
