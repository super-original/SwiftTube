import AppKit
import CryptoKit
import Foundation

enum BackendState: Equatable {
    case idle
    case preparing
    case installing
    case starting
    case running
    case failed(String)
}

@MainActor
final class BackendManager: ObservableObject {
    @Published private(set) var state: BackendState = .idle
    @Published private(set) var statusMessage: String = "Idle"
    @Published private(set) var lastLogLine: String? = nil

    private var process: Process? = nil
    private var startTask: Task<Void, Never>? = nil

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTermination),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    func start() {
        if case .running = state { return }
        if case .preparing = state { return }
        if case .installing = state { return }
        if case .starting = state { return }
        startTask?.cancel()
        startTask = Task { [weak self] in
            await self?.startBackend()
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        state = .idle
        statusMessage = "Stopped"
    }

    func retry() {
        stop()
        start()
    }

    @objc private func handleTermination() {
        stop()
    }

    private func startBackend() async {
        do {
            state = .preparing
            statusMessage = "Preparing backend..."

            let backendSourceURL = try locateBackendSource()
            let appSupportURL = try ensureAppSupportDirectory()
            let backendTargetURL = appSupportURL.appendingPathComponent("backend", isDirectory: true)

            try copyBackend(from: backendSourceURL, to: backendTargetURL)

            let venvURL = appSupportURL.appendingPathComponent("venv", isDirectory: true)
            let requirementsURL = backendTargetURL.appendingPathComponent("requirements.txt")

            state = .installing
            statusMessage = "Installing Python dependencies..."
            try await ensureVenv(at: venvURL, requirementsURL: requirementsURL)

            state = .starting
            statusMessage = "Starting backend..."
            try startUvicorn(venvURL: venvURL, backendURL: backendTargetURL)

            let healthy = await waitForHealth(timeoutSeconds: 30)
            if healthy {
                state = .running
                statusMessage = "Backend running"
            } else {
                process?.terminate()
                state = .failed("Backend failed to start. Check network access and try again.")
            }
        } catch {
            process?.terminate()
            state = .failed(error.localizedDescription)
        }
    }

    private func locateBackendSource() throws -> URL {
        if let url = Bundle.module.url(forResource: "backend", withExtension: nil) {
            return url
        }
        throw NSError(domain: "SwiftTube", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bundled backend not found."])
    }

    private func ensureAppSupportDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let appSupport = base.first else {
            throw NSError(domain: "SwiftTube", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to locate Application Support directory."])
        }
        let target = appSupport.appendingPathComponent("SwiftTube", isDirectory: true)
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }
        return target
    }

    private func copyBackend(from source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func ensureVenv(at venvURL: URL, requirementsURL: URL) async throws {
        let pythonPath = venvURL.appendingPathComponent("bin/python")
        if !FileManager.default.fileExists(atPath: pythonPath.path) {
            try await runProcess(
                launchPath: "/usr/bin/python3",
                arguments: ["-m", "venv", venvURL.path]
            )
        }

        let requirementsHash = try sha256Hex(for: requirementsURL)
        let hashURL = venvURL.appendingPathComponent("requirements.sha")
        let storedHash = try? String(contentsOf: hashURL)

        if storedHash != requirementsHash {
            try await runProcess(
                launchPath: venvURL.appendingPathComponent("bin/pip").path,
                arguments: ["install", "-r", requirementsURL.path]
            )
            try requirementsHash.write(to: hashURL, atomically: true, encoding: .utf8)
        }
    }

    private func startUvicorn(venvURL: URL, backendURL: URL) throws {
        let uvicornProcess = Process()
        uvicornProcess.executableURL = venvURL.appendingPathComponent("bin/python")
        uvicornProcess.arguments = [
            "-m", "uvicorn",
            "app.main:app",
            "--host", "127.0.0.1",
            "--port", "4891",
            "--app-dir", backendURL.path
        ]
        uvicornProcess.environment = [
            "PYTHONUNBUFFERED": "1"
        ]

        let pipe = Pipe()
        uvicornProcess.standardOutput = pipe
        uvicornProcess.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.lastLogLine = text.split(separator: "\n").last.map(String.init)
            }
        }

        uvicornProcess.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                if case .running = self?.state {
                    self?.state = .failed("Backend process terminated unexpectedly.")
                }
            }
        }

        try uvicornProcess.run()
        process = uvicornProcess
    }

    private func waitForHealth(timeoutSeconds: Int) async -> Bool {
        let url = URL(string: "http://127.0.0.1:4891/health")!
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))

        while Date() < deadline {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    if let payload = String(data: data, encoding: .utf8), payload.contains("ok") {
                        return true
                    }
                    return true
                }
            } catch {
                // keep polling
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private func runProcess(launchPath: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    self?.lastLogLine = text.split(separator: "\n").last.map(String.init)
                }
            }

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "SwiftTube",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "Process failed: \(launchPath) \(arguments.joined(separator: " "))"]
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func sha256Hex(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
