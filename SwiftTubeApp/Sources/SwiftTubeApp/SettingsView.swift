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
        case .appearance: return "Theme and window look"
        case .sidebar: return "Visibility and ordering"
        case .playback: return "Quality and speed"
        case .seeking: return "Seek categories and timing"
        case .shortcuts: return "Keyboard controls"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "circle.lefthalf.filled.inverse"
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
        .frame(width: 820, height: 560)
        .preferredColorScheme(settings.preferredColorScheme)
    }
}

private struct AppearancePane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsDetailLayout(
            title: "Appearance",
            subtitle: "Pick the overall look SwiftTube should use."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    Button {
                        settings.appearanceMode = mode
                    } label: {
                        HStack(spacing: 16) {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(mode.previewGradient)
                                .frame(width: 86, height: 54)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18)
                                        .stroke(Color.white.opacity(mode.preferredColorScheme == .light ? 0.12 : 0.18), lineWidth: 1)
                                )

                            VStack(alignment: .leading, spacing: 5) {
                                Text(mode.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(mode.subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: settings.appearanceMode == mode ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(settings.appearanceMode == mode ? Color.accentColor : .secondary)
                        }
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 24)
                                .fill(settings.cardBackgroundColor)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

}

private struct SidebarPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var draggedItem: SidebarItemKind?

    var body: some View {
        SettingsDetailLayout(
            title: "Sidebar",
            subtitle: "Choose what appears in the main app sidebar and drag sections into the order you want."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(settings.sidebarItemOrder) { item in
                    SidebarArrangementCard(
                        item: item,
                        isVisible: settings.isSidebarItemVisible(item)
                    ) { isVisible in
                        settings.setSidebarItem(item, visible: isVisible)
                    }
                    .draggable(item.rawValue) {
                        SidebarDragPreview(item: item)
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let rawValue = items.first,
                              let dragged = SidebarItemKind(rawValue: rawValue) else {
                            return false
                        }
                        settings.reorderSidebarItem(dragged, before: item)
                        return true
                    } isTargeted: { targeted in
                        if targeted {
                            draggedItem = item
                        } else if draggedItem == item {
                            draggedItem = nil
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(draggedItem == item ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1.5)
                    )
                }

                Text("If authentication is unavailable, playlist-related sections stay hidden automatically even if they are enabled here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PlaybackPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsDetailLayout(
            title: "Playback",
            subtitle: "Control startup quality and default speed behavior."
        ) {
            Form {
                Section("Quality") {
                    Picker("Default quality", selection: $settings.defaultQuality) {
                        ForEach(AppSettings.DefaultQuality.allCases) { quality in
                            Text(quality.rawValue).tag(quality)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Speed") {
                    Picker("Default playback speed", selection: $settings.defaultPlaybackSpeed) {
                        ForEach(AppSettings.playbackSpeedOptions, id: \.self) { speed in
                            Text(AppSettings.playbackSpeedLabel(speed)).tag(speed)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Spacebar hold speed", selection: $settings.spacebarHoldPlaybackSpeed) {
                        ForEach(AppSettings.spacebarHoldPlaybackSpeedOptions, id: \.self) { speed in
                            Text(AppSettings.playbackSpeedLabel(speed)).tag(speed)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("Space still toggles play and pause instantly. If you hold it for 0.8 seconds, SwiftTube temporarily switches to the configured hold speed until you release it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct SeekingPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsDetailLayout(
            title: "Seeking",
            subtitle: "Tune the three seek categories independently, then bind them however you like in Keybinds."
        ) {
            VStack(spacing: 16) {
                ForEach(SeekCategory.allCases) { category in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(category.title)
                                    .font(.headline)
                                Text(category.description)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Picker(category.title, selection: Binding(
                                get: { Int(settings.seekSeconds(for: category)) },
                                set: { settings.setSeekSeconds($0, for: category) }
                            )) {
                                ForEach(AppSettings.seekSecondsOptions, id: \.self) { seconds in
                                    Text("\(seconds)s").tag(seconds)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 110)
                        }

                        HStack(spacing: 12) {
                            SeekBindingPill(
                                title: "Back",
                                binding: settings.binding(for: action(for: category, direction: .backward))
                            )
                            SeekBindingPill(
                                title: "Forward",
                                binding: settings.binding(for: action(for: category, direction: .forward))
                            )
                        }
                    }
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(settings.cardBackgroundColor)
                    )
                }
            }
        }
    }

    private enum SeekDirection {
        case backward
        case forward
    }

    private func action(for category: SeekCategory, direction: SeekDirection) -> PlayerKeyAction {
        switch (category, direction) {
        case (.short, .backward): return .seekShortBack
        case (.short, .forward): return .seekShortForward
        case (.medium, .backward): return .seekMediumBack
        case (.medium, .forward): return .seekMediumForward
        case (.long, .backward): return .seekLongBack
        case (.long, .forward): return .seekLongForward
        }
    }
}

private struct ShortcutPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsDetailLayout(
            title: "Keybinds",
            subtitle: "Click any button to record a shortcut. Release the keys to save it, or press Escape while recording to clear it."
        ) {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(groupedActions, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(group.title)
                                .font(.headline)
                            Spacer()
                            if group.title == "Playback" {
                                Text("Space is always reserved for play / pause and hold-speed.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        VStack(spacing: 10) {
                            ForEach(group.actions) { action in
                                ShortcutRow(action: action)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Keyboard Lock")
                        .font(.headline)

                    Picker("Lock key", selection: $settings.keyboardLockKey) {
                        ForEach(AppSettings.KeyboardLockKey.allCases) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("The lock key mutes playback shortcuts and player clicks until you press it again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button("Reset All Keybinds to Default") {
                        settings.resetAllKeyBindings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var groupedActions: [(title: String, actions: [PlayerKeyAction])] {
        Dictionary(grouping: PlayerKeyAction.allCases, by: \.groupTitle)
            .map { (title: $0.key, actions: $0.value) }
            .sorted { $0.title < $1.title }
    }
}

private struct SettingsDetailLayout<Content: View>: View {
    @ObservedObject private var settings = AppSettings.shared
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold))
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                content
            }
            .padding(28)
        }
        .background(settings.windowBackgroundColor.ignoresSafeArea())
    }
}

private struct SidebarArrangementCard: View {
    @ObservedObject private var settings = AppSettings.shared
    let item: SidebarItemKind
    let isVisible: Bool
    let onVisibilityChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "line.3.horizontal")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28)

            Label(item.title, systemImage: item.systemImage)
                .font(.headline)

            Spacer()

            Toggle("Visible", isOn: Binding(
                get: { isVisible },
                set: { onVisibilityChanged($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(settings.cardBackgroundColor)
        )
    }
}

private struct SidebarDragPreview: View {
    let item: SidebarItemKind

    var body: some View {
        Label(item.title, systemImage: item.systemImage)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SeekBindingPill: View {
    let title: String
    let binding: KeyBinding

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(binding.displayText)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(.white.opacity(0.08)))
    }
}

private struct ShortcutRow: View {
    @ObservedObject private var settings = AppSettings.shared
    let action: PlayerKeyAction

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(action.title)
                    .font(.body.weight(.medium))
                if action == .playPause {
                    Text("This is the alternate shortcut. Space always works too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            KeyBindingRecorderButton(
                binding: Binding(
                    get: { settings.binding(for: action) },
                    set: { settings.setBinding($0, for: action) }
                )
            )
        }
        .padding(.vertical, 4)
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
                    .frame(minWidth: 160, alignment: .leading)
                    .contentTransition(.opacity)
            }
            .font(.body.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isRecording ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
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
