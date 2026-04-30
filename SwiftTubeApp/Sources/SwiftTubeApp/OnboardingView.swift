import AppKit
import SwiftUI

private enum OnboardingStage: String, CaseIterable, Identifiable, Comparable {
    case welcome = "Welcome"
    case theme = "Theme"
    case sponsorBlock = "SponsorBlock"
    case controls = "Controls"
    case grid = "Grid"
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

    var body: some View {
        ZStack {
            onboardingBackground

            VStack(spacing: 0) {
                progressRow
                    .padding(.top, 28)

                Spacer(minLength: 30)

                stageContent
                    .frame(width: 640)
                    .padding(.horizontal, 32)

                Spacer(minLength: 30)

                navigationRow
                    .padding(.bottom, 28)
            }
        }
        .foregroundStyle(.white)
    }

    private var onboardingBackground: some View {
        ZStack {
            settings.windowBackgroundColor
                .ignoresSafeArea()
            LinearGradient(
                colors: [
                    BrandAssets.youtubeRed.opacity(0.28),
                    settings.windowBackgroundColor.opacity(0.2),
                    Color.black.opacity(0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }

    private var progressRow: some View {
        HStack(spacing: 12) {
            ForEach(OnboardingStage.allCases) { item in
                HStack(spacing: 6) {
                    Image(systemName: progressSymbol(for: item))
                        .foregroundStyle(item <= stage ? BrandAssets.youtubeRed : .secondary)

                    if item == stage {
                        Text(item.rawValue)
                            .font(.footnote.weight(.semibold))
                    }
                }
                .foregroundStyle(item <= stage ? .white : .secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.black.opacity(0.28), in: Capsule())
    }

    @ViewBuilder
    private var stageContent: some View {
        switch stage {
        case .welcome:
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 78, height: 78)
                Text("Welcome to SwiftTube.")
                    .font(.system(size: 34, weight: .bold))
            }
        case .theme:
            VStack(alignment: .leading, spacing: 16) {
                stageTitle("Choose a theme")
                Picker("Theme", selection: $settings.appearanceMode) {
                    ForEach(AppAppearanceMode.defaultThemes + AppAppearanceMode.coloredThemes) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.large)
            }
        case .sponsorBlock:
            VStack(alignment: .leading, spacing: 18) {
                stageTitle("SponsorBlock")
                Toggle("Enable SponsorBlock", isOn: $settings.sponsorBlockEnabled)
                    .toggleStyle(.switch)
                Picker("Sponsors", selection: sponsorBehaviorBinding(for: .sponsor)) {
                    ForEach(SponsorBlockBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                Picker("Self promo", selection: sponsorBehaviorBinding(for: .selfpromo)) {
                    ForEach(SponsorBlockBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
            }
        case .controls:
            VStack(alignment: .leading, spacing: 16) {
                stageTitle("Player controls")
                Picker("Layout", selection: $settings.playerControlLayout) {
                    ForEach(PlayerControlLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
            }
        case .grid:
            VStack(alignment: .leading, spacing: 16) {
                stageTitle("Video grid")
                Picker("Grid size", selection: $settings.browseVideoGridPreset) {
                    ForEach(BrowseVideoGridPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.browseVideoGridPreset.columnHint)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        case .account:
            VStack(alignment: .leading, spacing: 16) {
                stageTitle("YouTube session")
                ForEach(BrowserLoginOption.allCases) { browser in
                    Button {
                        Task { await authSession.connect(using: browser) }
                    } label: {
                        HStack {
                            Text(browser.title)
                                .font(.headline)
                            Spacer()
                            if authSession.status.browser == browser.rawValue {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(authSession.isWorking)
                }

                if authSession.isWorking {
                    ProgressView()
                }

                if let errorMessage = authSession.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
        case .finished:
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.green)
                Text("SwiftTube is ready.")
                    .font(.system(size: 30, weight: .bold))
            }
        }
    }

    private var navigationRow: some View {
        HStack(spacing: 12) {
            Button("Back") {
                step(by: -1)
            }
            .disabled(stage == OnboardingStage.allCases.first)

            if stage == .account {
                Button("Skip") {
                    step(by: 1)
                }
            }

            Button(stage == .finished ? "Start Watching" : "Next") {
                if stage == .finished {
                    settings.onboardingCompleted = true
                } else {
                    step(by: 1)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func stageTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 28, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progressSymbol(for item: OnboardingStage) -> String {
        if item < stage { return "checkmark.circle.fill" }
        if item == stage { return "circle.fill" }
        return "circle"
    }

    private func step(by amount: Int) {
        let stages = OnboardingStage.allCases
        guard let index = stages.firstIndex(of: stage) else { return }
        let nextIndex = min(max(index + amount, 0), stages.count - 1)
        withAnimation(.snappy(duration: 0.2, extraBounce: 0)) {
            stage = stages[nextIndex]
        }
    }

    private func sponsorBehaviorBinding(for category: SponsorBlockCategory) -> Binding<SponsorBlockBehavior> {
        Binding(
            get: { settings.sponsorBlockBehavior(for: category) },
            set: { settings.setSponsorBlockBehavior($0, for: category) }
        )
    }
}
