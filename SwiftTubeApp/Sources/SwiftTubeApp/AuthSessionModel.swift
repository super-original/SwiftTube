import AppKit
import Foundation

enum BrowserLoginOption: String, CaseIterable, Identifiable {
    case safari
    case chrome
    case edge
    case firefox
    case brave
    case arc
    case zen
    case helium
    case chromium
    case vivaldi
    case opera
    case whale
    case librewolf
    case floorp

    var id: String { rawValue }

    var title: String {
        displayName
    }

    var subtitle: String {
        "Use the YouTube account already signed in there."
    }

    var displayName: String {
        switch self {
        case .safari:
            return "Safari"
        case .chrome:
            return "Chrome"
        case .edge:
            return "Microsoft Edge"
        case .firefox:
            return "Firefox"
        case .brave:
            return "Brave"
        case .arc:
            return "Arc"
        case .zen:
            return "Zen"
        case .helium:
            return "Helium"
        case .chromium:
            return "Chromium"
        case .vivaldi:
            return "Vivaldi"
        case .opera:
            return "Opera"
        case .whale:
            return "Whale"
        case .librewolf:
            return "LibreWolf"
        case .floorp:
            return "Floorp"
        }
    }

    var cookieSource: String? {
        switch self {
        case .safari:
            return "safari"
        case .chrome:
            return "chrome"
        case .edge:
            return "edge"
        case .firefox:
            return "firefox"
        case .brave:
            return "brave"
        case .arc:
            return Self.chromiumProfileSource(browser: "chrome", relativeUserDataPath: "Arc/User Data")
        case .zen:
            return Self.firefoxProfileSource(relativeProfilesPath: "zen/Profiles")
        case .helium:
            return Self.chromiumProfileSource(browser: "chrome", relativeUserDataPath: "Helium/User Data")
        case .chromium:
            return "chromium"
        case .vivaldi:
            return "vivaldi"
        case .opera:
            return "opera"
        case .whale:
            return "whale"
        case .librewolf:
            return Self.firefoxProfileSource(relativeProfilesPath: "LibreWolf/Profiles")
        case .floorp:
            return Self.firefoxProfileSource(relativeProfilesPath: "Floorp/Profiles")
        }
    }

    var appBundleIdentifiers: [String] {
        switch self {
        case .safari:
            return ["com.apple.Safari"]
        case .chrome:
            return ["com.google.Chrome"]
        case .edge:
            return ["com.microsoft.edgemac"]
        case .firefox:
            return ["org.mozilla.firefox"]
        case .brave:
            return ["com.brave.Browser"]
        case .arc:
            return ["company.thebrowser.Browser"]
        case .zen:
            return ["app.zen-browser.zen", "io.github.zen_browser.zen"]
        case .helium:
            return ["app.helium.Helium", "com.imputnet.helium"]
        case .chromium:
            return ["org.chromium.Chromium"]
        case .vivaldi:
            return ["com.vivaldi.Vivaldi"]
        case .opera:
            return ["com.operasoftware.Opera"]
        case .whale:
            return ["com.naver.Whale"]
        case .librewolf:
            return ["io.gitlab.librewolf-community"]
        case .floorp:
            return ["one.ablaze.floorp"]
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .safari:
            return "safari"
        case .firefox, .zen, .librewolf, .floorp:
            return "flame"
        default:
            return "globe"
        }
    }

    var isLikelyInstalled: Bool {
        if self == .safari { return true }
        return appBundleIdentifiers.contains { bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        }
    }

    var primaryBundleIdentifier: String? {
        installedBundleIdentifier ?? appBundleIdentifiers.first
    }

    var installedBundleIdentifier: String? {
        appBundleIdentifiers.first { bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        }
    }

    var sortRank: Int {
        Self.allCases.firstIndex(of: self) ?? 999
    }

    static var installedOptions: [BrowserLoginOption] {
        allCases.filter(\.isLikelyInstalled)
    }

    private static var applicationSupportURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    private static func chromiumProfileSource(browser: String, relativeUserDataPath: String) -> String? {
        guard let baseURL = applicationSupportURL?.appendingPathComponent(relativeUserDataPath, isDirectory: true) else {
            return nil
        }

        guard let profileURL = firstExistingProfile(
            in: baseURL,
            preferredNames: ["Default", "Profile 1", "Profile 2", "Profile 3"],
            cookieRelativePaths: ["Network/Cookies", "Cookies"]
        ) else {
            return nil
        }

        return "\(browser):\(profileURL.path)"
    }

    private static func firefoxProfileSource(relativeProfilesPath: String) -> String? {
        guard let profilesURL = applicationSupportURL?.appendingPathComponent(relativeProfilesPath, isDirectory: true),
              FileManager.default.fileExists(atPath: profilesURL.path) else {
            return nil
        }

        guard let profileURL = firstExistingProfile(
            in: profilesURL,
            preferredNames: [],
            cookieRelativePaths: ["cookies.sqlite"]
        ) else {
            return nil
        }

        return "firefox:\(profileURL.path)"
    }

    private static func firstExistingProfile(
        in baseURL: URL,
        preferredNames: [String],
        cookieRelativePaths: [String]
    ) -> URL? {
        let fileManager = FileManager.default
        let preferredURLs = preferredNames.map { baseURL.appendingPathComponent($0, isDirectory: true) }
        let discoveredURLs = (try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let sortedDiscovered = discoveredURLs
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

        for profileURL in preferredURLs + sortedDiscovered {
            guard fileManager.fileExists(atPath: profileURL.path) else { continue }
            if cookieRelativePaths.isEmpty || cookieRelativePaths.contains(where: {
                fileManager.fileExists(atPath: profileURL.appendingPathComponent($0).path)
            }) {
                return profileURL
            }
        }

        return nil
    }
}

@MainActor
final class AuthSessionModel: ObservableObject {
    @Published private(set) var status: AuthStatusResponse = .signedOut
    @Published private(set) var isWorking = false
    @Published private(set) var isDiscoveringAccounts = false
    @Published private(set) var discoveredAccounts: [BrowserAccountDiscoveryResponse] = []
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
            mergeDiscoveredAccounts([status.discoveryAccount].compactMap { $0 })
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
        await connect(browserRawValue: browser.rawValue)
    }

    func connect(using source: BrowserAccountSource) async -> Bool {
        await connect(browserRawValue: source.browser)
    }

    func discoverAccounts() async {
        guard isDiscoveringAccounts == false else { return }
        isDiscoveringAccounts = true
        errorMessage = nil
        defer { isDiscoveringAccounts = false }

        do {
            let scannedAccounts = try await BackendClient.shared.discoverBrowserAccounts()
            mergeDiscoveredAccounts([status.discoveryAccount].compactMap { $0 } + scannedAccounts)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func connect(browserRawValue: String) async -> Bool {
        isWorking = true
        defer { isWorking = false }

        do {
            status = try await BackendClient.shared.connectBrowserAuth(browser: browserRawValue)
            errorMessage = nil
            mergeDiscoveredAccounts([status.discoveryAccount].compactMap { $0 })
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
            discoveredAccounts = []
            contentRefreshID = UUID()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func mergeDiscoveredAccounts(_ accounts: [BrowserAccountDiscoveryResponse]) {
        guard accounts.isEmpty == false else { return }

        var byID = Dictionary(uniqueKeysWithValues: discoveredAccounts.map { ($0.id, $0) })
        for account in accounts {
            if let existing = byID[account.id] {
                byID[account.id] = existing.mergingSources(from: account)
            } else {
                byID[account.id] = account
            }
        }

        discoveredAccounts = byID.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}

private extension AuthStatusResponse {
    var discoveryAccount: BrowserAccountDiscoveryResponse? {
        guard authenticated else { return nil }

        let browserOption = browser.flatMap(BrowserLoginOption.init(rawValue:))
        let displayName = displayName?.authModelNilIfBlank
            ?? accountIdentifier
            ?? browserLabel
            ?? "YouTube"
        let source = BrowserAccountSource(
            browser: browser ?? "current",
            browserLabel: browserLabel ?? "YouTube",
            bundleIdentifier: browserOption?.primaryBundleIdentifier
        )

        return BrowserAccountDiscoveryResponse(
            id: (accountIdentifier ?? avatarUrl ?? displayName).lowercased(),
            displayName: displayName,
            identifier: accountIdentifier,
            avatarUrl: avatarUrl,
            sources: [source]
        )
    }
}

private extension BrowserAccountDiscoveryResponse {
    func mergingSources(from other: BrowserAccountDiscoveryResponse) -> BrowserAccountDiscoveryResponse {
        var sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        for source in other.sources {
            sourcesByID[source.id] = source
        }

        let mergedSources = sourcesByID.values.sorted {
            let lhsRank = BrowserLoginOption(rawValue: $0.browser)?.sortRank ?? 999
            let rhsRank = BrowserLoginOption(rawValue: $1.browser)?.sortRank ?? 999
            return lhsRank < rhsRank
        }

        return BrowserAccountDiscoveryResponse(
            id: id,
            displayName: displayName,
            identifier: identifier ?? other.identifier,
            avatarUrl: avatarUrl ?? other.avatarUrl,
            sources: mergedSources
        )
    }
}

private extension String {
    var authModelNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
