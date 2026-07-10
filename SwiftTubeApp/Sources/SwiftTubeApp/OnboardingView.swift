import AppKit
import SwiftUI

private enum OnboardingStage: String, CaseIterable, Identifiable, Comparable {
    case welcome = "Welcome"
    case theme = "Theme"
    case sponsorBlock = "SponsorBlock"
    case controls = "Controls"
    case layout = "Layout"
    case account = "Account"
    case privacy = "Privacy"
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

    var body: some View {
        ZStack {
            AppAppearanceMode.dark.windowBackgroundColor
                .ignoresSafeArea()

            VStack(spacing: 0) {
                OnboardingHeader(stage: stage)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)

                Divider()

                ScrollView {
                    OnboardingStageContent(
                        stage: stage,
                        settings: settings,
                        continueWithoutAccount: { stepStage() }
                    )
                    .id(stage)
                    .padding(28)
                    .frame(maxWidth: .infinity, minHeight: 390, alignment: .center)
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
                }

                Divider()

                OnboardingFooter(
                    stage: stage,
                    canGoBack: stage != .welcome,
                    showsPrimaryAction: shouldShowPrimaryButton,
                    onBack: { stepStage(by: -1) },
                    onContinue: continueOnboarding
                )
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .frame(maxWidth: 820, maxHeight: 610)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
            .padding(28)
        }
        .foregroundStyle(.primary)
        .preferredColorScheme(.dark)
    }

    private func continueOnboarding() {
        if stage == .finished {
            withAnimation(.easeOut(duration: 0.2)) {
                settings.onboardingCompleted = true
            }
        } else {
            stepStage()
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

private struct OnboardingHeader: View {
    let stage: OnboardingStage

    var body: some View {
        HStack(spacing: 14) {
            if let logo = BrandAssets.logo {
                Image(nsImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
            }

            Text("SwiftTube")
                .font(.headline)

            Spacer()

            OnboardingProgressStrip(stage: stage)
        }
    }
}

private struct OnboardingProgressStrip: View {
    let stage: OnboardingStage

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStage.allCases) { item in
                Capsule()
                    .fill(item <= stage ? BrandAssets.swiftTubeBlue : Color.secondary.opacity(0.24))
                    .frame(width: item == stage ? 24 : 10, height: 5)
            }

            Text(stage.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 78, alignment: .trailing)
        }
        .animation(.smooth(duration: 0.22), value: stage)
    }
}

private struct OnboardingStageContent: View {
    let stage: OnboardingStage
    @ObservedObject var settings: AppSettings
    let continueWithoutAccount: () -> Void

    var body: some View {
        VStack {
            switch stage {
            case .welcome:
                WelcomeStage()
            case .theme:
                ThemeStage(
                    selection: $settings.appearanceMode,
                    usesCustomTheme: $settings.usesCustomTheme
                )
            case .sponsorBlock:
                SponsorBlockStage(sponsorBlockEnabled: $settings.sponsorBlockEnabled)
            case .controls:
                ControlsStage(controlLayout: $settings.playerControlLayout)
            case .layout:
                LayoutStage(selection: $settings.browseVideoGridPreset)
            case .account:
                AccountStage(continueWithoutAccount: continueWithoutAccount)
            case .privacy:
                PrivacyStage(sendWatchProgressToYouTube: $settings.sendWatchProgressToYouTube)
            case .finished:
                FinishedStage()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct OnboardingFooter: View {
    let stage: OnboardingStage
    let canGoBack: Bool
    let showsPrimaryAction: Bool
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        HStack {
            Button("Back", systemImage: "chevron.left", action: onBack)
                .disabled(!canGoBack)

            Spacer()

            if showsPrimaryAction {
                Button(
                    stage == .finished ? "Start Watching" : "Continue",
                    systemImage: stage == .finished ? "play.fill" : "arrow.right",
                    action: onContinue
                )
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct WelcomeStage: View {
    var body: some View {
        VStack(spacing: 12) {
            if let logo = BrandAssets.logo {
                Image(nsImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 76, height: 58)
            } else {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 58, height: 58)
            }

            Text("SwiftTube")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)

            Text("Set up playback, appearance, and YouTube access.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MPVKitOnboardingStage: View {
    @Binding var selection: MPVKitDependencySource
    @Binding var customPath: String
    @State private var snapshot = DependencyDetectionSnapshot.empty

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            stageTitle("MPVKit")

            VStack(spacing: 12) {
                ForEach(MPVKitDependencySource.allCases) { source in
                    OnboardingDependencyChoice(
                        title: source.title,
                        value: status(for: source),
                        isSelected: selection == source,
                        isEnabled: isEnabled(source),
                        action: {
                            selection = source
                        }
                    )
                }
            }

            HStack(spacing: 12) {
                Button("Use bundled MPVKit") {
                    selection = .provisioned
                }

                Button("Choose MPVKit") {
                    if let path = choosePath(allowsDirectories: true) {
                        customPath = path
                        selection = .custom
                    }
                }
            }
            .controlSize(.large)
        }
        .task {
            refresh()
        }
    }

    private func status(for source: MPVKitDependencySource) -> String {
        switch source {
        case .system:
            return snapshot.systemMPVKit?.path ?? "Not found"
        case .provisioned:
            return "\(SwiftTubeDependencyManager.requiredMPVKitVersion) bundled"
        case .custom:
            return customPath.isEmpty ? "Not selected" : customPath
        }
    }

    private func isEnabled(_ source: MPVKitDependencySource) -> Bool {
        switch source {
        case .system:
            return snapshot.systemMPVKit != nil
        case .provisioned:
            return true
        case .custom:
            return customPath.isEmpty == false
        }
    }

    private func refresh() {
        Task.detached(priority: .utility) {
            let updatedSnapshot = SwiftTubeDependencyManager.detectionSnapshot()
            await MainActor.run {
                snapshot = updatedSnapshot
            }
        }
    }
}

private struct OnboardingDependencyChoice: View {
    let title: String
    let value: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? BrandAssets.swiftTubeBlue : .secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.bold))
                    Text(value)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isSelected ? BrandAssets.swiftTubeBlue.opacity(0.75) : Color.white.opacity(0.08), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false)
        .opacity(isEnabled ? 1 : 0.55)
    }
}

private struct ThemeStage: View {
    @Binding var selection: AppAppearanceMode
    @Binding var usesCustomTheme: Bool

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
                        usesCustomTheme = false
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
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.previewGradient)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.white.opacity(0.8))
                            .frame(width: 9, height: 9)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.55))
                            .frame(width: 58, height: 8)
                    }
                    .padding(10)
                }
                .frame(height: 66)

                HStack {
                    Text(theme.title)
                        .font(.headline)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? BrandAssets.swiftTubeBlue : .secondary)
                }
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
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

            Text("Detect, mark, and skip sponsored segments and other interruptions.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                    .font(.body.weight(.semibold))

                Text(title)
                    .font(.body.weight(.semibold))
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? BrandAssets.swiftTubeBlue.opacity(0.75) : Color.white.opacity(0.08), lineWidth: 1.5)
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
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
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
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
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
                        .font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? BrandAssets.swiftTubeBlue : .secondary)
                }

                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? BrandAssets.swiftTubeBlue.opacity(0.75) : Color.white.opacity(0.08), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AccountStage: View {
    @EnvironmentObject private var authSession: AuthSessionModel
    let continueWithoutAccount: () -> Void
    @State private var isWebSignInPresented = false

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(BrandAssets.swiftTubeBlue)

                Text("Connect YouTube")
                    .font(.title.weight(.bold))

                Text("Sign in with Google for subscriptions, playlists, history, and personalized recommendations.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }

            if authSession.status.authenticated {
                SignedInAccountCard(status: authSession.status)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button {
                    authSession.clearError()
                    isWebSignInPresented = true
                } label: {
                    Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(authSession.isWorking)

                Button("Continue without an account", action: continueWithoutAccount)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .sheet(isPresented: $isWebSignInPresented) {
            YouTubeWebLoginSheet {
                isWebSignInPresented = false
            }
            .environmentObject(authSession)
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
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
            } else {
                accountFallbackIcon
                    .frame(width: 64, height: 64)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Signed in to \(status.displayName?.nilIfBlank ?? status.browserLabel ?? "YouTube")")
                    .font(.headline)
                    .lineLimit(2)

                if let identifier = status.accountIdentifier {
                    Text(identifier)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(status.browserLabel ?? "YouTube")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(BrandAssets.swiftTubeBlue.opacity(0.65), lineWidth: 1.5)
        )
    }

    private var accountFallbackIcon: some View {
        Image(systemName: "person.crop.circle.badge.checkmark")
            .font(.system(size: 44, weight: .semibold))
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
    let isLoading: Bool
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

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.right.circle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
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
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(BrandAssets.swiftTubeBlue)

            Text("Ready")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
        }
    }
}

private struct OnboardingPlayerControlsPreview: View {
    let layout: PlayerControlLayout

    var body: some View {
        VStack(spacing: 10) {
            if layout == .compact {
                previewSlider
                compactControlsRow
            } else {
                standardControlsRow
                scrubberPill
            }
        }
        .padding(12)
        .frame(height: 104, alignment: .bottom)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.20))
        )
    }

    private var compactControlsRow: some View {
        HStack(spacing: 10) {
            previewCircleButton(symbol: "pause.fill")
            previewVolumePill
            previewTextPill("0:01", width: 52)
            Spacer()
            previewCircleButton(symbol: "captions.bubble")
            previewCircleButton(symbol: "gearshape")
            previewCircleButton(symbol: "arrow.down.left.and.arrow.up.right")
        }
    }

    private var standardControlsRow: some View {
        HStack(spacing: 10) {
            previewCircleButton(symbol: "pause.fill")
            previewVolumePill
            Spacer()
            previewCircleButton(symbol: "captions.bubble")
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
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(playerControlFill, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    private var previewVolumePill: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 16, height: 20)
            Capsule()
                .fill(Color.white.opacity(0.24))
                .frame(width: 54, height: 5)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(BrandAssets.swiftTubeBlue)
                        .frame(width: 34, height: 5)
                }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
        .background(playerControlFill, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    private var previewSlider: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.20))
                    .frame(height: 6)
                Capsule()
                    .fill(BrandAssets.swiftTubeBlue)
                    .frame(width: proxy.size.width * 0.42, height: 6)
                SponsorBlockTimelineOverlayPreview()
                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .offset(x: max(0, proxy.size.width * 0.42 - 9))
            }
        }
        .frame(height: 20)
    }

    private func previewCircleButton(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 30, height: 30)
            .background(playerControlFill, in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    private func previewTextPill(_ text: String, width: CGFloat? = nil) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, width == nil ? 10 : 0)
            .frame(width: width)
            .frame(minHeight: 30)
            .background(playerControlFill, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    private var playerControlFill: Color {
        Color(red: 0.06, green: 0.09, blue: 0.15).opacity(0.82)
    }
}

private struct SponsorBlockTimelineOverlayPreview: View {
    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(SponsorBlockCategory.sponsor.tint)
                .frame(width: proxy.size.width * 0.13, height: 6)
                .offset(x: proxy.size.width * 0.22)
        }
        .frame(height: 6)
    }
}

private func stageTitle(_ title: String) -> some View {
    Text(title)
        .font(.title.weight(.bold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
}

@MainActor
private func choosePath(allowsDirectories: Bool) -> String? {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = allowsDirectories
    panel.resolvesAliases = true
    return panel.runModal() == .OK ? panel.url?.path : nil
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct GridPreview: View {
    let columns: Int
    private let spacing: CGFloat = 8

    private var maxThumbnailWidth: CGFloat {
        switch columns {
        case 4:
            return 76
        case 3:
            return 104
        default:
            return 126
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let availableThumbnailWidth = max(1, (proxy.size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
            let thumbnailWidth = min(maxThumbnailWidth, availableThumbnailWidth)
            let cellHeight = thumbnailWidth * 9 / 16 + 17
            let contentWidth = thumbnailWidth * CGFloat(columns) + CGFloat(columns - 1) * spacing

            VStack(spacing: 8) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<columns, id: \.self) { column in
                            GridPreviewCell(isAccent: (row + column).isMultiple(of: 2), thumbnailWidth: thumbnailWidth)
                                .frame(width: thumbnailWidth, height: cellHeight)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: contentWidth, alignment: .leading)
        }
        .frame(height: 126)
    }
}

private struct GridPreviewCell: View {
    let isAccent: Bool
    let thumbnailWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: max(4, min(7, thumbnailWidth * 0.04)), style: .continuous)
                .fill(isAccent ? BrandAssets.swiftTubeBlue.opacity(0.6) : Color.white.opacity(0.20))
                .frame(width: thumbnailWidth, height: thumbnailWidth * 9 / 16)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.38))
                .frame(width: thumbnailWidth, height: 5)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.18))
                .frame(width: thumbnailWidth * 0.58, height: 4)
        }
    }
}
