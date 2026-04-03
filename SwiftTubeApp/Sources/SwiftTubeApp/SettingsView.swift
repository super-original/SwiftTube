import AppKit
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance
    case sidebar
    case playback
    case seeking
    case shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .sidebar: return "Sidebar"
        case .playback: return "Playback"
        case .seeking: return "Seeking"
        case .shortcuts: return "Keybinds"
        }
    }

    var subtitle: String {
        switch self {
        case .appearance: return "Themes and colors"
        case .sidebar: return "Navigation layout"
        case .playback: return "Quality and speed"
        case .seeking: return "Seek timings"
        case .shortcuts: return "Keyboard controls"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "circle.lefthalf.filled"
        case .sidebar: return "sidebar.left"
        case .playback: return "play.circle"
        case .seeking: return "gobackward.10"
        case .shortcuts: return "keyboard"
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selection: SettingsPane = .appearance

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
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                switch selection {
                case .appearance:
                    AppearancePane()
                case .sidebar:
                    SidebarPane()
                case .playback:
                    PlaybackPane()
                case .seeking:
                    SeekingPane()
                case .shortcuts:
                    ShortcutPane()
                }
            }
            .padding(28)
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
        [.dark, .midnight, .midnightOcean, .midnightForest, .midnightRose, .midnightAurora, .midnightEmber, .midnightAmethyst]
    }

    private var lightThemes: [AppAppearanceMode] {
        [.light, .sunrise, .sky, .mint, .rose, .sand, .lavender, .citrus]
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

    private let columns = Array(repeating: GridItem(.fixed(86), spacing: 14), count: 5)

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
                RoundedRectangle(cornerRadius: 18)
                    .fill(theme.previewGradient)
                    .frame(width: 86, height: 86)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(borderColor, lineWidth: isSelected ? 2.5 : 1)
                    )

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Color.accentColor, .white)
                        .background(Circle().fill(Color.white))
                        .offset(x: 7, y: -7)
                }
            }
            .scaleEffect(isHovered ? 1.05 : 1)
            .overlay(alignment: .bottom) {
                Text(theme.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .opacity(isHovered ? 1 : 0)
                    .offset(y: 14)
            }
        }
        .buttonStyle(.plain)
        .padding(.bottom, 26)
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

private struct SidebarPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var draggedItem: SidebarItemKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "Sidebar",
                subtitle: "Control which sections appear in the app sidebar and drag them into the order you want."
            )

            VStack(spacing: 12) {
                ForEach(settings.sidebarItemOrder) { item in
                    SidebarArrangementCard(
                        item: item,
                        isVisible: settings.isSidebarItemVisible(item),
                        isDraggingOver: draggedItem == item
                    ) { visible in
                        settings.setSidebarItem(item, visible: visible)
                    }
                    .draggable(item.rawValue) {
                        SidebarDragPreview(item: item)
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let rawValue = items.first,
                              let dragged = SidebarItemKind(rawValue: rawValue) else { return false }
                        settings.reorderSidebarItem(dragged, before: item)
                        return true
                    } isTargeted: { targeted in
                        draggedItem = targeted ? item : nil
                    }
                }
            }
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
                    title: "Default quality",
                    selectionText: settings.defaultQuality.rawValue
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
                    title: "Default playback speed",
                    selectionText: AppSettings.playbackSpeedLabel(settings.defaultPlaybackSpeed)
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
                    title: "Spacebar hold speed",
                    selectionText: AppSettings.playbackSpeedLabel(settings.spacebarHoldPlaybackSpeed)
                ) {
                    Picker("Spacebar hold speed", selection: $settings.spacebarHoldPlaybackSpeed) {
                        ForEach(AppSettings.spacebarHoldPlaybackSpeedOptions, id: \.self) { speed in
                            Text(AppSettings.playbackSpeedLabel(speed)).tag(speed)
                        }
                    }
                    .labelsHidden()
                }

                Text("Space still toggles play and pause instantly. Hold it for 0.8 seconds to temporarily switch to the configured hold speed until you release it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(settings.separatorColor)
            .frame(height: 1)
    }
}

private struct SeekingPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "Seeking",
                subtitle: "Set the timing for the three seek categories. Their shortcuts are shown here and can be changed in Keybinds."
            )

            ForEach(SeekCategory.allCases) { category in
                SettingsCard(title: category.title, icon: icon(for: category)) {
                    NativePickerRow(
                        title: "Seek amount",
                        selectionText: "\(Int(settings.seekSeconds(for: category)))s"
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

                    divider

                    bindingLine(
                        title: "Back",
                        icon: "arrow.uturn.backward",
                        bindingText: bindingText(for: category, isForward: false)
                    )

                    bindingLine(
                        title: "Forward",
                        icon: "arrow.uturn.forward",
                        bindingText: bindingText(for: category, isForward: true)
                    )

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

    private func bindingText(for category: SeekCategory, isForward: Bool) -> String {
        let action: PlayerKeyAction = switch (category, isForward) {
        case (.short, false): .seekShortBack
        case (.short, true): .seekShortForward
        case (.medium, false): .seekMediumBack
        case (.medium, true): .seekMediumForward
        case (.long, false): .seekLongBack
        case (.long, true): .seekLongForward
        }
        return settings.binding(for: action).displayText
    }

    private var divider: some View {
        Rectangle()
            .fill(settings.separatorColor)
            .frame(height: 1)
    }

    private func bindingLine(title: String, icon: String, bindingText: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .foregroundStyle(.secondary)
            Spacer()
            Text(bindingText)
                .font(.headline)
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
    let selectionText: String
    @ViewBuilder let pickerContent: PickerContent

    init(title: String, selectionText: String, @ViewBuilder pickerContent: () -> PickerContent) {
        self.title = title
        self.selectionText = selectionText
        self.pickerContent = pickerContent()
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(selectionText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            pickerContent
        }
    }
}

private struct SidebarArrangementCard: View {
    @ObservedObject private var settings = AppSettings.shared
    let item: SidebarItemKind
    let isVisible: Bool
    let isDraggingOver: Bool
    let onVisibilityChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "line.3.horizontal")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)

            Label(item.title, systemImage: item.systemImage)
                .font(.headline)

            Spacer()

            Toggle("Visible", isOn: Binding(
                get: { isVisible },
                set: { newValue in
                    onVisibilityChanged(newValue)
                }
            ))
            .labelsHidden()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(settings.elevatedBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(isDraggingOver ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1.5)
        )
    }
}

private struct SidebarDragPreview: View {
    let item: SidebarItemKind

    var body: some View {
        Label(item.title, systemImage: item.systemImage)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
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
