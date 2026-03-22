import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            PlaybackTab()
                .tabItem { Label("Playback", systemImage: "play.circle") }
                .tag(0)

            ControlsTab()
                .tabItem { Label("Controls", systemImage: "keyboard") }
                .tag(1)
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

                KeyBindingRow(label: "Seek back key", binding: $settings.seekBackKey)
                KeyBindingRow(label: "Seek forward key", binding: $settings.seekFwdKey)

                Picker("Seek back/forward amount", selection: $settings.jlSeekSeconds) {
                    ForEach(AppSettings.seekSecondsOptions, id: \.self) { s in
                        Text("\(s)s").tag(s)
                    }
                }
                .pickerStyle(.menu)

                KeyBindingRow(label: "Frame back key", binding: $settings.frameBackKey)
                KeyBindingRow(label: "Frame forward key", binding: $settings.frameFwdKey)

                Picker(", / . mode", selection: $settings.commaSeekMode) {
                    ForEach(AppSettings.SeekMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Playback") {
                KeyBindingRow(label: "Play / Pause (alt)", binding: $settings.playPauseKey)
                Text("Space always toggles play/pause. This sets an additional key.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Player") {
                KeyBindingRow(label: "Theater mode", binding: $settings.theaterKey)
                KeyBindingRow(label: "Fullscreen", binding: $settings.fullscreenKey)
                KeyBindingRow(label: "Subtitles", binding: $settings.subtitleKey)
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

private struct KeyBindingRow: View {
    let label: String
    @Binding var binding: String

    var body: some View {
        LabeledContent(label) {
            TextField("", text: Binding(
                get: { binding },
                set: { binding = String($0.prefix(1).lowercased()) }
            ))
            .frame(width: 40)
            .multilineTextAlignment(.center)
        }
    }
}
