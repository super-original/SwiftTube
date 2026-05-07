import AppKit
import SwiftUI

private enum OnboardingStage: String, CaseIterable, Identifiable, Comparable {
    case welcome = "Welcome"
    case theme = "Theme"
    case playback = "Playback"
    case layout = "Layout"
    case privacy = "Privacy"
    case account = "Account"
    case finished = "Done"

    var id: String { rawValue }

    static func < (lhs: OnboardingStage, rhs: OnboardingStage) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

struct OnboardingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject private var authSession: AuthSessionModel
    @State private var stage: OnboardingStage = .welcome
    @State private var isHoveringOverProgressView = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AnimatedOnboardingBackground()

                VStack {
                    progressView
                        .padding(.top)
                        .onHover { hovering in
                            withAnimation(.easeOut(duration: 0.16)) {
                                isHoveringOverProgressView = hovering
                            }
                        }

                    if isHoveringOverProgressView {
                        Text(progressText)
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)

                VStack(spacing: 26) {
                    stageContent
                        .frame(width: min(geometry.size.width * 0.75, 860))
                        .padding(.horizontal)

                    Button(stage == .finished ? "Start Watching" : "Next", systemImage: stage == .finished ? "play.fill" : "arrow.right") {
                        if stage == .finished {
                            withAnimation {
                                settings.onboardingCompleted = true
                            }
                        } else {
                            stepStage()
                        }
                    }
                    .clipShape(.capsule)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            }
            .foregroundStyle(.primary)
        }
    }

    private var progressView: some View {
        HStack(spacing: 9) {
            ForEach(OnboardingStage.allCases) { item in
                if stage > item {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else if stage == item {
                    Image(systemName: "circle")
                        .symbolVariant(.fill)
                        .foregroundStyle(BrandAssets.swiftTubeBlue)
                    Text(item.rawValue)
                        .font(.footnote.weight(.semibold))
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var progressText: String {
        let stages = OnboardingStage.allCases
        guard let index = stages.firstIndex(of: stage), stages.count > 1 else { return "0% complete" }
        let fraction = Double(index) / Double(stages.count - 1)
        return "\(fraction.formatted(.percent.precision(.fractionLength(0)))) complete"
    }

    @ViewBuilder
    private var stageContent: some View {
        switch stage {
        case .welcome:
            WelcomeStage()
        case .theme:
            ThemeStage(selection: $settings.appearanceMode)
        case .playback:
            PlaybackStage(
                sponsorBlockEnabled: $settings.sponsorBlockEnabled,
                controlLayout: $settings.playerControlLayout
            )
        case .layout:
            LayoutStage(selection: $settings.browseVideoGridPreset)
        case .privacy:
            PrivacyStage(sendWatchProgressToYouTube: $settings.sendWatchProgressToYouTube)
        case .account:
            AccountStage(
                status: authSession.status,
                isWorking: authSession.isWorking,
                errorMessage: authSession.errorMessage,
                connect: { browser in
                    Task { await authSession.connect(using: browser) }
                },
                continueWithoutAccount: {
                    stepStage()
                }
            )
        case .finished:
            FinishedStage()
        }
    }

    private func stepStage(by amount: Int = 1) {
        let stages = OnboardingStage.allCases
        guard let index = stages.firstIndex(of: stage) else { return }
        let nextIndex = min(max(index + amount, 0), stages.count - 1)
        withAnimation(.snappy(duration: 0.26, extraBounce: 0.08)) {
            stage = stages[nextIndex]
        }
    }
}

private struct AnimatedOnboardingBackground: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            LinearGradient(
                colors: [
                    BrandAssets.swiftTubeBlue.opacity(0.48),
                    Color(red: 0.15, green: 0.30, blue: 0.55).opacity(0.42),
                    Color(nsColor: .windowBackgroundColor)
                ],
                startPoint: UnitPoint(
                    x: 0.12 + 0.06 * sin(phase / 5),
                    y: 0.05
                ),
                endPoint: UnitPoint(
                    x: 0.88,
                    y: 0.95 + 0.05 * cos(phase / 6)
                )
            )
            .overlay {
                Color.black.opacity(0.22)
            }
            .ignoresSafeArea()
        }
    }
}

private struct WelcomeStage: View {
    var body: some View {
        VStack(spacing: 18) {
            if let logo = BrandAssets.logo {
                Image(nsImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 92)
            } else {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 82, height: 82)
            }

            Text("SwiftTube")
                .font(.system(size: 58, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

private struct ThemeStage: View {
    @Binding var selection: AppAppearanceMode

    private let themes: [AppAppearanceMode] = [
        .dark,
        .midnight,
        .sky,
        .glacier,
        .mint,
        .pearl
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            stageTitle("Theme")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                ForEach(themes) { theme in
                    ThemePreviewButton(theme: theme, isSelected: selection == theme) {
                        selection = theme
                    }
                }
            }
        }
    }
}

private struct ThemePreviewButton: View {
    let theme: AppAppearanceMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(theme.previewGradient)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.white.opacity(0.8))
                            .frame(width: 9, height: 9)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.55))
                            .frame(width: 58, height: 8)
                    }
                    .padding(12)
                }
                .frame(height: 96)

                HStack {
                    Text(theme.title)
                        .font(.headline)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? BrandAssets.swiftTubeBlue : .secondary)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isSelected ? BrandAssets.swiftTubeBlue.opacity(0.8) : Color.white.opacity(0.08), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PlaybackStage: View {
    @Binding var sponsorBlockEnabled: Bool
    @Binding var controlLayout: PlayerControlLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            stageTitle("Playback")

            HStack(alignment: .top, spacing: 16) {
                SponsorBlockPreviewCard(isEnabled: $sponsorBlockEnabled)

                VStack(spacing: 16) {
                    ControlLayoutCard(layout: .compact, selection: $controlLayout)
                    ControlLayoutCard(layout: .standard, selection: $controlLayout)
                }
            }
        }
    }
}

private struct SponsorBlockPreviewCard: View {
    @Binding var isEnabled: Bool

    var body: some View {
        Button {
            isEnabled.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("SponsorBlock", systemImage: "forward.end.fill")
                        .font(.title3.weight(.bold))
                    Spacer()
                    Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isEnabled ? BrandAssets.swiftTubeBlue : .secondary)
                }

                TimelinePreview(
                    segments: [
                        (.sponsor, 0.09, 0.18),
                        (.selfpromo, 0.43, 0.12),
                        (.intro, 0.68, 0.08)
                    ]
                )

                HStack(spacing: 8) {
                    CategoryChip(category: .sponsor)
                    CategoryChip(category: .selfpromo)
                    CategoryChip(category: .intro)
                    Spacer()
                }

                Text(isEnabled ? "Manual skip for sponsor, self promo, reminders, and intros." : "SponsorBlock stays off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 252, alignment: .topLeading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(isEnabled ? BrandAssets.swiftTubeBlue.opacity(0.7) : Color.white.opacity(0.08), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ControlLayoutCard: View {
    let layout: PlayerControlLayout
    @Binding var selection: PlayerControlLayout

    private var isSelected: Bool { selection == layout }

    var body: some View {
        Button {
            selection = layout
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(layout.title)
                        .font(.headline)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? BrandAssets.swiftTubeBlue : .secondary)
                }

                PlayerControlsPreview(layout: layout)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isSelected ? BrandAssets.swiftTubeBlue.opacity(0.75) : Color.white.opacity(0.08), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct LayoutStage: View {
    @Binding var selection: BrowseVideoGridPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            stageTitle("Video grid")

            HStack(spacing: 16) {
                ForEach(BrowseVideoGridPreset.allCases) { preset in
                    GridPresetCard(preset: preset, selection: $selection)
                }
            }
        }
    }
}

private struct GridPresetCard: View {
    let preset: BrowseVideoGridPreset
    @Binding var selection: BrowseVideoGridPreset

    private var isSelected: Bool { selection == preset }

    var body: some View {
        Button {
            selection = preset
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(preset.title)
                        .font(.headline)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? BrandAssets.swiftTubeBlue : .secondary)
                }

                GridPreview(columns: preset.previewColumnCount)

                Text(preset.columnHint)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(isSelected ? BrandAssets.swiftTubeBlue : .secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 244, alignment: .topLeading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(isSelected ? BrandAssets.swiftTubeBlue.opacity(0.75) : Color.white.opacity(0.08), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PrivacyStage: View {
    @Binding var sendWatchProgressToYouTube: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            stageTitle("Privacy")

            HStack(spacing: 16) {
                PrivacyChoiceCard(
                    title: "Sync with YouTube",
                    systemImage: "arrow.triangle.2.circlepath",
                    isSelected: sendWatchProgressToYouTube,
                    detail: "SwiftTube sends watch progress to YouTube, so recommendations keep adapting.",
                    action: { sendWatchProgressToYouTube = true }
                )

                PrivacyChoiceCard(
                    title: "Local only",
                    systemImage: "lock.fill",
                    isSelected: !sendWatchProgressToYouTube,
                    detail: "SwiftTube keeps local history, but YouTube recommendations will not update from these views.",
                    action: { sendWatchProgressToYouTube = false }
                )
            }
        }
    }
}

private struct PrivacyChoiceCard: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.system(size: 24, weight: .semibold))
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? BrandAssets.swiftTubeBlue : .secondary)
                }

                Text(title)
                    .font(.title2.weight(.bold))

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(isSelected ? BrandAssets.swiftTubeBlue.opacity(0.75) : Color.white.opacity(0.08), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AccountStage: View {
    let status: AuthStatusResponse
    let isWorking: Bool
    let errorMessage: String?
    let connect: (BrowserLoginOption) -> Void
    let continueWithoutAccount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            stageTitle("Account")

            HStack(alignment: .top, spacing: 16) {
                AccountPreview(status: status)

                VStack(spacing: 12) {
                    ForEach(BrowserLoginOption.allCases) { browser in
                        BrowserConnectCard(
                            browser: browser,
                            isSelected: status.browser == browser.rawValue,
                            isWorking: isWorking,
                            action: { connect(browser) }
                        )
                    }

                    Button("Continue without account", systemImage: "arrow.right") {
                        continueWithoutAccount()
                    }
                    .clipShape(.capsule)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isWorking {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

private struct AccountPreview: View {
    let status: AuthStatusResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                BrandAssets.swiftTubeBlue.opacity(0.42),
                                Color(red: 0.10, green: 0.18, blue: 0.32).opacity(0.88)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if status.authenticated, let avatarURL = status.avatarURL {
                    CachedAsyncImage(url: avatarURL, maxPixelSize: 180) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 62, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .frame(width: 92, height: 92)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.24), lineWidth: 1))
                } else {
                    Image(systemName: status.authenticated ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                        .font(.system(size: 72, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(height: 170)

            Text(status.authenticated ? "Signed in" : "Not signed in")
                .font(.title2.weight(.bold))

            if let browserLabel = status.browserLabel, status.authenticated {
                Text(browserLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 320, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct BrowserConnectCard: View {
    let browser: BrowserLoginOption
    let isSelected: Bool
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: browser.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(browser.shortTitle)
                        .font(.headline)
                    Text(browser.onboardingSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "arrow.right.circle")
                    .foregroundStyle(isSelected ? BrandAssets.swiftTubeBlue : .secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(isSelected ? BrandAssets.swiftTubeBlue.opacity(0.72) : Color.white.opacity(0.08), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }
}

private struct FinishedStage: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 62, weight: .semibold))
                .foregroundStyle(BrandAssets.swiftTubeBlue)

            Text("Ready")
                .font(.system(size: 52, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

private struct TimelinePreview: View {
    let segments: [(SponsorBlockCategory, CGFloat, CGFloat)]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 9)

                Capsule()
                    .fill(BrandAssets.swiftTubeBlue)
                    .frame(width: proxy.size.width * 0.28, height: 9)

                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Capsule()
                        .fill(segment.0.tint)
                        .frame(width: proxy.size.width * segment.2, height: 9)
                        .offset(x: proxy.size.width * segment.1)
                }
            }
        }
        .frame(height: 12)
    }
}

private struct CategoryChip: View {
    let category: SponsorBlockCategory

    var body: some View {
        Text(category.shortTitle)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(category.tint.opacity(0.18), in: Capsule())
            .foregroundStyle(category.tint)
    }
}

private struct PlayerControlsPreview: View {
    let layout: PlayerControlLayout

    var body: some View {
        VStack(spacing: layout == .compact ? 10 : 8) {
            if layout == .compact {
                TimelinePreview(segments: [(.sponsor, 0.18, 0.12)])
                controlsRow
            } else {
                HStack(spacing: 8) {
                    controlsRow
                    TimelinePreview(segments: [(.sponsor, 0.18, 0.12)])
                }
            }
        }
        .frame(height: 72)
    }

    private var controlsRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.white.opacity(0.82))
                .frame(width: 20, height: 20)
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 70, height: 18)
            Spacer()
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(width: 92, height: 28)
        }
    }
}

private struct GridPreview: View {
    let columns: Int

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 10) {
            ForEach(0..<(columns * 2), id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(index % 2 == 0 ? BrandAssets.swiftTubeBlue.opacity(0.6) : Color.white.opacity(0.20))
                        .aspectRatio(16 / 9, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.38))
                        .frame(height: 7)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 44, height: 6)
                }
            }
        }
    }
}

private func stageTitle(_ title: String) -> some View {
    Text(title)
        .font(.system(size: 52, weight: .bold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
}

private extension BrowseVideoGridPreset {
    var previewColumnCount: Int {
        switch self {
        case .large: return 2
        case .standard: return 3
        case .compact: return 4
        }
    }
}

private extension BrowserLoginOption {
    var shortTitle: String {
        switch self {
        case .chrome: return "Chrome"
        case .safari: return "Safari"
        }
    }

    var onboardingSubtitle: String {
        switch self {
        case .chrome: return "Use the YouTube account already signed in there."
        case .safari: return "Use the YouTube account already signed in there."
        }
    }

    var systemImage: String {
        switch self {
        case .chrome: return "globe"
        case .safari: return "safari"
        }
    }
}
