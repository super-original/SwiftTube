import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            PlaybackTab()
                .tabItem { Label("Playback", systemImage: "play.circle") }
                .tag(0)

            PlayerTab()
                .tabItem { Label("Player", systemImage: "tv") }
                .tag(1)

            ControlsTab()
                .tabItem { Label("Controls", systemImage: "keyboard") }
                .tag(2)
        }
        .frame(width: 480)
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Playback Tab

private struct PlaybackTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Quality") {
                Picker("Default quality", selection: $settings.defaultQuality) {
                    ForEach(AppSettings.DefaultQuality.allCases) { quality in
                        Text(quality.rawValue).tag(quality)
                    }
                }
                .pickerStyle(.menu)

                Text("Sets the starting quality when opening a video. You can always change it with the quality menu during playback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Player Tab

private struct PlayerTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Theater & Fullscreen") {
                Toggle("Auto-hide toolbar", isOn: $settings.hideTopBarInImmersiveMode)

                Text("Hides the window toolbar in theater mode. Move the cursor to the top of the window to reveal it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Controls Tab

private struct ControlsTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Seek Amounts") {
                Picker("← → (Arrow keys)", selection: $settings.arrowSeekSeconds) {
                    ForEach(AppSettings.seekSecondsOptions, id: \.self) { s in
                        Text("\(s)s").tag(s)
                    }
                }
                .pickerStyle(.menu)

                Picker("J / L keys", selection: $settings.jlSeekSeconds) {
                    ForEach(AppSettings.seekSecondsOptions, id: \.self) { s in
                        Text("\(s)s").tag(s)
                    }
                }
                .pickerStyle(.menu)

                Picker(", / . keys", selection: $settings.commaSeekMode) {
                    ForEach(AppSettings.SeekMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Keyboard Lock") {
                Picker("Lock key", selection: $settings.keyboardLockKey) {
                    ForEach(AppSettings.KeyboardLockKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .pickerStyle(.menu)

                Text("Press the lock key during playback to disable all keyboard shortcuts. Press it again to unlock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
