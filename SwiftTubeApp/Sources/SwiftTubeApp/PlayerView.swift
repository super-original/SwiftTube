import AVKit
import SwiftUI

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

struct PlayerScreen: View {
    let video: VideoItem
    @StateObject private var viewModel: PlayerViewModel
    @State private var isDescriptionExpanded = false
    @EnvironmentObject private var navigation: AppNavigationModel

    init(video: VideoItem) {
        self.video = video
        _viewModel = StateObject(wrappedValue: PlayerViewModel(video: video))
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                contentLayout(for: proxy.size.width)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(
                Color(NSColor.windowBackgroundColor)
                    .ignoresSafeArea()
            )
        }
        .navigationTitle("")
        .task {
            viewModel.load()
        }
        .textSelection(.enabled)
    }
}

private extension PlayerScreen {
    var playback: VideoPlayback? {
        viewModel.playback
    }

    var displayTitle: String {
        playback?.title ?? video.title
    }

    var displayChannel: String? {
        playback?.channel ?? video.channel
    }

    var recommendations: [VideoItem] {
        playback?.recommendations ?? []
    }

    var comments: [CommentItem] {
        playback?.comments ?? []
    }

    var commentHeaderText: String {
        if let count = playback?.commentCountText, !count.isEmpty {
            return "\(count) comments"
        }
        return "Comments"
    }

    var playbackBadgeText: String? {
        if viewModel.isUsingAdaptivePlayback,
           let label = playback?.preferredVideoStream?.qualityLabel {
            return "Adaptive \(label)"
        }
        return viewModel.activeStream?.qualityLabel
            ?? playback?.preferredMuxedStream?.qualityLabel
            ?? playback?.bestStream?.qualityLabel
    }

    var metadataPills: [String] {
        var items: [String] = []
        if let views = playback?.viewCountText ?? video.viewCountText {
            items.append(views)
        }
        if let likes = playback?.likeCountText {
            items.append("\(likes) likes")
        }
        if let published = playback?.publishedDateText ?? playback?.publishedTimeText ?? video.publishedTimeText {
            items.append(published)
        }
        if let duration = playback?.durationText ?? video.durationText {
            items.append(duration)
        }
        if let badge = playbackBadgeText {
            items.append(badge)
        }
        return items
    }

    func contentLayout(for width: CGFloat) -> some View {
        let isWideLayout = width >= 1_280
        let railWidth = min(max(width * 0.28, 320), 400)

        return Group {
            if isWideLayout {
                HStack(alignment: .top, spacing: 24) {
                    mainColumn
                    recommendationsColumn
                        .frame(width: railWidth)
                }
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    mainColumn
                    recommendationsColumn
                }
            }
        }
    }

    var mainColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            playerSurface
            headerSection
            descriptionSection
            commentsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var playerSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.black.opacity(0.88))

            if viewModel.isLoading {
                VStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(1.15)
                    Text("Loading video...")
                        .font(.headline)
                }
                .tint(.white)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 14) {
                    Image(systemName: "play.slash.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(error)
                        .foregroundStyle(.white.opacity(0.9))
                    Button("Retry") {
                        viewModel.load()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(24)
            } else if let player = viewModel.player {
                PlayerView(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .onDisappear {
                        viewModel.stop()
                        player.pause()
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.18), radius: 22, y: 10)
        .overlay(alignment: .topLeading) {
            if let badge = playbackBadgeText {
                QualityBadge(text: badge, isAdaptive: viewModel.isUsingAdaptivePlayback)
                    .padding(16)
            }
        }
    }

    var headerSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(displayTitle)
                .font(.system(size: 30, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 18) {
                ChannelSummary(
                    avatarURL: playback?.channelAvatarURL,
                    channel: displayChannel,
                    subscriberCount: playback?.subscriberCountText
                )

                Spacer(minLength: 12)

                if let publishedTime = playback?.publishedTimeText, !publishedTime.isEmpty {
                    Text(publishedTime)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !metadataPills.isEmpty {
                FlexiblePillRow(items: metadataPills)
            }
        }
    }

    var descriptionSection: some View {
        DetailCard(title: "Description") {
            VStack(alignment: .leading, spacing: 16) {
                if let description = playback?.description, !description.isEmpty {
                    ExpandableDescription(
                        text: description,
                        isExpanded: $isDescriptionExpanded
                    )
                } else {
                    Text("No description available for this video yet.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var commentsSection: some View {
        DetailCard(title: commentHeaderText) {
            VStack(alignment: .leading, spacing: 18) {
                if comments.isEmpty {
                    Text("Comments aren’t available for this video right now.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(comments) { comment in
                        CommentRow(comment: comment)
                        if comment.id != comments.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    var recommendationsColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Up next")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                if let badge = playbackBadgeText, !recommendations.isEmpty {
                    Text(badge)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .frame(height: 108)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(recommendations, id: \.id) { relatedVideo in
                        Button {
                            navigation.showVideo(relatedVideo)
                        } label: {
                            RecommendationRow(video: relatedVideo)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

private struct ChannelSummary: View {
    let avatarURL: URL?
    let channel: String?
    let subscriberCount: String?

    var body: some View {
        HStack(spacing: 14) {
            CachedAsyncImage(url: avatarURL) {
                Circle()
                    .fill(Color.gray.opacity(0.28))
                    .overlay(
                        Image(systemName: "person.fill")
                            .foregroundStyle(.secondary)
                    )
            }
            .frame(width: 54, height: 54)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(channel ?? "Unknown channel")
                    .font(.headline)
                if let subscriberCount, !subscriberCount.isEmpty {
                    Text(subscriberCount)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct FlexiblePillRow: View {
    let items: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color(NSColor.controlBackgroundColor))
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ExpandableDescription: View {
    let text: String
    @Binding var isExpanded: Bool

    private var shouldShowToggle: Bool {
        text.count > 260
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(isExpanded ? nil : 5)
                .fixedSize(horizontal: false, vertical: true)

            if shouldShowToggle {
                Button(isExpanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct CommentRow: View {
    let comment: CommentItem

    private var footerItems: [String] {
        var items: [String] = []
        if let likeCount = comment.likeCountText, !likeCount.isEmpty {
            items.append("\(likeCount) likes")
        }
        if let replyCount = comment.replyCountText, !replyCount.isEmpty {
            items.append("\(replyCount) replies")
        }
        return items
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CachedAsyncImage(url: comment.avatarURL) {
                Circle()
                    .fill(Color.gray.opacity(0.28))
                    .overlay(
                        Image(systemName: "person.fill")
                            .foregroundStyle(.secondary)
                    )
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(comment.author)
                        .font(.subheadline.weight(.semibold))
                    if let published = comment.publishedTimeText, !published.isEmpty {
                        Text(published)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let pinned = comment.pinnedText, !pinned.isEmpty {
                        Text(pinned)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                    }
                }

                Text(comment.body)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                if !footerItems.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(footerItems, id: \.self) { item in
                            Text(item)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RecommendationRow: View {
    let video: VideoItem

    private var statsLine: String {
        let parts = [video.channel, video.viewCountText, video.publishedTimeText]
            .compactMap { $0 }
        return parts.joined(separator: " • ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: video.thumbnailURL) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.secondary)
                        )
                }
                .frame(width: 210)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                if let duration = video.durationText {
                    Text(duration)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.74))
                        )
                        .foregroundStyle(.white)
                        .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(video.title)
                    .font(.headline)
                    .lineLimit(2)
                if !statsLine.isEmpty {
                    Text(statsLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

private struct QualityBadge: View {
    let text: String
    let isAdaptive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isAdaptive ? Color.red : Color.orange)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
    }
}
