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
    @Namespace private var brandNamespace

    var body: some View {
        ZStack {
            AppAppearanceMode.dark.windowBackgroundColor
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if stage != .welcome {
                    OnboardingHeader(stage: stage, brandNamespace: brandNamespace)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                        .transition(.move(edge: .top).combined(with: .opacity))

                    Divider()
                }

                ScrollView {
                    OnboardingStageContent(
                        stage: stage,
                        settings: settings,
                        brandNamespace: brandNamespace,
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
    let brandNamespace: Namespace.ID

    var body: some View {
        HStack(spacing: 14) {
            OnboardingBrand(hero: false, namespace: brandNamespace)

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
    let brandNamespace: Namespace.ID
    let continueWithoutAccount: () -> Void

    var body: some View {
        VStack {
            switch stage {
            case .welcome:
                WelcomeStage(brandNamespace: brandNamespace)
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
                .buttonStyle(.glass(.regular.interactive()))
                .buttonBorderShape(.capsule)
                .disabled(!canGoBack)

            Spacer()

            if showsPrimaryAction {
                Button(
                    stage == .finished ? "Start Watching" : "Continue",
                    systemImage: stage == .finished ? "play.fill" : "arrow.right",
                    action: onContinue
                )
                .buttonStyle(.glass(.regular.tint(BrandAssets.swiftTubeBlue).interactive()))
                .buttonBorderShape(.capsule)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct WelcomeStage: View {
    let brandNamespace: Namespace.ID

    var body: some View {
        OnboardingBrand(hero: true, namespace: brandNamespace)
            .frame(maxWidth: .infinity, minHeight: 330)
    }
}

private struct OnboardingBrand: View {
    let hero: Bool
    let namespace: Namespace.ID

    var body: some View {
        Group {
            if hero {
                VStack(spacing: 16) {
                    brandImage
                        .frame(width: 86, height: 68)
                    Text("Welcome to SwiftTube")
                        .font(.largeTitle.weight(.bold))
                }
            } else {
                HStack(spacing: 12) {
                    brandImage
                        .frame(width: 28, height: 28)
                    Text("SwiftTube")
                        .font(.headline)
                }
            }
        }
        .matchedGeometryEffect(id: "onboarding-brand", in: namespace)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var brandImage: some View {
        if let logo = BrandAssets.logo {
            Image(nsImage: logo)
                .resizable()
                .scaledToFit()
        } else {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                stageTitle("Choose a look")
                Text("You can create a custom theme later in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 18) {
                OnboardingThemeWindowPreview(theme: selection)

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 8
                ) {
                    ForEach(themes) { theme in
                        OnboardingThemeChoice(
                            theme: theme,
                            isSelected: selection == theme
                        ) {
                            selection = theme
                            usesCustomTheme = false
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct OnboardingThemeWindowPreview: View {
    let theme: AppAppearanceMode

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.windowBackgroundGradient)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Circle().frame(width: 7, height: 7)
                        Capsule().frame(width: 38, height: 6)
                    }
                    ForEach(0..<4, id: \.self) { index in
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 3)
                                .frame(width: 11, height: 11)
                            Capsule()
                                .frame(width: index == 0 ? 54 : 42, height: 6)
                        }
                        .opacity(index == 0 ? 0.9 : 0.48)
                    }
                    Spacer()
                }
                .padding(14)
                .frame(width: 104)
                .background(theme.sidebarBackgroundColor.opacity(0.88))

                VStack(alignment: .leading, spacing: 12) {
                    Capsule()
                        .frame(width: 74, height: 8)
                    HStack(spacing: 10) {
                        ForEach(0..<2, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 7) {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(theme.elevatedBackgroundColor)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                Capsule().frame(height: 6)
                                Capsule().frame(width: 46, height: 5).opacity(0.45)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(16)
            }
            .foregroundStyle(theme.preferredColorScheme == .dark ? Color.white.opacity(0.72) : Color.black.opacity(0.55))
        }
        .frame(width: 410, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
        .animation(.smooth(duration: 0.24), value: theme)
    }
}

private struct OnboardingThemeChoice: View {
    let theme: AppAppearanceMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle()
                    .fill(theme.previewGradient)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                Text(theme.title)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 4)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? BrandAssets.swiftTubeBlue : .secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .background(
                isSelected ? BrandAssets.swiftTubeBlue.opacity(0.12) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SponsorBlockStage: View {
    @Binding var sponsorBlockEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                stageTitle("Skip interruptions")
                Text("SponsorBlock marks community-reported segments on the player timeline.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SponsorBlockOnboardingPreview(isEnabled: sponsorBlockEnabled)

            HStack(spacing: 14) {
                Image(systemName: "forward.end.fill")
                    .font(.headline)
                    .foregroundStyle(SponsorBlockCategory.sponsor.tint)
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.06), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Automatically skip sponsors")
                        .font(.headline)
                    Text(sponsorBlockEnabled ? "Sponsor segments will be skipped." : "Segments stay visible on the timeline.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("Automatically skip sponsors", isOn: $sponsorBlockEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(16)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct SponsorBlockOnboardingPreview: View {
    let isEnabled: Bool

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Label("Player timeline", systemImage: "play.rectangle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Label(isEnabled ? "Auto-skip on" : "Preview only", systemImage: isEnabled ? "checkmark.circle.fill" : "eye")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isEnabled ? SponsorBlockCategory.sponsor.tint : .secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .glassEffect(.regular, in: Capsule())
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.14))
                    Capsule()
                        .fill(Color.primary.opacity(0.72))
                        .frame(width: proxy.size.width * 0.38)
                    Capsule()
                        .fill(SponsorBlockCategory.sponsor.tint)
                        .frame(width: proxy.size.width * 0.18)
                        .offset(x: proxy.size.width * 0.38)
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .frame(width: 15, height: 15)
                        .offset(x: proxy.size.width * (isEnabled ? 0.56 : 0.38) - 7.5)
                }
            }
            .frame(height: 14)

            HStack {
                Text("0:00")
                Spacer()
                Label("Sponsor", systemImage: "scissors")
                    .foregroundStyle(SponsorBlockCategory.sponsor.tint)
                Spacer()
                Text("8:42")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.primary.opacity(0.075), BrandAssets.swiftTubeBlue.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(height: 154)
        .animation(.smooth(duration: 0.25), value: isEnabled)
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
        VStack(alignment: .leading, spacing: 20) {
            stageTitle("Video grid")

            VideoGridPresetSelector(selection: $selection)

            HStack(spacing: 18) {
                GridPreview(columns: selection.columnCount)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 7) {
                    Text(selection.title)
                        .font(.title2.weight(.bold))
                    Text(selection.columnHint)
                        .font(.headline)
                        .foregroundStyle(BrandAssets.swiftTubeBlue)
                    Text("Changes the density of video grids throughout SwiftTube.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 220, alignment: .leading)
            }
            .padding(18)
            .frame(height: 180)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct PrivacyStage: View {
    @Binding var sendWatchProgressToYouTube: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                stageTitle("Watch history")
                Text("SwiftTube always keeps local resume progress.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.title2)
                        .foregroundStyle(BrandAssets.swiftTubeBlue)
                        .frame(width: 34)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sync progress with YouTube")
                            .font(.headline)
                        Text("Keeps YouTube recommendations and history current.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("Sync progress with YouTube", isOn: $sendWatchProgressToYouTube)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(18)

                Divider().padding(.leading, 66)

                HStack(spacing: 14) {
                    Image(systemName: "lock.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Local history")
                            .font(.headline)
                        Text("Resume positions stay on this Mac in either mode.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                }
                .padding(18)
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
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
            let availableRowHeight = max(1, (proxy.size.height - spacing) / 2)
            let heightLimitedWidth = max(1, (availableRowHeight - 17) * 16 / 9)
            let thumbnailWidth = min(maxThumbnailWidth, availableThumbnailWidth, heightLimitedWidth)
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
