import AppKit
import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case themes
    case sidebar
    case notifications
    case advanced
    case playback
    case controls
    case sponsorBlock
    case changelog

    var id: String { rawValue }

    static var appSection: [SettingsPane] {
        [.general, .themes, .sidebar, .notifications]
    }

    static var toolsSection: [SettingsPane] {
        [.advanced]
    }

    static var playbackSection: [SettingsPane] {
        [.playback, .controls, .sponsorBlock]
    }

    static var aboutSection: [SettingsPane] {
        [.changelog]
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .themes: return "Themes"
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
        case .general: return "gearshape"
        case .themes: return "paintpalette"
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
    @State private var selection: SettingsPane = .general

    var body: some View {
        ZStack {
            Rectangle()
                .fill(settings.windowBackgroundStyle)
                .ignoresSafeArea()

            NavigationSplitView {
                SettingsNativeSidebar(selection: $selection)
            } detail: {
                SettingsDetailHost(selection: $selection)
            }
            .navigationSplitViewStyle(.balanced)
            .removeSidebarToggle()
            .navigationTitle(selection.title)
        }
        .frame(
            minWidth: SettingsWindowSupport.minSize.width,
            idealWidth: 980,
            maxWidth: SettingsWindowSupport.maxSize.width,
            minHeight: SettingsWindowSupport.minSize.height,
            idealHeight: 650,
            maxHeight: SettingsWindowSupport.maxSize.height
        )
        .containerBackground(settings.windowBackgroundStyle, for: .window)
        .preferredColorScheme(settings.preferredColorScheme)
        .background(
            WindowAccessor { window in
                guard let window else { return }
                SettingsWindowSupport.configure(window)
                SettingsWindowSupport.preventSidebarCollapse(in: window)
            }
        )
    }
}

private struct SettingsNativeSidebar: View {
    @Binding var selection: SettingsPane

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(SettingsPane.appSection) { pane in
                    SettingsSidebarLabel(pane: pane)
                        .tag(pane)
                }
            } header: {
                HStack(spacing: 8) {
                    if let logo = BrandAssets.logo {
                        Image(nsImage: logo)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                    }
                    Text("SwiftTube")
                        .font(.title3.weight(.bold))
                }
                .foregroundStyle(.primary)
                .textCase(nil)
                .padding(.vertical, 6)
            }
            .collapsible(false)

            Section("Player") {
                ForEach(SettingsPane.playbackSection) { pane in
                    SettingsSidebarLabel(pane: pane)
                        .tag(pane)
                }
            }
            .collapsible(false)

            Section("Tools") {
                ForEach(SettingsPane.toolsSection) { pane in
                    SettingsSidebarLabel(pane: pane)
                        .tag(pane)
                }
            }
            .collapsible(false)

            Section("About") {
                ForEach(SettingsPane.aboutSection) { pane in
                    SettingsSidebarLabel(pane: pane)
                        .tag(pane)
                }
            }
            .collapsible(false)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 205, ideal: 220, max: 250)
    }
}

private struct SettingsDetailHost: View {
    @Binding var selection: SettingsPane
    @Namespace private var scrollTop

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Color.clear
                        .frame(height: 0)
                        .id(scrollTop)

                    switch selection {
                    case .general:
                        GeneralPane()
                    case .themes:
                        ThemesPane()
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
                .padding(22)
            }
            .onChange(of: selection) { _, _ in
                proxy.scrollTo(scrollTop, anchor: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct GeneralPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(
                title: "General",
                subtitle: "Navigation and startup behavior."
            )

            AppearancePaneContent()

            SettingsCard(title: nil, icon: nil) {
                VStack(spacing: 10) {
                    NativeToggleRow(
                        title: "Automatically collapse sidebar on video pages",
                        isOn: $settings.autoHideSidebarOnPlayback
                    )

                    SettingsDivider()

                    NativeToggleRow(
                        title: "Show sidebar on Home",
                        isOn: $settings.showSidebarOnHome
                    )
                }
            }

            SettingsCard(title: "Thumbnails", icon: "photo") {
                NativePickerRow(title: "Corner style") {
                    Picker("Corner style", selection: $settings.thumbnailCornerStyle) {
                        ForEach(ThumbnailCornerStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .labelsHidden()
                }

                SettingsDivider().padding(.vertical, 6)
                NativeToggleRow(title: "Fade images in", isOn: $settings.thumbnailFadeInEnabled)
                SettingsDivider().padding(.vertical, 6)
                NativeToggleRow(title: "Animate on hover", isOn: $settings.hoverAnimationsEnabled)
                SettingsDivider().padding(.vertical, 6)
                NativeToggleRow(title: "Show watch progress", isOn: $settings.showVideoProgressBars)
                SettingsDivider().padding(.vertical, 6)
                NativeToggleRow(title: "Show duration badges", isOn: $settings.showDurationBadges)
            }
        }
    }
}

private struct AppearancePaneContent: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsCard(title: "Video Grid", icon: "rectangle.grid.2x2") {
            VideoGridPresetSelector(selection: $settings.browseVideoGridPreset)
            .help("\(settings.browseVideoGridPreset.title), \(settings.browseVideoGridPreset.columnHint)")
            .accessibilityValue("\(settings.browseVideoGridPreset.title), \(settings.browseVideoGridPreset.columnHint)")
        }
    }
}

private struct ThemesPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(
                title: "Themes",
                subtitle: "Color presets."
            )

            SettingsCard(title: "Presets", icon: "paintpalette") {
                VStack(alignment: .leading, spacing: 14) {
                    ThemeGroup(themes: AppAppearanceMode.defaultThemes + AppAppearanceMode.coloredThemes)

                    Text("Gradients")
                        .font(.headline)
                    ThemeGroup(themes: AppAppearanceMode.gradientThemes)
                }
            }

            CustomThemeEditor(settings: settings)
        }
    }
}

private struct CustomThemeEditor: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsCard(title: "Custom Theme", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 16) {
                CustomThemePreview(configuration: settings.customThemeConfiguration)

                NativeToggleRow(title: "Use custom theme", isOn: $settings.usesCustomTheme)
                SettingsDivider()

                HStack {
                    Text("Colors")
                        .font(.headline)
                    Spacer()
                    Button("Add Color", systemImage: "plus") {
                        addColor()
                    }
                    .disabled(settings.customThemeConfiguration.colors.count >= 5)
                }

                VStack(spacing: 8) {
                    ForEach(0..<5, id: \.self) { index in
                        if settings.customThemeConfiguration.colors.indices.contains(index) {
                            CustomThemeColorRow(
                                number: index + 1,
                                color: customColorBinding(at: index),
                                canRemove: settings.customThemeConfiguration.colors.count > 1,
                                onRemove: { removeColor(at: index) }
                            )
                        }
                    }
                }

                SettingsDivider()

                ThemeSliderRow(
                    title: "Angle",
                    valueText: "\(Int(settings.customThemeConfiguration.angleDegrees.rounded()))°"
                ) {
                    Slider(value: customAngleBinding, in: 0...359, step: 1)
                        .disabled(settings.customThemeConfiguration.colors.count == 1)
                }

                ThemeSliderRow(
                    title: "Intensity",
                    valueText: settings.customThemeConfiguration.intensity.formatted(.percent.precision(.fractionLength(0)))
                ) {
                    Slider(value: customIntensityBinding, in: 0.2...1, step: 0.01)
                }

                NativePickerRow(title: "Interface") {
                    Picker("Interface", selection: customDarkTextBinding) {
                        Text("Light text").tag(false)
                        Text("Dark text").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                }
            }
        }
    }

    private func addColor() {
        var configuration = settings.customThemeConfiguration
        guard configuration.colors.count < 5 else { return }
        let previous = configuration.colors.last ?? .init(red: 0.1, green: 0.42, blue: 0.82)
        configuration.colors.append(previous)
        settings.customThemeConfiguration = configuration
        settings.usesCustomTheme = true
    }

    private func removeColor(at index: Int) {
        var configuration = settings.customThemeConfiguration
        guard configuration.colors.count > 1,
              configuration.colors.indices.contains(index) else { return }
        configuration.colors.remove(at: index)
        settings.customThemeConfiguration = configuration
        settings.usesCustomTheme = true
    }

    private func customColorBinding(at index: Int) -> Binding<Color> {
        Binding(
            get: {
                guard settings.customThemeConfiguration.colors.indices.contains(index) else {
                    return .clear
                }
                return settings.customThemeConfiguration.colors[index].color
            },
            set: { color in
                var configuration = settings.customThemeConfiguration
                guard configuration.colors.indices.contains(index) else { return }
                configuration.colors[index] = ThemeColorComponents(color: color)
                settings.customThemeConfiguration = configuration
                settings.usesCustomTheme = true
            }
        )
    }

    private var customAngleBinding: Binding<Double> {
        Binding(
            get: { settings.customThemeConfiguration.angleDegrees },
            set: { angle in
                var configuration = settings.customThemeConfiguration
                configuration.angleDegrees = angle
                settings.customThemeConfiguration = configuration
                settings.usesCustomTheme = true
            }
        )
    }

    private var customIntensityBinding: Binding<Double> {
        Binding(
            get: { settings.customThemeConfiguration.intensity },
            set: { intensity in
                var configuration = settings.customThemeConfiguration
                configuration.intensity = intensity
                settings.customThemeConfiguration = configuration
                settings.usesCustomTheme = true
            }
        )
    }

    private var customDarkTextBinding: Binding<Bool> {
        Binding(
            get: { settings.customThemeConfiguration.usesDarkText },
            set: { usesDarkText in
                var configuration = settings.customThemeConfiguration
                configuration.usesDarkText = usesDarkText
                settings.customThemeConfiguration = configuration
                settings.usesCustomTheme = true
            }
        )
    }
}

private struct CustomThemePreview: View {
    let configuration: CustomThemeConfiguration

    var body: some View {
        let points = configuration.gradientPoints
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: configuration.resolvedColors,
                        startPoint: points.start,
                        endPoint: points.end
                    )
                )

            HStack(spacing: 7) {
                Circle()
                    .frame(width: 9, height: 9)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .frame(width: 74, height: 8)
            }
            .foregroundStyle(configuration.usesDarkText ? Color.black.opacity(0.72) : Color.white.opacity(0.78))
            .padding(14)
        }
        .frame(height: 112)
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct CustomThemeColorRow: View {
    let number: Int
    @Binding var color: Color
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ColorPicker("Color \(number)", selection: $color, supportsOpacity: false)
            Spacer()
            Button("Remove Color", systemImage: "minus") {
                onRemove()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(!canRemove)
            .help("Remove Color")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ThemeSliderRow<Control: View>: View {
    let title: String
    let valueText: String
    @ViewBuilder let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            control
        }
    }
}

private struct ThemeGroup: View {
    @ObservedObject private var settings = AppSettings.shared
    let themes: [AppAppearanceMode]
    private let columns = [GridItem(.adaptive(minimum: 52, maximum: 52), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(themes) { theme in
                ThemeSwatch(
                    theme: theme,
                    isSelected: !settings.usesCustomTheme && settings.appearanceMode == theme
                ) {
                    settings.appearanceMode = theme
                    settings.usesCustomTheme = false
                }
            }
        }
        .padding(.top, 28)
    }
}

private struct ThemeSwatch: View {
    let theme: AppAppearanceMode
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.previewGradient)
                .frame(width: 52, height: 52)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.18),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.accentColor, .white)
                            .background(Circle().fill(.white))
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(theme.title)
        .overlay(alignment: .top) {
            if isHovered {
                Text(theme.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .glassEffect(.regular, in: Capsule())
                    .offset(y: -30)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .zIndex(isHovered ? 100 : 0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

private struct SidebarPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(
                title: "Sidebar",
                subtitle: "Navigation order and visibility."
            )

            SidebarNavigationEditor(settings: settings)
        }
    }
}

private struct SidebarNavigationEditor: View {
    @ObservedObject var settings: AppSettings

    private var visibleItems: [SidebarItemKind] {
        settings.sidebarItemOrder.filter(settings.isSidebarItemVisible)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            SidebarEditorPreview(items: visibleItems)
                .frame(width: 170)

            VStack(spacing: 12) {
                HStack {
                    Text("\(visibleItems.count) of \(settings.sidebarItemOrder.count) shown")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Hide All") {
                        settings.setAllSidebarItems(visible: false)
                    }
                    .buttonStyle(.glass(.regular.interactive()))
                    .controlSize(.small)

                    Button("Show All") {
                        settings.setAllSidebarItems(visible: true)
                    }
                    .buttonStyle(.glass(.regular.interactive()))
                    .controlSize(.small)
                }

                if #available(macOS 27.0, *) {
                    modernSidebarItemList
                } else {
                    legacySidebarItemList
                }
            }
            .padding(14)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    @available(macOS 27.0, *)
    private var modernSidebarItemList: some View {
        LazyVStack(spacing: 8) {
            ForEach(settings.sidebarItemOrder) { item in
                sidebarItemRow(item)
            }
            .reorderable()
        }
        .reorderContainer(for: SidebarItemKind.self, itemID: \.self) { difference in
            guard let dragged = difference.sources.first else { return }
            switch difference.destination.position {
            case .before(let target):
                settings.reorderSidebarItem(dragged, before: target)
            case .end:
                settings.reorderSidebarItem(dragged, to: settings.sidebarItemOrder.count)
            }
        }
    }

    private var legacySidebarItemList: some View {
        LazyVStack(spacing: 4) {
            ForEach(Array(settings.sidebarItemOrder.enumerated()), id: \.element) { index, item in
                SidebarReorderDropZone {
                    settings.reorderSidebarItem($0, to: index)
                }
                sidebarItemRow(item)
                    .draggable(item.rawValue)
            }
            SidebarReorderDropZone {
                settings.reorderSidebarItem($0, to: settings.sidebarItemOrder.count)
            }
        }
    }

    private func sidebarItemRow(_ item: SidebarItemKind) -> some View {
        SidebarSettingsListRow(
            item: item,
            isVisible: settings.isSidebarItemVisible(item),
            onVisibilityChanged: { settings.setSidebarItem(item, visible: $0) }
        )
    }
}

private struct SidebarReorderDropZone: View {
    let onInsert: (SidebarItemKind) -> Void
    @State private var isTargeted = false

    var body: some View {
        Capsule()
            .fill(isTargeted ? Color.accentColor.opacity(0.7) : .clear)
            .frame(height: isTargeted ? 4 : 4)
            .padding(.horizontal, 12)
            .animation(.easeOut(duration: 0.12), value: isTargeted)
            .dropDestination(for: String.self) { items, _ in
                guard let rawValue = items.first,
                      let item = SidebarItemKind(rawValue: rawValue) else {
                    return false
                }
                onInsert(item)
                return true
            } isTargeted: { hovering in
                isTargeted = hovering
            }
    }
}

private struct SidebarEditorPreview: View {
    let items: [SidebarItemKind]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Preview", systemImage: "sidebar.left")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                if items.isEmpty {
                    ContentUnavailableView(
                        "No Items",
                        systemImage: "sidebar.left",
                        description: Text("The sidebar will stay empty.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 250)
                } else {
                    ForEach(items) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .font(.callout.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 36)
                            .background(Color.primary.opacity(item == items.first ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .frame(minHeight: 370, alignment: .topLeading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SidebarSettingsListRow: View {
    let item: SidebarItemKind
    let isVisible: Bool
    let onVisibilityChanged: (Bool) -> Void

    var body: some View {
        Button {
            onVisibilityChanged(!isVisible)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 32)

                Image(systemName: item.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isVisible ? BrandAssets.swiftTubeBlue : .secondary)
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.headline)
                    Text(isVisible ? "Shown in the sidebar" : "Hidden from the sidebar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ZStack(alignment: isVisible ? .trailing : .leading) {
                    Capsule()
                        .fill(isVisible ? Color.accentColor : Color.secondary.opacity(0.28))
                        .frame(width: 38, height: 22)
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                        .frame(width: 18, height: 18)
                        .padding(2)
                }
                .animation(.snappy(duration: 0.18, extraBounce: 0), value: isVisible)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(Color.primary.opacity(isVisible ? 0.055 : 0.025), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(isVisible ? 0.08 : 0.04), lineWidth: 1)
        }
        .opacity(isVisible ? 1 : 0.66)
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityLabel(item.title)
        .accessibilityValue(isVisible ? "Shown" : "Hidden")
        .accessibilityAddTraits(isVisible ? .isSelected : [])
    }
}

private struct NotificationsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            SettingsCard(title: "Debug Timings", icon: "timer") {
                VStack(spacing: 0) {
                    ForEach(Array(TimedDebugNotification.allCases.enumerated()), id: \.element.id) { index, category in
                        NativeToggleRow(
                            title: category.title,
                            isOn: Binding(
                                get: { settings.isTimedDebugNotificationEnabled(category) },
                                set: { settings.setTimedDebugNotification(category, enabled: $0) }
                            )
                        )

                        if index < TimedDebugNotification.allCases.count - 1 {
                            SettingsDivider()
                                .padding(.vertical, 6)
                        }
                    }
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
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(
                title: "Advanced",
                subtitle: "Reset and notification testing."
            )

            SettingsCard(title: nil, icon: nil) {
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

                    SettingsDivider()

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
        VStack(alignment: .leading, spacing: 14) {
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

            SettingsCard(title: nil, icon: nil) {
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

            SettingsCard(title: nil, icon: nil) {
                NativeToggleRow(
                    title: "Send watch progress to YouTube",
                    detail: "Turn this off to keep watch history local. YouTube recommendations will not update from SwiftTube views.",
                    isOn: $settings.sendWatchProgressToYouTube
                )
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
        VStack(alignment: .leading, spacing: 14) {
            SettingsHeader(
                title: "SponsorBlock",
                subtitle: "Global toggle and category behavior."
            )

            SettingsCard(title: nil, icon: nil) {
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
        VStack(alignment: .leading, spacing: 14) {
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
        VStack(alignment: .leading, spacing: 14) {
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
        EmptyView()
    }
}

private struct SettingsSidebarLabel: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: pane.systemImage)
                .foregroundStyle(BrandAssets.swiftTubeBlue)
                .frame(width: 18)
            Text(pane.title)
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
    let title: String?
    let icon: String?
    @ViewBuilder let content: Content

    init(title: String?, icon: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        VStack(alignment: .leading, spacing: 10) {
            if let title, let icon {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: shape)
    }
}

private struct SettingsDependencyChoice: View {
    let title: String
    let value: String?
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.system(size: 17, weight: .semibold))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    if let value {
                        Text(value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false)
        .opacity(isEnabled ? 1 : 0.55)
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
                    .font(.body)
                if let selectionText {
                    Text(selectionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            pickerContent
                .controlSize(.small)
        }
    }
}

private struct NativeToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    init(title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .frame(minHeight: 26)
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
