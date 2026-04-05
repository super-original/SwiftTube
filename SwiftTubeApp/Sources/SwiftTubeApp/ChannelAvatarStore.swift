import Foundation

@MainActor
final class ChannelAvatarLoader: ObservableObject {
    @Published private(set) var resolvedURL: URL? = nil

    private static var cachedURLs: [String: URL?] = [:]
    private static var inFlightTasks: [String: Task<URL?, Never>] = [:]

    private var activeChannelID: String? = nil
    private var loadTask: Task<Void, Never>? = nil

    deinit {
        loadTask?.cancel()
    }

    func load(channelID: String?, fallbackURL: URL?) {
        loadTask?.cancel()
        activeChannelID = channelID
        resolvedURL = fallbackURL

        guard let channelID else { return }

        if Self.cachedURLs.keys.contains(channelID) {
            resolvedURL = Self.cachedURLs[channelID] ?? fallbackURL
            return
        }

        let requestTask: Task<URL?, Never>
        if let existingTask = Self.inFlightTasks[channelID] {
            requestTask = existingTask
        } else {
            let task = Task<URL?, Never> {
                do {
                    let response = try await BackendClient.shared.fetchChannelAvatar(channelID: channelID)
                    return response.avatarURL
                } catch {
                    return nil
                }
            }
            Self.inFlightTasks[channelID] = task
            requestTask = task
        }

        loadTask = Task { [weak self] in
            let resolvedURL = await requestTask.value
            Self.cachedURLs[channelID] = resolvedURL
            Self.inFlightTasks[channelID] = nil
            guard !Task.isCancelled else { return }
            guard self?.activeChannelID == channelID else { return }
            self?.resolvedURL = resolvedURL ?? fallbackURL
        }
    }
}
