import AppKit
import SwiftUI

private enum OnboardingStage: String, CaseIterable, Identifiable, Comparable {
    case welcome = "Welcome"
    case theme = "Theme"
    case sponsorBlock = "SponsorBlock"
    case controls = "Controls"
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

                    if shouldShowPrimaryButton {
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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            }
            .foregroundStyle(.primary)
            .preferredColorScheme(.dark)
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
        case .sponsorBlock:
            SponsorBlockStage(sponsorBlockEnabled: $settings.sponsorBlockEnabled)
        case .controls:
            ControlsStage(controlLayout: $settings.playerControlLayout)
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

    private var shouldShowPrimaryButton: Bool {
        !(stage == .account && authSession.status.authenticated == false)
    }

    private func stepStage(by amount: Int = 1) {
        let stages = OnboardingStage.allCases
        guard let index = stages.firstIndex(of: stage) else { return }
        var nextIndex = min(max(index + amount, 0), stages.count - 1)
        if amount > 0, stages[nextIndex] == .account, authSession.status.authenticated {
            nextIndex = min(nextIndex + 1, stages.count - 1)
        }
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
                    Color(red: 0.06, green: 0.09, blue: 0.15)
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

private struct SponsorBlockStage: View {
    @Binding var sponsorBlockEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            stageTitle("SponsorBlock")

            HStack(alignment: .top, spacing: 16) {
                SponsorBlockModeCard(
                    title: "On",
                    isSelected: sponsorBlockEnabled,
                    action: { sponsorBlockEnabled = true }
                )

                SponsorBlockModeCard(
                    title: "Off",
                    isSelected: !sponsorBlockEnabled,
                    action: { sponsorBlockEnabled = false }
                )
            }

            SponsorBlockTimelineCard(isEnabled: sponsorBlockEnabled)
        }
    }
}

private struct ControlsStage: View {
    @Binding var controlLayout: PlayerControlLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            stageTitle("Player controls")

            HStack(spacing: 16) {
                ControlLayoutCard(layout: .compact, selection: $controlLayout)
                ControlLayoutCard(layout: .standard, selection: $controlLayout)
            }
        }
    }
}

private struct SponsorBlockModeCard: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? BrandAssets.swiftTubeBlue : .secondary)
                    .font(.title3.weight(.semibold))

                Text(title)
                    .font(.title3.weight(.bold))
                Spacer()
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

private struct SponsorBlockTimelineCard: View {
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Timeline preview", systemImage: "forward.end.fill")
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

            Text(isEnabled ? "Manual skip for sponsor, self promo, reminders, and intro." : "SponsorBlock stays off.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(isEnabled ? BrandAssets.swiftTubeBlue.opacity(0.7) : Color.white.opacity(0.08), lineWidth: 1.5)
        )
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
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(layout.title)
                        .font(.headline)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? BrandAssets.swiftTubeBlue : .secondary)
                }

                OnboardingPlayerControlsPreview(layout: layout)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
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

                GridPreview(columns: preset.columnCount)

                Text(preset.columnHint)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(isSelected ? BrandAssets.swiftTubeBlue : .secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
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

            if status.authenticated {
                SignedInAccountCard(status: status)
                    .frame(maxWidth: 560, alignment: .leading)
            } else {
                VStack(spacing: 14) {
                    ForEach(BrowserLoginOption.allCases) { browser in
                        AccountChoiceButton(
                            title: browser.shortTitle,
                            subtitle: browser.onboardingSubtitle,
                            icon: .app(browser.appIcon),
                            isWorking: isWorking,
                            action: { connect(browser) }
                        )
                    }

                    AccountChoiceButton(
                        title: "Skip sign in",
                        subtitle: "Continue without a YouTube account.",
                        icon: .system("arrow.right"),
                        isWorking: isWorking,
                        action: continueWithoutAccount
                    )

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

private struct SignedInAccountCard: View {
    let status: AuthStatusResponse

    var body: some View {
        HStack(spacing: 18) {
            if let avatarURL = status.avatarURL {
                CachedAsyncImage(url: avatarURL, maxPixelSize: 180) {
                    accountFallbackIcon
                }
                .frame(width: 96, height: 96)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
            } else {
                accountFallbackIcon
                    .frame(width: 96, height: 96)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Signed in to \(status.displayName?.nilIfBlank ?? status.browserLabel ?? "YouTube")")
                    .font(.title2.weight(.bold))
                    .lineLimit(2)

                if let email = status.email?.nilIfBlank {
                    Text(email)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                } else {
                    Text(status.browserLabel ?? "YouTube")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(BrandAssets.swiftTubeBlue.opacity(0.65), lineWidth: 1.5)
        )
    }

    private var accountFallbackIcon: some View {
        Image(systemName: "person.crop.circle.badge.checkmark")
            .font(.system(size: 64, weight: .semibold))
            .foregroundStyle(BrandAssets.swiftTubeBlue, Color.white.opacity(0.86))
    }
}

private enum AccountChoiceIcon {
    case app(NSImage)
    case system(String)
}

private struct AccountChoiceButton: View {
    let title: String
    let subtitle: String
    let icon: AccountChoiceIcon
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                switch icon {
                case .app(let image):
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 34, height: 34)
                case .system(let symbol):
                    Image(systemName: symbol)
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 34, height: 34)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.bold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "arrow.right.circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1.5)
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

private struct OnboardingPlayerControlsPreview: View {
    let layout: PlayerControlLayout

    var body: some View {
        VStack(spacing: layout == .compact ? 8 : 12) {
            if layout == .compact {
                previewSlider
                    .frame(height: 18)
                    .padding(.horizontal, 4)
                controlsRow(includeTimePill: true)
            } else {
                controlsRow(includeTimePill: false)
                scrubberPill
            }
        }
        .padding(.top, 8)
        .frame(height: 230, alignment: layout == .compact ? .bottom : .center)
    }

    private func controlsRow(includeTimePill: Bool) -> some View {
        HStack(spacing: 10) {
            previewCircleButton(symbol: "pause.fill")
            previewVolumePill
            if includeTimePill {
                previewTextPill("0:01 / -11:58")
            }
            Spacer()
            previewCircleButton(symbol: "captions.bubble")
            previewTextPill("1080p")
            previewCircleButton(symbol: "gearshape")
            previewCircleButton(symbol: "rectangle.on.rectangle")
            previewCircleButton(symbol: "arrow.down.left.and.arrow.up.right")
        }
    }

    private var scrubberPill: some View {
        HStack(spacing: 12) {
            Text("0:01")
                .frame(width: 54, alignment: .leading)
            previewSlider
            Text("-11:58")
                .frame(width: 54, alignment: .trailing)
        }
        .font(.caption.weight(.medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 38)
        .onboardingPlayerSurface(shape: Capsule())
    }

    private var previewVolumePill: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 20, height: 22)
            Capsule()
                .fill(Color.white.opacity(0.24))
                .frame(width: 112, height: 6)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(BrandAssets.swiftTubeBlue)
                        .frame(width: 72, height: 6)
                }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
        .onboardingPlayerSurface(shape: Capsule())
    }

    private var previewSlider: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(height: 6)
            HStack(spacing: 0) {
                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            }
            .frame(height: 6)
            HStack(spacing: 0) {
                Capsule()
                    .fill(BrandAssets.swiftTubeBlue)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 18, height: 18)
                    }
                Spacer(minLength: 0)
            }
            .frame(width: 120, height: 6)
            SponsorBlockTimelineOverlayPreview()
        }
    }

    private func previewCircleButton(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 30, height: 30)
            .onboardingPlayerSurface(shape: Circle())
    }

    private func previewTextPill(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .onboardingPlayerSurface(shape: Capsule())
    }
}

private struct SponsorBlockTimelineOverlayPreview: View {
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Capsule()
                    .fill(SponsorBlockCategory.sponsor.tint)
                    .frame(width: proxy.size.width * 0.13, height: 6)
                    .offset(x: proxy.size.width * 0.21)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 6)
    }
}

private extension View {
    func onboardingPlayerSurface<S: Shape>(shape: S) -> some View {
        self.glassEffect(.regular, in: shape)
    }
}

private func stageTitle(_ title: String) -> some View {
    Text(title)
        .font(.system(size: 52, weight: .bold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
}

private func browserAppIcon(for browser: BrowserLoginOption) -> NSImage {
    let bundleIdentifier: String
    switch browser {
    case .chrome:
        bundleIdentifier = "com.google.Chrome"
    case .safari:
        bundleIdentifier = "com.apple.Safari"
    }

    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    switch browser {
    case .chrome:
        return NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
    case .safari:
        return NSImage(systemSymbolName: "safari", accessibilityDescription: nil) ?? NSImage()
    }
}

private extension BrowserLoginOption {
    var appIcon: NSImage {
        browserAppIcon(for: self)
    }

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
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct GridPreview: View {
    let columns: Int

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 8
            let cellWidth = max(1, (proxy.size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
            let cellHeight = min((proxy.size.height - 10) / 2, cellWidth * 0.86)

            VStack(spacing: 10) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<columns, id: \.self) { column in
                            GridPreviewCell(isAccent: (row + column).isMultiple(of: 2))
                                .frame(width: cellWidth, height: cellHeight)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 176)
    }
}

private struct GridPreviewCell: View {
    let isAccent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isAccent ? BrandAssets.swiftTubeBlue.opacity(0.6) : Color.white.opacity(0.20))
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
