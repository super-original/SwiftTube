import Foundation

enum BrowserLoginOption: String, CaseIterable, Identifiable {
    case chrome
    case safari

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chrome:
            return "Use Chrome Session"
        case .safari:
            return "Use Safari Session"
        }
    }

    var subtitle: String {
        switch self {
        case .chrome:
            return "Import the YouTube account you are already signed into in Chrome."
        case .safari:
            return "Import the YouTube account you are already signed into in Safari."
        }
    }
}

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

    func connect(using browser: BrowserLoginOption) async -> Bool {
        isWorking = true
        defer { isWorking = false }

        do {
            status = try await BackendClient.shared.connectBrowserAuth(browser: browser.rawValue)
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
