import AppKit
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance
    case browse
    case sidebar
    case notifications
    case playback
    case updates
    case seeking
    case shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .browse: return "Browse"
        case .sidebar: return "Sidebar"
        case .notifications: return "Notifications"
        case .playback: return "Playback"
        case .updates: return "Updates"
        case .seeking: return "Seeking"
        case .shortcuts: return "Keybinds"
        }
    }

    var subtitle: String {
        switch self {
        case .appearance: return "Themes and colors"
        case .browse: return "Grid and cards"
        case .sidebar: return "Navigation layout"
        case .notifications: return "Queue and toasts"
        case .playback: return "Quality and speed"
        case .updates: return "Release notes"
        case .seeking: return "Seek timings"
        case .shortcuts: return "Keyboard controls"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "circle.lefthalf.filled"
        case .browse: return "rectangle.grid.2x2"
        case .sidebar: return "sidebar.left"
        case .notifications: return "bell.badge"
        case .playback: return "play.circle"
        case .updates: return "sparkles.rectangle.stack"
        case .seeking: return "gobackward.10"
        case .shortcuts: return "keyboard"
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selection: SettingsPane = .appearance
    @Namespace private var settingsScrollTop

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            settingsDetail
        }
        .frame(width: 940, height: 620)
        .background(settings.windowBackgroundColor.ignoresSafeArea())
        .preferredColorScheme(settings.preferredColorScheme)
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(.system(size: 30, weight: .bold))
                .padding(.top, 8)

            VStack(spacing: 8) {
                ForEach(SettingsPane.allCases) { pane in
                    SettingsSidebarRow(
                        pane: pane,
                        isSelected: selection == pane
                    ) {
                        withAnimation(.snappy(duration: 0.18, extraBounce: 0)) {
                            selection = pane
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(width: 240)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(settings.sidebarBackgroundColor)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(settings.separatorColor)
                .frame(width: 1)
        }
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
                    case .browse:
                        BrowsePane()
                    case .sidebar:
                        SidebarPane()
                    case .notifications:
                        NotificationsPane()
                    case .playback:
                        PlaybackPane()
                    case .updates:
                        UpdatesPane()
                    case .seeking:
                        SeekingPane()
                    case .shortcuts:
                        ShortcutPane()
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

private struct SettingsSidebarRow: View {
    @ObservedObject private var settings = AppSettings.shared
    let pane: SettingsPane
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: pane.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title)
                        .font(.headline)
                    Text(pane.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1)
            )
            .offset(x: isHovered && !isSelected ? 2 : 0)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : .primary)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return settings.elevatedBackgroundColor
        }
        return isHovered ? settings.hoverCardBackgroundColor : .clear
    }
}

private struct AppearancePane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var hoveredTheme: AppAppearanceMode?

    private var darkThemes: [AppAppearanceMode] {
        [.dark, .midnight, .midnightOcean, .midnightForest, .midnightRose, .midnightAurora, .midnightEmber, .midnightAmethyst, .midnightLagoon, .midnightCocoa]
    }

    private var lightThemes: [AppAppearanceMode] {
        [.light, .sunrise, .sky, .mint, .rose, .sand, .lavender, .citrus, .pearl, .coral]
    }

    private var spotlightTheme: AppAppearanceMode {
        hoveredTheme ?? settings.appearanceMode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "Appearance",
                subtitle: "Pick a visual theme for SwiftTube."
            )

            VStack(alignment: .leading, spacing: 14) {
                Text(spotlightTheme.title)
                    .font(.title2.weight(.bold))
                    .contentTransition(.opacity)
                Text(spotlightTheme.subtitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(settings.elevatedBackgroundColor)
            )

            ThemeGroup(title: "Dark Themes", themes: darkThemes, hoveredTheme: $hoveredTheme)
            ThemeGroup(title: "Light Themes", themes: lightThemes, hoveredTheme: $hoveredTheme)
        }
    }
}

private struct ThemeGroup: View {
    @ObservedObject private var settings = AppSettings.shared
    let title: String
    let themes: [AppAppearanceMode]
    @Binding var hoveredTheme: AppAppearanceMode?

    private let columns = Array(repeating: GridItem(.fixed(72), spacing: 12), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.bold))

            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(themes) { theme in
                    ThemeSwatch(
                        theme: theme,
                        isSelected: settings.appearanceMode == theme
                    ) {
                        settings.appearanceMode = theme
                    } onHover: { hovering in
                        hoveredTheme = hovering ? theme : nil
                    }
                }
            }
        }
    }
}

private struct ThemeSwatch: View {
    let theme: AppAppearanceMode
    let isSelected: Bool
    let onSelect: () -> Void
    let onHover: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(theme.previewGradient)
                    .frame(width: 72, height: 72)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
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
            .scaleEffect(isHovered ? 1.05 : 1)
            .overlay(alignment: .bottom) {
                Text(theme.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .opacity(isHovered ? 1 : 0)
                    .offset(y: 14)
            }
        }
        .buttonStyle(.plain)
        .padding(.bottom, 22)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
            onHover(hovering)
        }
    }

    private var borderColor: Color {
        if isSelected { return Color.accentColor }
        return Color.primary.opacity(isHovered ? 0.45 : 0.18)
    }
}

private struct BrowsePane: View {
    @ObservedObject private var settings = AppSettings.shared

    private var widthText: String {
        "\(Int(settings.browseVideoCardWidth)) pt"
    }

    private var densityLabel: String {
        switch settings.browseVideoCardWidth {
        case ..<320:
            return "Compact"
        case ..<390:
            return "Balanced"
        default:
            return "Large"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "Browse",
                subtitle: "Tune the size of video cards on Home and Search."
            )

            SettingsCard(title: "Video Grid", icon: "rectangle.grid.2x2") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Recommendations and search size")
                                .font(.headline)
                            Text("Larger cards reduce the number of columns and give titles more room before truncating.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text("\(densityLabel) · \(widthText)")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: $settings.browseVideoCardWidth,
                        in: AppSettings.browseVideoCardWidthRange,
                        step: AppSettings.browseVideoCardWidthStep
                    )

                    HStack {
                        Text("Smaller")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Larger")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct SidebarPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var draggedItem: SidebarItemKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "Sidebar",
                subtitle: "Drag items into the order you want, and toggle off the ones you don't need."
            )

            SettingsCard(title: "Navigation Items", icon: "sidebar.left") {
                VStack(spacing: 0) {
                    ForEach(settings.sidebarItemOrder) { item in
                        SidebarSettingsListRow(
                            item: item,
                            isVisible: settings.isSidebarItemVisible(item),
                            isDraggingOver: draggedItem == item
                        ) { visible in
                            settings.setSidebarItem(item, visible: visible)
                        }
                        .draggable(item.rawValue) {
                            Label(item.title, systemImage: item.systemImage)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let rawValue = items.first,
                                  let dragged = SidebarItemKind(rawValue: rawValue) else { return false }
                            settings.reorderSidebarItem(dragged, before: item)
                            return true
                        } isTargeted: { targeted in
                            draggedItem = targeted ? item : nil
                        }

                        if item != settings.sidebarItemOrder.last {
                            Rectangle()
                                .fill(settings.separatorColor)
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
    }
}

private struct SidebarSettingsListRow: View {
    let item: SidebarItemKind
    let isVisible: Bool
    let isDraggingOver: Bool
    let onVisibilityChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
            Toggle(isOn: Binding(
                get: { isVisible },
                set: { newValue in
                    onVisibilityChanged(newValue)
                }
            )) {
                Label(item.title, systemImage: item.systemImage)
                    .foregroundStyle(item == .home ? .primary : (isVisible ? .primary : .secondary))
            }
            .toggleStyle(.checkbox)
            .disabled(item == .home)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isDraggingOver ? Color.accentColor.opacity(0.12) : .clear)
        )
    }
}

private struct NotificationsPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var mutationCenter = AppMutationCenter.shared
    @State private var customTitle = "Custom notification"
    @State private var customMessage = "This is how your custom toast will look."
    @State private var customSymbol = "wand.and.stars"
    @State private var customColor = Color(red: 0.49, green: 0.75, blue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "Notifications",
                subtitle: "Control how background API actions report their progress back into the app."
            )

            SettingsCard(title: "Visibility", icon: "bell.badge") {
                NativePickerRow(
                    title: "Show notifications",
                    selectionText: settings.notificationDisplayMode.subtitle
                ) {
                    Picker("Show notifications", selection: $settings.notificationDisplayMode) {
                        ForEach(NotificationDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                }
            }

            SettingsCard(title: "Placement", icon: "uiwindow.split.2x1") {
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

                Text("Notifications stack upward from the selected corner and can still be dismissed manually.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SettingsCard(title: "Auto Hide", icon: "timer") {
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

                Text("Hover a notification to reveal its close button, or swipe it sideways to dismiss it early.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SettingsCard(title: "Preview", icon: "sparkles") {
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

                    Text("Preview buttons always show a toast, even if normal notifications are currently hidden.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                subtitle: "Startup quality and default speed behavior."
            )

            SettingsCard(title: "Quality", icon: "sparkles.tv") {
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
            }

            SettingsCard(title: "Speed", icon: "speedometer") {
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

            SettingsCard(title: "SponsorBlock", icon: "scissors") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: $settings.sponsorBlockEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Show sponsor markers")
                                .font(.headline)
                            Text("Display SponsorBlock segments on the player timeline.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Rectangle()
                        .fill(settings.separatorColor)
                        .frame(height: 1)

                    Toggle(isOn: $settings.sponsorBlockAutoSkipEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Auto-skip sponsor segments")
                                .font(.headline)
                            Text("Jump past sponsor sections automatically when playback enters them.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(!settings.sponsorBlockEnabled)

                    Text("SwiftTube currently uses SponsorBlock only for viewing and skipping sponsor sections. Submission and voting tools stay out of the app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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

private struct UpdatesPane: View {
    @State private var changelog = ChangelogDocument.load()

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
                title: "Updates",
                subtitle: "Release notes and version history for SwiftTube."
            )

            SettingsCard(title: "Current Version", icon: "app.badge") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(currentVersionText)
                        .font(.title2.weight(.bold))
                    Text("Every shipped update is recorded in the bundled changelog, including future named milestone releases.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard(title: "Changelog", icon: "text.document") {
                if let changelog {
                    Text(changelog)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("SwiftTube couldn’t load the bundled changelog.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SeekingPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "Seeking",
                subtitle: "Set the timing for the three seek categories."
            )

            ForEach(SeekCategory.allCases) { category in
                SettingsCard(title: category.title, icon: icon(for: category)) {
                    NativePickerRow(
                        title: "Seek amount"
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

                    Text("You can customize the shortcuts for this seek category in the Keybinds section.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Text(category.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func icon(for category: SeekCategory) -> String {
        switch category {
        case .short: return "arrow.left.and.right.circle"
        case .medium: return "gobackward.10"
        case .long: return "forward.end.circle"
        }
    }

}

private struct ShortcutPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "Keybinds",
                subtitle: "Click any binding to record a shortcut. Release the keys to save it, or press Escape while recording to clear it."
            )

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
                    title: "Lock key",
                    selectionText: settings.keyboardLockKey.displayName
                ) {
                    Picker("Lock key", selection: $settings.keyboardLockKey) {
                        ForEach(AppSettings.KeyboardLockKey.allCases) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .labelsHidden()
                }

                Text("The lock key disables playback shortcuts and player clicks until you press it again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

private enum ChangelogDocument {
    static func load() -> AttributedString? {
        let bundledURL = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md", subdirectory: "Docs")
        let sourceTreeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../CHANGELOG.md")
            .standardizedFileURL

        for url in [bundledURL, sourceTreeURL] {
            guard let url else { continue }
            guard let rawMarkdown = try? String(contentsOf: url, encoding: .utf8) else { continue }
            return try? AttributedString(
                markdown: rawMarkdown,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
            )
        }
        return nil
    }
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
        case .theaterMode: return "rectangle.expand.vertical"
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
