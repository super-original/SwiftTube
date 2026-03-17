import AppKit
import CryptoKit
import Darwin
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
    private enum Constants {
        static let host = "127.0.0.1"
        static let port = 4891
        static let startupTimeoutSeconds = 15
        static let instanceIDEnvironmentKey = "SWIFTTUBE_INSTANCE_ID"
    }

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
            lastLogLine = nil
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

            try await clearConflictingBackendIfNeeded()

            state = .starting
            statusMessage = "Starting backend..."
            let instanceID = UUID().uuidString
            try startUvicorn(
                venvURL: venvURL,
                backendURL: backendTargetURL,
                instanceID: instanceID
            )

            let healthy = await waitForHealth(
                timeoutSeconds: Constants.startupTimeoutSeconds,
                expectedInstanceID: instanceID
            )
            if healthy {
                state = .running
                statusMessage = "Backend running"
            } else {
                process?.terminate()
                state = .failed(startupFailureMessage())
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

    private func startUvicorn(venvURL: URL, backendURL: URL, instanceID: String) throws {
        let uvicornProcess = Process()
        uvicornProcess.executableURL = venvURL.appendingPathComponent("bin/python")
        uvicornProcess.arguments = [
            "-m", "uvicorn",
            "app.main:app",
            "--host", Constants.host,
            "--port", String(Constants.port),
            "--app-dir", backendURL.path
        ]
        uvicornProcess.environment = ProcessInfo.processInfo.environment.merging([
            "PYTHONUNBUFFERED": "1",
            Constants.instanceIDEnvironmentKey: instanceID,
        ]) { _, new in new }

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

    private func waitForHealth(timeoutSeconds: Int, expectedInstanceID: String) async -> Bool {
        let url = URL(string: "http://\(Constants.host):\(Constants.port)/health")!
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))

        while Date() < deadline {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    if let payload = try? JSONDecoder().decode(HealthStatus.self, from: data),
                       payload.status == "ok",
                       payload.instanceID == expectedInstanceID {
                        return true
                    }
                }
            } catch {
                // keep polling
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private func clearConflictingBackendIfNeeded() async throws {
        guard let pid = try await listeningPID(on: Constants.port) else { return }

        let command = try await commandLine(for: pid)
        guard isSwiftTubeBackend(command) else {
            throw NSError(
                domain: "SwiftTube",
                code: 8,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Backend port \(Constants.port) is already in use by another process: \(command)"
                ]
            )
        }

        _ = Darwin.kill(pid_t(pid), SIGTERM)
        if await waitForPortToClear(timeoutSeconds: 3) {
            return
        }

        _ = Darwin.kill(pid_t(pid), SIGKILL)
        if await waitForPortToClear(timeoutSeconds: 2) {
            return
        }

        throw NSError(
            domain: "SwiftTube",
            code: 9,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Couldn’t stop the previous SwiftTube backend process on port \(Constants.port)."
            ]
        )
    }

    private func listeningPID(on port: Int) async throws -> Int? {
        let output = try await captureProcessOutput(
            launchPath: "/usr/sbin/lsof",
            arguments: ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"],
            acceptableExitCodes: [0, 1]
        )

        guard let firstLine = output
            .split(whereSeparator: \.isNewline)
            .first,
            let pid = Int(firstLine.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        return pid
    }

    private func commandLine(for pid: Int) async throws -> String {
        let output = try await captureProcessOutput(
            launchPath: "/bin/ps",
            arguments: ["-p", String(pid), "-o", "command="]
        )

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitForPortToClear(timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))

        while Date() < deadline {
            if (try? await listeningPID(on: Constants.port)) == nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        return false
    }

    private func captureProcessOutput(
        launchPath: String,
        arguments: [String],
        acceptableExitCodes: Set<Int32> = [0]
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if acceptableExitCodes.contains(process.terminationStatus) {
                return output
            }

            throw NSError(
                domain: "SwiftTube",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: "Process failed: \(launchPath) \(arguments.joined(separator: " "))"
                ]
            )
        }.value
    }

    private func isSwiftTubeBackend(_ command: String) -> Bool {
        command.contains("uvicorn")
            && command.contains("app.main:app")
            && command.contains("SwiftTube")
    }

    private func startupFailureMessage() -> String {
        if let lastLogLine, lastLogLine.localizedCaseInsensitiveContains("address already in use") {
            return "Backend port \(Constants.port) is already in use. Quit the conflicting process and try again."
        }

        return "Backend failed to start. Check network access and try again."
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

private struct HealthStatus: Decodable {
    let status: String
    let instanceID: String?

    private enum CodingKeys: String, CodingKey {
        case status
        case instanceID = "instanceId"
    }
}
