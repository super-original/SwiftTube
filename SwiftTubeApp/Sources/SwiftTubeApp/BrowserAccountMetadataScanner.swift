import Foundation

/// Reads browser-owned profile metadata only. It never opens cookie databases or
/// Keychain items, so account discovery stays quick and cannot trigger a Safe
/// Storage password prompt.
enum BrowserAccountMetadataScanner {
    static func discoverAccounts(in browsers: [BrowserLoginOption]) -> [BrowserAccountDiscoveryResponse] {
        let discovered = browsers.flatMap(discoverAccounts(in:))
        var grouped: [String: BrowserAccountDiscoveryResponse] = [:]

        for account in discovered {
            if let existing = grouped[account.id] {
                let sources = Array(Set(existing.sources + account.sources)).sorted(by: sourceSort)
                grouped[account.id] = BrowserAccountDiscoveryResponse(
                    id: existing.id,
                    displayName: preferredName(existing.displayName, account.displayName),
                    identifier: existing.identifier ?? account.identifier,
                    avatarUrl: existing.avatarUrl ?? account.avatarUrl,
                    sources: sources
                )
            } else {
                grouped[account.id] = account
            }
        }

        return grouped.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private static func discoverAccounts(in browser: BrowserLoginOption) -> [BrowserAccountDiscoveryResponse] {
        switch browser {
        case .safari:
            return [genericAccount(browser: browser, profilePath: nil, profileName: nil)]
        case .firefox, .zen, .librewolf, .floorp:
            return firefoxAccounts(browser: browser)
        default:
            return chromiumAccounts(browser: browser)
        }
    }

    private static func chromiumAccounts(browser: BrowserLoginOption) -> [BrowserAccountDiscoveryResponse] {
        guard let root = chromiumRoot(for: browser) else {
            return [genericAccount(browser: browser, profilePath: profilePath(from: browser.cookieSource), profileName: nil)]
        }

        let stateURL = root.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = object["profile"] as? [String: Any],
              let infoCache = profile["info_cache"] as? [String: [String: Any]] else {
            return [genericAccount(browser: browser, profilePath: profilePath(from: browser.cookieSource), profileName: nil)]
        }

        return infoCache.compactMap { profileName, metadata in
            let profileURL = root.appendingPathComponent(profileName, isDirectory: true)
            guard hasCookieStore(in: profileURL) else { return nil }

            let accounts = metadata["account_info"] as? [[String: Any]] ?? []
            let primary = accounts.first
            let email = nonEmpty(primary?["email"] as? String)
                ?? nonEmpty(metadata["user_name"] as? String)
            let fullName = nonEmpty(primary?["full_name"] as? String)
                ?? nonEmpty(metadata["gaia_name"] as? String)
                ?? nonEmpty(metadata["name"] as? String)
            let avatarURL = nonEmpty(primary?["picture_url"] as? String)
            let source = BrowserAccountSource(
                browser: browser.rawValue,
                browserLabel: browser.displayName,
                bundleIdentifier: browser.primaryBundleIdentifier,
                profilePath: profileURL.path
            )
            let displayName = fullName ?? email ?? "\(browser.displayName) — \(profileName)"
            let key = (email ?? "\(browser.rawValue)|\(profileURL.path)").lowercased()
            return BrowserAccountDiscoveryResponse(
                id: key,
                displayName: displayName,
                identifier: email,
                avatarUrl: avatarURL,
                sources: [source]
            )
        }
    }

    private static func firefoxAccounts(browser: BrowserLoginOption) -> [BrowserAccountDiscoveryResponse] {
        guard let profilesRoot = firefoxProfilesRoot(for: browser),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: profilesRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return [genericAccount(browser: browser, profilePath: profilePath(from: browser.cookieSource), profileName: nil)]
        }

        let profiles = entries.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && FileManager.default.fileExists(atPath: url.appendingPathComponent("cookies.sqlite").path)
        }
        guard profiles.isEmpty == false else {
            return [genericAccount(browser: browser, profilePath: profilePath(from: browser.cookieSource), profileName: nil)]
        }

        return profiles.map { profile in
            genericAccount(browser: browser, profilePath: profile.path, profileName: cleanedProfileName(profile.lastPathComponent))
        }
    }

    private static func genericAccount(
        browser: BrowserLoginOption,
        profilePath: String?,
        profileName: String?
    ) -> BrowserAccountDiscoveryResponse {
        let source = BrowserAccountSource(
            browser: browser.rawValue,
            browserLabel: browser.displayName,
            bundleIdentifier: browser.primaryBundleIdentifier,
            profilePath: profilePath
        )
        let displayName = profileName.map { "\(browser.displayName) — \($0)" } ?? browser.displayName
        return BrowserAccountDiscoveryResponse(
            id: "\(browser.rawValue)|\(profilePath ?? "default")".lowercased(),
            displayName: displayName,
            identifier: nil,
            avatarUrl: nil,
            sources: [source]
        )
    }

    private static func chromiumRoot(for browser: BrowserLoginOption) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let relativePath: String
        switch browser {
        case .chrome: relativePath = "Google/Chrome"
        case .edge: relativePath = "Microsoft Edge"
        case .brave: relativePath = "BraveSoftware/Brave-Browser"
        case .arc: relativePath = "Arc/User Data"
        case .helium: relativePath = "Helium/User Data"
        case .chromium: relativePath = "Chromium"
        case .vivaldi: relativePath = "Vivaldi"
        case .opera: relativePath = "com.operasoftware.Opera"
        case .whale: relativePath = "Naver/Whale"
        default: return nil
        }
        return base.appendingPathComponent(relativePath, isDirectory: true)
    }

    private static func firefoxProfilesRoot(for browser: BrowserLoginOption) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let relativePath: String
        switch browser {
        case .firefox: relativePath = "Firefox/Profiles"
        case .zen: relativePath = "zen/Profiles"
        case .librewolf: relativePath = "LibreWolf/Profiles"
        case .floorp: relativePath = "Floorp/Profiles"
        default: return nil
        }
        return base.appendingPathComponent(relativePath, isDirectory: true)
    }

    private static func hasCookieStore(in profile: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: profile.appendingPathComponent("Network/Cookies").path)
            || fileManager.fileExists(atPath: profile.appendingPathComponent("Cookies").path)
    }

    private static func profilePath(from cookieSource: String?) -> String? {
        guard let cookieSource, let separator = cookieSource.firstIndex(of: ":") else { return nil }
        let value = String(cookieSource[cookieSource.index(after: separator)...])
        return value.hasPrefix("/") ? value : nil
    }

    private static func cleanedProfileName(_ name: String) -> String {
        let suffix = name.split(separator: ".", maxSplits: 1).last.map(String.init) ?? name
        return suffix.replacingOccurrences(of: "-release", with: "").replacingOccurrences(of: "_", with: " ")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func preferredName(_ lhs: String, _ rhs: String) -> String {
        lhs.count >= rhs.count ? lhs : rhs
    }

    private static func sourceSort(_ lhs: BrowserAccountSource, _ rhs: BrowserAccountSource) -> Bool {
        let left = BrowserLoginOption(rawValue: lhs.browser)?.sortRank ?? 999
        let right = BrowserLoginOption(rawValue: rhs.browser)?.sortRank ?? 999
        return left == right ? lhs.id < rhs.id : left < right
    }
}
