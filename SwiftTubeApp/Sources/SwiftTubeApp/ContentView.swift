import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = HomeViewModel()
    @EnvironmentObject private var backend: BackendManager
    @EnvironmentObject private var navigation: AppNavigationModel

    private let columns = [
        GridItem(.adaptive(minimum: 240), spacing: 20)
    ]

    var body: some View {
        ZStack {
            backgroundView

            VStack(spacing: 0) {
                AppChrome(
                    backendState: backend.state,
                    canGoBack: navigation.canGoBack,
                    canGoForward: navigation.canGoForward
                ) {
                    navigation.goBack()
                } onForward: {
                    navigation.goForward()
                } onHome: {
                    navigation.showHome()
                } onRefresh: {
                    viewModel.reload()
                }

                Divider()

                currentScreen
            }
        }
        .overlay(backendOverlay)
        .task(id: backend.state) {
            if backend.isRunning {
                viewModel.reload()
            }
        }
    }
}

private extension ContentView {
    var backgroundView: some View {
        Color(NSColor.windowBackgroundColor)
            .ignoresSafeArea()
    }

    @ViewBuilder
    var currentScreen: some View {
        switch navigation.currentRoute {
        case .home:
            homeScreen
        case .video(let video):
            PlayerScreen(video: video)
        }
    }

    var homeScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerView

                if let notice = viewModel.notice {
                    NoticeBanner(text: notice)
                }

                contentView
            }
            .padding(24)
        }
    }

    var headerView: some View {
        GroupBox {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your feed, your player, no browser clutter.")
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    Text("Fast local backend, richer watch pages, and room for your own UX.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
                StatusPill(state: backend.state)
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    var contentView: some View {
        if viewModel.videos.isEmpty {
            if viewModel.isLoading {
                placeholderGrid
            } else if let error = viewModel.errorMessage {
                EmptyStateView(
                    title: "Couldn’t load recommendations",
                    message: error,
                    actionTitle: "Try Again"
                ) {
                    viewModel.reload()
                }
            } else {
                EmptyStateView(
                    title: "No videos yet",
                    message: "The feed is empty. Try refreshing once the backend is running.",
                    actionTitle: "Refresh"
                ) {
                    viewModel.reload()
                }
            }
        } else {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(viewModel.videos, id: \.id) { video in
                    Button {
                        navigation.showVideo(video)
                    } label: {
                        VideoCard(video: video)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        viewModel.loadMoreIfNeeded(currentVideo: video)
                    }
                }
            }

            if viewModel.isLoading {
                ProgressView("Loading more...")
                    .padding(.top, 16)
            }
        }
    }

    var placeholderGrid: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(0..<8, id: \.self) { _ in
                PlaceholderCard()
            }
        }
    }

    @ViewBuilder
    var backendOverlay: some View {
        switch backend.state {
        case .idle, .preparing, .installing, .starting:
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                    Text(backend.statusMessage)
                        .font(.headline)
                    if let logLine = backend.lastLogLine {
                        Text(logLine)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(NSColor.windowBackgroundColor))
                        .shadow(radius: 12)
                )
            }
        case .failed(let message):
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    Text("Backend Error")
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                    if let logLine = backend.lastLogLine {
                        Text(logLine)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Button("Retry") {
                        backend.retry()
                    }
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(NSColor.windowBackgroundColor))
                        .shadow(radius: 12)
                )
            }
        case .running:
            EmptyView()
        }
    }
}

private struct AppChrome: View {
    let backendState: BackendState
    let canGoBack: Bool
    let canGoForward: Bool
    let onBack: () -> Void
    let onForward: () -> Void
    let onHome: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            chromeButton(systemImage: "chevron.left", enabled: canGoBack, action: onBack)
            chromeButton(systemImage: "chevron.right", enabled: canGoForward, action: onForward)

            Button(action: onHome) {
                HStack(spacing: 12) {
                    if let logo = BrandAssets.logo {
                        Image(nsImage: logo)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 34, height: 24)
                    }
                    Text("SwiftTube")
                        .font(.title3.weight(.semibold))
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)

            StatusPill(state: backendState)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.thinMaterial)
    }

    private func chromeButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .background(
            Circle()
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }
}

private struct StatusPill: View {
    let state: BackendState

    private var label: String {
        switch state {
        case .running:
            return "Online"
        case .failed:
            return "Error"
        case .installing:
            return "Installing"
        case .starting:
            return "Starting"
        case .preparing:
            return "Preparing"
        case .idle:
            return "Idle"
        }
    }

    private var color: Color {
        switch state {
        case .running:
            return Color.green
        case .failed:
            return Color.red
        default:
            return Color.orange
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

private struct EmptyStateView: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(title)
                .font(.title2)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button(actionTitle) {
                action()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

private struct NoticeBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle")
                .foregroundColor(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

private struct PlaceholderCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.2))
                .aspectRatio(16 / 9, contentMode: .fit)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.25))
                .frame(height: 16)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.18))
                .frame(height: 12)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.18))
                .frame(height: 12)
                .padding(.trailing, 80)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .redacted(reason: .placeholder)
    }
}
