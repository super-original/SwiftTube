import Foundation

@MainActor
final class AuthSessionModel: ObservableObject {
    @Published private(set) var status: AuthStatusResponse = .signedOut
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String? = nil
    @Published var isSheetPresented = false
    @Published private(set) var contentRefreshID = UUID()
    @Published private(set) var hasLoadedStatus = false
    private var authStatusObserver: NSObjectProtocol?

    init() {
        authStatusObserver = NotificationCenter.default.addObserver(
            forName: .authSessionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.loadStatus()
            }
        }
    }

    func loadStatus() async {
        let previousStatus = status
        do {
            status = try await BackendClient.shared.fetchAuthStatus()
            errorMessage = nil
        } catch {
            status = .signedOut
            errorMessage = error.localizedDescription
        }
        hasLoadedStatus = true

        if previousStatus != status {
            contentRefreshID = UUID()
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func connect(webCookies: [WebSessionCookie]) async -> Bool {
        guard isWorking == false else { return false }
        isWorking = true
        defer { isWorking = false }

        do {
            status = try await BackendClient.shared.connectWebAuth(cookies: webCookies)
            errorMessage = nil
            contentRefreshID = UUID()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func disconnect() async {
        isWorking = true
        defer { isWorking = false }

        do {
            status = try await BackendClient.shared.clearAuthSession()
            errorMessage = nil
            contentRefreshID = UUID()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
