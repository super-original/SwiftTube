import AppKit
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

    private var startTask: Task<Void, Never>?

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
        guard !isRunning else { return }
        if case .starting = state { return }

        startTask?.cancel()
        startTask = Task { [weak self] in
            await self?.startService()
        }
    }

    func stop() {
        startTask?.cancel()
        state = .idle
        statusMessage = "Stopped"
        lastLogLine = nil
    }

    func retry() {
        stop()
        start()
    }

    @objc private func handleTermination() {
        stop()
    }

    private func startService() async {
        state = .starting
        statusMessage = "Starting in-process backend..."
        lastLogLine = nil

        do {
            try await SwiftTubeBackend.shared.start()
            guard !Task.isCancelled else { return }
            state = .running
            statusMessage = "Backend running in process"
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
            statusMessage = "Backend failed"
            lastLogLine = error.localizedDescription
        }
    }
}
