import AppKit
import SwiftUI

private enum OnboardingStage: String, CaseIterable, Identifiable, Comparable {
    case welcome = "Welcome"
    case ytDLP = "yt-dlp"
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
        case .ytDLP:
            YTDLPOnboardingStage(
                selection: $settings.ytDLPDependencySource,
                customPath: $settings.ytDLPCustomPath
            )
        case .theme:
            ThemeStage(selection: $settings.appearanceMode)
        case .sponsorBlock:
            SponsorBlockStage(sponsorBlockEnabled: $settings.sponsorBlockEnabled)
        case .controls:
            ControlsStage(controlLayout: $settings.playerControlLayout)
        case .layout:
            LayoutStage(selection: $settings.browseVideoGridPreset)
        case .account:
            AccountStage(
                status: authSession.status,
                isWorking: authSession.isWorking,
                isDiscoveringAccounts: authSession.isDiscoveringAccounts,
                scanningBrowsers: authSession.accountScanningBrowsers,
                discoveredAccounts: authSession.discoveredAccounts,
                errorMessage: authSession.errorMessage,
                discover: {
                    await authSession.discoverAccounts()
                },
                connect: { source in
                    await authSession.connect(using: source)
                },
                continueWithoutAccount: {
                    stepStage()
                }
            )
        case .privacy:
            PrivacyStage(sendWatchProgressToYouTube: $settings.sendWatchProgressToYouTube)
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
                    Color(red: 0.16, green: 0.30, blue: 0.38),
                    Color(red: 0.10, green: 0.16, blue: 0.27),
                    Color(red: 0.05, green: 0.07, blue: 0.12)
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
                Color.black.opacity(0.12)
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

private struct YTDLPOnboardingStage: View {
    @Binding var selection: YTDLPDependencySource
    @Binding var customPath: String
    @State private var snapshot = DependencyDetectionSnapshot.empty
    @State private var isInstalling = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            stageTitle("yt-dlp")

            VStack(spacing: 12) {
                ForEach(YTDLPDependencySource.allCases) { source in
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
                Button("Install yt-dlp") {
                    install()
                }
                .disabled(isInstalling)

                Button("Choose yt-dlp") {
                    if let path = choosePath(allowsDirectories: false) {
                        customPath = path
                        selection = .custom
                    }
                }
            }
            .controlSize(.large)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .task {
            refresh()
        }
    }

    private func status(for source: YTDLPDependencySource) -> String {
        switch source {
        case .nativeSwift:
            return "YouTube only"
        case .system:
            return snapshot.systemYTDLP?.path ?? "Not found"
        case .provisioned:
            return snapshot.provisionedYTDLP?.path ?? "Not installed"
        case .custom:
            return customPath.isEmpty ? "Not selected" : customPath
        }
    }

    private func isEnabled(_ source: YTDLPDependencySource) -> Bool {
        switch source {
        case .nativeSwift:
            return true
        case .system:
            return snapshot.systemYTDLP != nil
        case .provisioned:
            return snapshot.provisionedYTDLP != nil
        case .custom:
            return customPath.isEmpty == false
        }
    }

    private func install() {
        isInstalling = true
        errorMessage = nil
        Task {
            do {
                _ = try await SwiftTubeDependencyManager.installYTDLP()
                let updatedSnapshot = SwiftTubeDependencyManager.detectionSnapshot()
                await MainActor.run {
                    snapshot = updatedSnapshot
                    selection = .provisioned
                    isInstalling = false
                }
            } catch {
                let updatedSnapshot = SwiftTubeDependencyManager.detectionSnapshot()
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    snapshot = updatedSnapshot
                    isInstalling = false
                }
            }
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

            Text("SponsorBlock can detect, show, and skip unnecessary parts of the video such as sponsored segments, self promotion, and more.")
                .font(.title3.weight(.semibold))
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
            .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
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
            .frame(maxWidth: .infinity, minHeight: 310, alignment: .topLeading)
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
    let isDiscoveringAccounts: Bool
    let scanningBrowsers: [BrowserLoginOption]
    let discoveredAccounts: [BrowserAccountDiscoveryResponse]
    let errorMessage: String?
    let discover: () async -> Void
    let connect: (BrowserAccountSource) async -> Bool
    let continueWithoutAccount: () -> Void
    @State private var pendingSource: BrowserAccountSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            stageTitle("Account")

            if status.authenticated {
                SignedInAccountCard(status: status)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 14) {
                    if isDiscoveringAccounts {
                        LoadingStatusView(text: "Looking for accounts...", browsers: scanningBrowsers)
                    } else if discoveredAccounts.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("No signed-in YouTube accounts found")
                                .font(.headline)
                            Button {
                                Task {
                                    await discover()
                                }
                            } label: {
                                Label("Scan Again", systemImage: "arrow.clockwise")
                            }
                            .disabled(isWorking || isDiscoveringAccounts)
                        }
                    } else {
                        ForEach(discoveredAccounts) { account in
                            AccountDiscoveryCard(
                                account: account,
                                isWorking: isWorking,
                                pendingSource: pendingSource
                            ) { source in
                                Task {
                                    pendingSource = source
                                    _ = await connect(source)
                                    pendingSource = nil
                                }
                            }
                        }
                    }

                    AccountChoiceButton(
                        title: "Skip sign in",
                        subtitle: "Continue without a YouTube account.",
                        icon: .system("arrow.right"),
                        isWorking: isWorking,
                        isLoading: false,
                        action: continueWithoutAccount
                    )

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
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await discover()
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

                if let identifier = status.accountIdentifier {
                    Text(identifier)
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
                .font(.system(size: 62, weight: .semibold))
                .foregroundStyle(BrandAssets.swiftTubeBlue)

            Text("Ready")
                .font(.system(size: 52, weight: .bold))
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
        .frame(height: 140, alignment: .bottom)
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
        .font(.system(size: 52, weight: .bold))
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
        .frame(height: 184)
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
