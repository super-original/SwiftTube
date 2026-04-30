import AppKit
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance
    case sidebar
    case notifications
    case advanced
    case playback
    case controls
    case sponsorBlock
    case changelog

    var id: String { rawValue }

    static var appSection: [SettingsPane] {
        [.appearance, .sidebar, .notifications, .advanced]
    }

    static var playbackSection: [SettingsPane] {
        [.playback, .controls, .sponsorBlock]
    }

    static var aboutSection: [SettingsPane] {
        [.changelog]
    }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .sidebar: return "Sidebar"
        case .notifications: return "Notifications"
        case .advanced: return "Advanced"
        case .playback: return "Playback"
        case .controls: return "Controls"
        case .sponsorBlock: return "SponsorBlock"
        case .changelog: return "Changelog"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "circle.lefthalf.filled"
        case .sidebar: return "sidebar.left"
        case .notifications: return "bell.badge"
        case .advanced: return "wrench.and.screwdriver"
        case .playback: return "play.circle"
        case .controls: return "keyboard"
        case .sponsorBlock: return "scissors"
        case .changelog: return "text.document"
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selection: SettingsPane = .appearance
    @Namespace private var settingsScrollTop

    var body: some View {
        NavigationSplitView {
            settingsSidebar
        } detail: {
            settingsDetail
        }
        .frame(
            minWidth: SettingsWindowSupport.minSize.width,
            idealWidth: 980,
            maxWidth: SettingsWindowSupport.maxSize.width,
            minHeight: SettingsWindowSupport.minSize.height,
            idealHeight: 650,
            maxHeight: SettingsWindowSupport.maxSize.height
        )
        .background(settings.windowBackgroundColor.ignoresSafeArea())
        .preferredColorScheme(settings.preferredColorScheme)
        .background(
            WindowAccessor { window in
                guard let window else { return }
                SettingsWindowSupport.configure(window)
            }
        )
    }

    private var settingsSidebar: some View {
        List(selection: Binding(
            get: { Optional(selection) },
            set: {
                if let pane = $0 {
                    selection = pane
                }
            }
        )) {
            Section {
                ForEach(SettingsPane.appSection) { pane in
                    Label(pane.title, systemImage: pane.systemImage)
                        .tag(pane)
                }
            } header: {
                Text("SwiftTube")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
            }
            .collapsible(false)

            Section("Player") {
                ForEach(SettingsPane.playbackSection) { pane in
                    Label(pane.title, systemImage: pane.systemImage)
                        .tag(pane)
                }
            }
            .collapsible(false)

            Section("About") {
                ForEach(SettingsPane.aboutSection) { pane in
                    Label(pane.title, systemImage: pane.systemImage)
                        .tag(pane)
                }
            }
            .collapsible(false)
        }
        .listStyle(.sidebar)
        .scrollDisabled(true)
        .removeSidebarToggle()
        .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 220)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var settingsDetail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Color.clear
                        .frame(height: 0)
                        .id(settingsScrollTop)

                    switch selection {
                    case .appearance:
                        AppearancePane()
                    case .sidebar:
                        SidebarPane()
                    case .notifications:
                        NotificationsPane()
                    case .advanced:
                        AdvancedPane()
                    case .playback:
                        PlaybackPane()
                    case .controls:
                        ControlsPane()
                    case .sponsorBlock:
                        SponsorBlockPane()
                    case .changelog:
                        ChangelogPane()
                    }
                }
                .padding(28)
            }
            .onChange(of: selection) { _, _ in
                proxy.scrollTo(settingsScrollTop, anchor: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(settings.windowBackgroundColor)
    }
}

private struct AppearancePane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "Appearance",
                subtitle: "Theme and browse layout."
            )

            SettingsCard(title: "Default Themes", icon: "circle.lefthalf.filled") {
                ThemeGroup(themes: AppAppearanceMode.defaultThemes)
            }

            SettingsCard(title: "Colored Themes", icon: "paintpalette") {
                ThemeGroup(themes: AppAppearanceMode.coloredThemes)
            }

            SettingsCard(title: "Video Grid", icon: "rectangle.grid.2x2") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center) {
                        Text("Recommendations and search size")
                            .font(.headline)
                        Spacer()
                        Text("\(settings.browseVideoGridPreset.title) · \(settings.browseVideoGridPreset.columnHint)")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Picker("Grid size", selection: $settings.browseVideoGridPreset) {
                        ForEach(BrowseVideoGridPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }
}

private struct ThemeGroup: View {
    @ObservedObject private var settings = AppSettings.shared
    let themes: [AppAppearanceMode]
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(themes) { theme in
                ThemeSwatch(
                    theme: theme,
                    isSelected: settings.appearanceMode == theme
                ) {
                    settings.appearanceMode = theme
                }
            }
        }
    }
}

private struct ThemeSwatch: View {
    @ObservedObject private var settings = AppSettings.shared
    let theme: AppAppearanceMode
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(theme.previewGradient)
                        .frame(height: 82)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(borderColor, lineWidth: isSelected ? 2.5 : 1)
                        )

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Color.accentColor, .white)
                            .background(Circle().fill(Color.white))
                            .offset(x: 7, y: -7)
                    }
                }

                Text(theme.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(backgroundColor)
            )
            .scaleEffect(isHovered ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }

    private var borderColor: Color {
        if isSelected { return Color.accentColor }
        return Color.primary.opacity(isHovered ? 0.45 : 0.18)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(settings.preferredColorScheme == .dark ? 0.15 : 0.08)
        }
        return isHovered ? settings.hoverCardBackgroundColor : .clear
    }
}

private struct SidebarPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "Sidebar",
                subtitle: "Navigation order and visibility."
            )

            SettingsCard(title: "Navigation Items", icon: "sidebar.left") {
                List {
                    ForEach(settings.sidebarItemOrder) { item in
                        SidebarSettingsListRow(
                            item: item,
                            isVisible: settings.isSidebarItemVisible(item)
                        ) { visible in
                            settings.setSidebarItem(item, visible: visible)
                        }
                        .listRowBackground(Color.clear)
                        .moveDisabled(item == .home)
                    }
                    .onMove { source, destination in
                        settings.moveSidebarItems(from: source, to: destination)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(height: CGFloat(settings.sidebarItemOrder.count) * 44 + 18)
            }
        }
    }
}

private struct SidebarSettingsListRow: View {
    let item: SidebarItemKind
    let isVisible: Bool
    let onVisibilityChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

            Button {
                onVisibilityChanged(!isVisible)
            } label: {
                Image(systemName: checkboxSymbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(item == .home ? .secondary : (isVisible ? Color.accentColor : .secondary))
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .disabled(item == .home)

            Label(item.title, systemImage: item.systemImage)
                .foregroundStyle(item == .home ? .primary : (isVisible ? .primary : .secondary))

            Spacer()

            if item == .home {
                Text("Required")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var checkboxSymbol: String {
        if item == .home {
            return "checkmark.square.fill"
        }
        return isVisible ? "checkmark.square.fill" : "square"
    }
}

private struct NotificationsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "Notifications",
                subtitle: "Toast display and placement."
            )

            SettingsCard(title: "Behavior", icon: "bell.badge") {
                NativePickerRow(
                    title: "Show notifications"
                ) {
                    Picker("Show notifications", selection: $settings.notificationDisplayMode) {
                        ForEach(NotificationDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                }

                SettingsDivider()

                NativePickerRow(
                    title: "Stack position"
                ) {
                    Picker("Stack position", selection: $settings.notificationPlacement) {
                        ForEach(NotificationPlacement.allCases) { placement in
                            Text(placement.title).tag(placement)
                        }
                    }
                    .labelsHidden()
                }

                SettingsDivider()

                NativePickerRow(
                    title: "Hide after"
                ) {
                    Picker("Hide after", selection: $settings.notificationAutoHideDelay) {
                        ForEach(AppSettings.notificationAutoHideDelayOptions, id: \.self) { seconds in
                            Text("\(Int(seconds))s").tag(seconds)
                        }
                    }
                    .labelsHidden()
                }
            }
        }
    }
}

private struct AdvancedPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var mutationCenter = AppMutationCenter.shared
    @State private var customTitle = "Custom notification"
    @State private var customMessage = "This is how your custom toast will look."
    @State private var customSymbol = "wand.and.stars"
    @State private var customColor = Color(red: 0.49, green: 0.75, blue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "Advanced",
                subtitle: "Testing and reset options."
            )

            SettingsCard(title: "Onboarding", icon: "sparkles.tv") {
                HStack {
                    Text("First-time setup")
                        .font(.headline)
                    Spacer()
                    Button("Restart Onboarding") {
                        settings.onboardingCompleted = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            SettingsCard(title: "Notification Tester", icon: "sparkles") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick presets")
                        .font(.headline)

                    HStack(spacing: 10) {
                        ForEach(NotificationPreviewPreset.allCases) { preset in
                            Button(preset.title) {
                                mutationCenter.showPreview(preset.notice)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Rectangle()
                        .fill(settings.separatorColor)
                        .frame(height: 1)

                    Text("Custom test notification")
                        .font(.headline)

                    TextField("Title", text: $customTitle)
                        .textFieldStyle(.roundedBorder)

                    TextField("Message", text: $customMessage)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 12) {
                        TextField("SF Symbol", text: $customSymbol)
                            .textFieldStyle(.roundedBorder)

                        ColorPicker("Color", selection: $customColor, supportsOpacity: false)
                            .labelsHidden()
                    }

                    Button("Show Custom Notification") {
                        mutationCenter.showPreview(
                            MutationNotice(
                                title: customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom notification" : customTitle,
                                message: customMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : customMessage,
                                symbol: customSymbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "wand.and.stars" : customSymbol,
                                accent: .blue,
                                customColor: customColor.notificationColorValue
                            )
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

private enum NotificationPreviewPreset: String, CaseIterable, Identifiable {
    case like
    case watchLater
    case error
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .like:
            return "Liked"
        case .watchLater:
            return "Watch Later"
        case .error:
            return "Error"
        case .history:
            return "History"
        }
    }

    var notice: MutationNotice {
        switch self {
        case .like:
            return MutationNotice(
                title: "Liked video",
                message: nil,
                symbol: "hand.thumbsup.fill",
                accent: .green
            )
        case .watchLater:
            return MutationNotice(
                title: "Added to Watch Later",
                message: nil,
                symbol: "clock.fill",
                accent: .green
            )
        case .error:
            return MutationNotice(
                title: "Couldn’t save to playlist",
                message: "YouTube rejected the request.",
                symbol: "text.badge.xmark",
                accent: .red
            )
        case .history:
            return MutationNotice(
                title: "Removed from history",
                message: nil,
                symbol: "trash",
                accent: .green
            )
        }
    }
}

private struct PlaybackPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "Playback",
                subtitle: "Default playback quality and speed."
            )

            SettingsCard(title: "Defaults", icon: "play.circle") {
                NativePickerRow(
                    title: "Default quality"
                ) {
                    Picker("Default quality", selection: $settings.defaultQuality) {
                        ForEach(AppSettings.DefaultQuality.allCases) { quality in
                            Text(quality.rawValue).tag(quality)
                        }
                    }
                    .labelsHidden()
                }

                divider

                NativePickerRow(
                    title: "Default playback speed"
                ) {
                    Picker("Default playback speed", selection: $settings.defaultPlaybackSpeed) {
                        ForEach(AppSettings.playbackSpeedOptions, id: \.self) { speed in
                            Text(AppSettings.playbackSpeedLabel(speed)).tag(speed)
                        }
                    }
                    .labelsHidden()
                }

                divider

                NativePickerRow(
                    title: "Spacebar hold speed"
                ) {
                    Picker("Spacebar hold speed", selection: $settings.spacebarHoldPlaybackSpeed) {
                        ForEach(AppSettings.spacebarHoldPlaybackSpeedOptions, id: \.self) { speed in
                            Text(AppSettings.playbackSpeedLabel(speed)).tag(speed)
                        }
                    }
                    .labelsHidden()
                }

            }

            SettingsCard(title: "Player Controls", icon: "slider.horizontal.below.rectangle") {
                NativePickerRow(
                    title: "Control layout"
                ) {
                    Picker("Control layout", selection: $settings.playerControlLayout) {
                        ForEach(PlayerControlLayout.allCases) { layout in
                            Text(layout.title).tag(layout)
                        }
                    }
                    .labelsHidden()
                }
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(settings.separatorColor)
            .frame(height: 1)
    }
}

private struct SponsorBlockPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "SponsorBlock",
                subtitle: "Global toggle and category behavior."
            )

            SettingsCard(title: "Global", icon: "switch.2") {
                NativeToggleRow(
                    title: "Enable SponsorBlock",
                    isOn: $settings.sponsorBlockEnabled
                )
            }

            SettingsCard(title: "Categories", icon: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SponsorBlockCategory.allCases) { category in
                        SponsorBlockCategoryRow(category: category)
                            .disabled(!settings.sponsorBlockEnabled)

                        if category != SponsorBlockCategory.allCases.last {
                            Rectangle()
                                .fill(settings.separatorColor)
                                .frame(height: 1)
                                .padding(.vertical, 18)
                        }
                    }
                }
            }
        }
    }
}

private struct SponsorBlockCategoryRow: View {
    @ObservedObject private var settings = AppSettings.shared
    let category: SponsorBlockCategory

    private var selection: Binding<SponsorBlockBehavior> {
        Binding(
            get: { settings.sponsorBlockBehavior(for: category) },
            set: { settings.setSponsorBlockBehavior($0, for: category) }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            RoundedRectangle(cornerRadius: 999)
                .fill(category.tint)
                .frame(width: 8, height: 40)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 6) {
                Text(category.shortTitle)
                    .font(.headline)
                Text(category.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Picker(category.title, selection: selection) {
                ForEach(SponsorBlockBehavior.allCases) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            }
            .labelsHidden()
            .frame(width: 150)
        }
    }
}

private struct ChangelogPane: View {
    @State private var changelogReleases = ChangelogDocument.load()

    private var currentVersionText: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.isEmpty {
            return version
        }
        return "Development Build"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "Changelog",
                subtitle: "Current version and release history."
            )

            SettingsCard(title: "Current Version", icon: "app.badge") {
                Text(currentVersionText)
                    .font(.title2.weight(.bold))
            }

            SettingsCard(title: "Changelog", icon: "text.document") {
                if changelogReleases.isEmpty == false {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(changelogReleases) { release in
                            ChangelogReleaseCard(release: release)
                        }
                    }
                } else {
                    Text("SwiftTube couldn’t load the bundled changelog.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ChangelogReleaseCard: View {
    @ObservedObject private var settings = AppSettings.shared
    let release: ChangelogRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(release.title)
                .font(.title3.weight(.bold))

            if let theme = release.theme, !theme.isEmpty {
                Text(theme)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }

            ForEach(release.paragraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(release.bullets, id: \.self) { bullet in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color.accentColor.opacity(0.9))
                        .frame(width: 6, height: 6)
                        .padding(.top, 7)

                    Text(bullet)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(settings.windowBackgroundColor.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(settings.separatorColor.opacity(0.8), lineWidth: 1)
        )
    }
}

private struct ControlsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "Controls",
                subtitle: "Seek amounts and keyboard shortcuts."
            )

            SettingsCard(title: "Seek Timing", icon: "gobackward.10") {
                ForEach(Array(SeekCategory.allCases.enumerated()), id: \.element.id) { index, category in
                    NativePickerRow(
                        title: category.title
                    ) {
                        Picker("Seek amount", selection: Binding(
                            get: { Int(settings.seekSeconds(for: category)) },
                            set: { settings.setSeekSeconds($0, for: category) }
                        )) {
                            ForEach(AppSettings.seekSecondsOptions, id: \.self) { seconds in
                                Text("\(seconds)s").tag(seconds)
                            }
                        }
                        .labelsHidden()
                    }

                    if index < SeekCategory.allCases.count - 1 {
                        SettingsDivider()
                    }
                }
            }

            ShortcutSectionCard(
                title: "Playback Controls",
                icon: "play.circle.fill"
            ) {
                ShortcutRow(action: .playPause)
                ShortcutRow(action: .theaterMode)
                ShortcutRow(action: .fullscreen)
                ShortcutRow(action: .subtitles)
            }

            ShortcutSectionCard(
                title: "Seek Navigation",
                icon: "gobackward.10"
            ) {
                ShortcutSubsection(title: "Short Seek", icon: "arrow.left.and.right.circle") {
                    ShortcutRow(action: .seekShortBack)
                    ShortcutRow(action: .seekShortForward)
                }

                ShortcutSubsection(title: "Medium Seek", icon: "arrow.left.arrow.right") {
                    ShortcutRow(action: .seekMediumBack)
                    ShortcutRow(action: .seekMediumForward)
                }

                ShortcutSubsection(title: "Long Seek", icon: "forward.end.circle") {
                    ShortcutRow(action: .seekLongBack)
                    ShortcutRow(action: .seekLongForward)
                }

                ShortcutSubsection(title: "Frame Stepping", icon: "film.stack") {
                    ShortcutRow(action: .frameBack)
                    ShortcutRow(action: .frameForward)
                }
            }

            ShortcutSectionCard(
                title: "Video Actions",
                icon: "hand.thumbsup.fill"
            ) {
                ShortcutRow(action: .likeVideo)
                ShortcutRow(action: .dislikeVideo)
                ShortcutRow(action: .watchLater)
                ShortcutRow(action: .saveToPlaylist)
                ShortcutRow(action: .subscribe)
                ShortcutRow(action: .share)
            }

            SettingsCard(title: "Keyboard Lock", icon: "lock.fill") {
                NativePickerRow(
                    title: "Lock key"
                ) {
                    Picker("Lock key", selection: $settings.keyboardLockKey) {
                        ForEach(AppSettings.KeyboardLockKey.allCases) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .labelsHidden()
                }
            }

            Button("Reset All Keybinds to Default") {
                settings.resetAllKeyBindings()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct SettingsHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 34, weight: .bold))
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsDivider: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Rectangle()
            .fill(settings.separatorColor)
            .frame(height: 1)
    }
}

private enum ChangelogDocument {
    static func load() -> [ChangelogRelease] {
        let bundledURL = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md", subdirectory: "Docs")
        let sourceTreeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../CHANGELOG.md")
            .standardizedFileURL

        for url in [bundledURL, sourceTreeURL] {
            guard let url else { continue }
            guard let rawMarkdown = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let releases = parseReleases(from: rawMarkdown)
            if releases.isEmpty == false {
                return releases
            }
        }
        return []
    }

    private static func parseReleases(from rawMarkdown: String) -> [ChangelogRelease] {
        var releases: [ChangelogRelease] = []
        var currentTitle: String?
        var currentTheme: String?
        var currentParagraphs: [String] = []
        var currentBullets: [String] = []

        func flushCurrentRelease() {
            guard let currentTitle else { return }
            releases.append(
                ChangelogRelease(
                    title: currentTitle,
                    theme: currentTheme,
                    paragraphs: currentParagraphs,
                    bullets: currentBullets
                )
            )
            selfReset()
        }

        func selfReset() {
            currentTitle = nil
            currentTheme = nil
            currentParagraphs = []
            currentBullets = []
        }

        for rawLine in rawMarkdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                continue
            }

            if line.hasPrefix("## ") {
                flushCurrentRelease()
                currentTitle = String(line.dropFirst(3))
                continue
            }

            guard currentTitle != nil else {
                continue
            }

            if line.hasPrefix("- ") {
                currentBullets.append(String(line.dropFirst(2)))
            } else if line.hasPrefix("Theme: ") {
                currentTheme = String(line.dropFirst("Theme: ".count))
            } else {
                currentParagraphs.append(line)
            }
        }

        flushCurrentRelease()
        return releases
    }
}

private struct ChangelogRelease: Identifiable {
    let title: String
    let theme: String?
    let paragraphs: [String]
    let bullets: [String]

    var id: String { title }
}

private struct SettingsCard<Content: View>: View {
    @ObservedObject private var settings = AppSettings.shared
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: icon)
                .font(.title3.weight(.bold))
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(settings.elevatedBackgroundColor)
        )
    }
}

private struct NativePickerRow<PickerContent: View>: View {
    let title: String
    let selectionText: String?
    @ViewBuilder let pickerContent: PickerContent

    init(title: String, selectionText: String? = nil, @ViewBuilder pickerContent: () -> PickerContent) {
        self.title = title
        self.selectionText = selectionText
        self.pickerContent = pickerContent()
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let selectionText {
                    Text(selectionText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            pickerContent
        }
    }
}

private struct NativeToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.headline)

            Spacer()

            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

private struct ShortcutSectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        SettingsCard(title: title, icon: icon) {
            content
        }
    }
}

private struct ShortcutSubsection<Content: View>: View {
    @ObservedObject private var settings = AppSettings.shared
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.headline)
                Text(title)
                    .font(.title3.weight(.bold))
            }
            .foregroundStyle(.primary)

            VStack(spacing: 12) {
                content
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(settings.separatorColor)
                .frame(height: 1)
                .opacity(0.9)
        }
    }
}

private struct ShortcutRow: View {
    @ObservedObject private var settings = AppSettings.shared
    let action: PlayerKeyAction

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: iconName)
                .font(.headline)
                .frame(width: 20)
                .foregroundStyle(.secondary)

            Text(action.title)
                .font(.headline)

            Spacer()

            KeyBindingRecorderButton(
                binding: Binding(
                    get: { settings.binding(for: action) },
                    set: { settings.setBinding($0, for: action) }
                )
            )
        }
    }

    private var iconName: String {
        switch action {
        case .playPause: return "playpause.fill"
        case .seekShortBack, .seekMediumBack, .seekLongBack: return "gobackward"
        case .seekShortForward, .seekMediumForward, .seekLongForward: return "goforward"
        case .frameBack, .frameForward: return "film"
        case .theaterMode: return "tv"
        case .fullscreen: return "arrow.up.left.and.arrow.down.right"
        case .subtitles: return "captions.bubble"
        case .likeVideo: return "hand.thumbsup"
        case .dislikeVideo: return "hand.thumbsdown"
        case .watchLater: return "clock"
        case .saveToPlaylist: return "text.badge.plus"
        case .subscribe: return "person.badge.plus"
        case .share: return "square.and.arrow.up"
        }
    }
}

private struct KeyBindingRecorderButton: View {
    @Binding var binding: KeyBinding
    @State private var isRecording = false
    @State private var previewText = "Listening..."
    @State private var pendingBinding: KeyBinding?
    @State private var keyDownMonitor: Any?
    @State private var keyUpMonitor: Any?

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isRecording ? "waveform" : "keyboard")
                    .foregroundStyle(isRecording ? Color.accentColor : .secondary)
                Text(isRecording ? previewText : binding.displayText)
                    .font(.headline)
                    .frame(minWidth: 200, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.primary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        previewText = "Listening..."
        isRecording = true

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isRecording else { return event }

            if event.keyCode == 53 {
                binding = .unbound
                stopRecording()
                return nil
            }

            guard let captured = KeyBinding.binding(from: event) else { return nil }
            pendingBinding = captured
            previewText = captured.displayText
            return nil
        }

        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            guard isRecording else { return event }
            if let pendingBinding, pendingBinding.keyCode == event.keyCode {
                binding = pendingBinding
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        previewText = "Listening..."
        pendingBinding = nil

        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }

        if let keyUpMonitor {
            NSEvent.removeMonitor(keyUpMonitor)
            self.keyUpMonitor = nil
        }
    }
}

private extension Color {
    var notificationColorValue: NotificationColorValue {
        let nsColor = NSColor(self).usingColorSpace(.deviceRGB) ?? .systemBlue
        return NotificationColorValue(
            red: Double(nsColor.redComponent),
            green: Double(nsColor.greenComponent),
            blue: Double(nsColor.blueComponent),
            opacity: Double(nsColor.alphaComponent)
        )
    }
}
