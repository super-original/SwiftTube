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

    var body: some View {
        TabView {
            AppearancePane()
                .tabItem { Label(SettingsPane.appearance.title, systemImage: SettingsPane.appearance.systemImage) }
            SidebarPane()
                .tabItem { Label(SettingsPane.sidebar.title, systemImage: SettingsPane.sidebar.systemImage) }
            PlaybackPane()
                .tabItem { Label(SettingsPane.playback.title, systemImage: SettingsPane.playback.systemImage) }
            SeekingPane()
                .tabItem { Label(SettingsPane.seeking.title, systemImage: SettingsPane.seeking.systemImage) }
            ShortcutPane()
                .tabItem { Label(SettingsPane.shortcuts.title, systemImage: SettingsPane.shortcuts.systemImage) }
        }
        .frame(width: 760, height: 540)
        .preferredColorScheme(settings.preferredColorScheme)
    }
}

private struct AppearancePane: View {
    @ObservedObject private var settings = AppSettings.shared

    private var darkThemes: [AppAppearanceMode] {
        [.dark, .midnight, .midnightOcean, .midnightForest, .midnightRose]
    }

    private var lightThemes: [AppAppearanceMode] {
        [.light, .sunrise, .sky, .mint, .rose]
    }

    var body: some View {
        Form {
            Section {
                Text("Choose the overall app theme.")
                    .foregroundStyle(.secondary)
            }

            Section("Dark Themes") {
                ForEach(darkThemes) { mode in
                    ThemeRow(mode: mode, isSelected: settings.appearanceMode == mode) {
                        settings.appearanceMode = mode
                    }
                }
            }

            Section("Light Themes") {
                ForEach(lightThemes) { mode in
                    ThemeRow(mode: mode, isSelected: settings.appearanceMode == mode) {
                        settings.appearanceMode = mode
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SidebarPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Text("Choose which top-level sections appear in the main sidebar and arrange them in the order you want.")
                    .foregroundStyle(.secondary)
            }

            Section("Sidebar Order") {
                ForEach(settings.sidebarItemOrder) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)

                        Text(item.title)

                        Spacer()

                        Toggle("Visible", isOn: Binding(
                            get: { settings.isSidebarItemVisible(item) },
                            set: { settings.setSidebarItem(item, visible: $0) }
                        ))
                        .labelsHidden()
                    }
                }
                .onMove(perform: settings.moveSidebarItems)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PlaybackPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Quality") {
                Picker("Default quality", selection: $settings.defaultQuality) {
                    ForEach(AppSettings.DefaultQuality.allCases) { quality in
                        Text(quality.rawValue).tag(quality)
                    }
                }
            }

            Section("Speed") {
                Picker("Default playback speed", selection: $settings.defaultPlaybackSpeed) {
                    ForEach(AppSettings.playbackSpeedOptions, id: \.self) { speed in
                        Text(AppSettings.playbackSpeedLabel(speed)).tag(speed)
                    }
                }

                Picker("Spacebar hold speed", selection: $settings.spacebarHoldPlaybackSpeed) {
                    ForEach(AppSettings.spacebarHoldPlaybackSpeedOptions, id: \.self) { speed in
                        Text(AppSettings.playbackSpeedLabel(speed)).tag(speed)
                    }
                }

                Text("Space still toggles play and pause instantly. Hold it for 0.8 seconds to temporarily switch to the configured hold speed until you release it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SeekingPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Text("Set the timing for the three seek categories. The actual keys are configured in Keybinds.")
                    .foregroundStyle(.secondary)
            }

            ForEach(SeekCategory.allCases) { category in
                Section {
                    Picker("Amount", selection: Binding(
                        get: { Int(settings.seekSeconds(for: category)) },
                        set: { settings.setSeekSeconds($0, for: category) }
                    )) {
                        ForEach(AppSettings.seekSecondsOptions, id: \.self) { seconds in
                            Text("\(seconds)s").tag(seconds)
                        }
                    }

                    HStack {
                        Label("Back", systemImage: "arrow.uturn.backward")
                        Spacer()
                        Text(bindingText(for: category, direction: .backward))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Forward", systemImage: "arrow.uturn.forward")
                        Spacer()
                        Text(bindingText(for: category, direction: .forward))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(category.title)
                } footer: {
                    Text(category.description)
                }
            }
        }
        .formStyle(.grouped)
    }

    private enum SeekDirection {
        case backward
        case forward
    }

    private func bindingText(for category: SeekCategory, direction: SeekDirection) -> String {
        let action: PlayerKeyAction = switch (category, direction) {
        case (.short, .backward): .seekShortBack
        case (.short, .forward): .seekShortForward
        case (.medium, .backward): .seekMediumBack
        case (.medium, .forward): .seekMediumForward
        case (.long, .backward): .seekLongBack
        case (.long, .forward): .seekLongForward
        }

        return settings.binding(for: action).displayText
    }
}

private struct ShortcutPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Text("Click a button to record a shortcut. Release the keys to save it, or press Escape while recording to clear it.")
                    .foregroundStyle(.secondary)
            }

            shortcutSection(
                title: "Playback Controls",
                icon: "play.circle.fill",
                actions: [.playPause, .theaterMode, .fullscreen, .subtitles]
            )

            shortcutSection(
                title: "Seek Navigation",
                icon: "gobackward.10"
            ) {
                shortcutSubgroup("Short Seek", icon: "arrow.left.and.right.circle", actions: [.seekShortBack, .seekShortForward])
                shortcutSubgroup("Medium Seek", icon: "arrow.left.arrow.right", actions: [.seekMediumBack, .seekMediumForward])
                shortcutSubgroup("Long Seek", icon: "forward.end.circle", actions: [.seekLongBack, .seekLongForward])
                shortcutSubgroup("Frame Stepping", icon: "film.stack", actions: [.frameBack, .frameForward])
            }

            shortcutSection(
                title: "Video Actions",
                icon: "hand.thumbsup.fill",
                actions: [.likeVideo, .dislikeVideo, .watchLater, .saveToPlaylist, .subscribe, .share]
            )

            Section {
                Picker("Lock key", selection: $settings.keyboardLockKey) {
                    ForEach(AppSettings.KeyboardLockKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
            } header: {
                Label("Keyboard Lock", systemImage: "lock.fill")
            } footer: {
                Text("The lock key disables playback shortcuts and player clicks until you press it again.")
            }

            Section {
                Button("Reset All Keybinds to Default") {
                    settings.resetAllKeyBindings()
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func shortcutSection(title: String, icon: String, actions: [PlayerKeyAction]) -> some View {
        Section {
            ForEach(actions) { action in
                ShortcutRow(action: action)
            }
        } header: {
            Label(title, systemImage: icon)
                .font(.headline)
        }
    }

    @ViewBuilder
    private func shortcutSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        Section {
            content()
        } header: {
            Label(title, systemImage: icon)
                .font(.headline)
        }
    }

    @ViewBuilder
    private func shortcutSubgroup(_ title: String, icon: String, actions: [PlayerKeyAction]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(actions) { action in
                ShortcutRow(action: action)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ThemeRow: View {
    let mode: AppAppearanceMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(mode.previewGradient)
                    .frame(width: 54, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(.quaternary, lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .foregroundStyle(.primary)
                    Text(mode.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ShortcutRow: View {
    @ObservedObject private var settings = AppSettings.shared
    let action: PlayerKeyAction

    var body: some View {
        HStack(spacing: 12) {
            Label(action.title, systemImage: iconName)
                .labelStyle(.titleAndIcon)
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
            HStack(spacing: 8) {
                Image(systemName: isRecording ? "waveform" : "keyboard")
                    .foregroundStyle(isRecording ? Color.accentColor : .secondary)
                Text(isRecording ? previewText : binding.displayText)
                    .frame(minWidth: 148, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
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
