import SwiftUI

struct VideoCard: View {
    @ObservedObject private var settings = AppSettings.shared
    let video: VideoItem
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: video.thumbnailURL, maxPixelSize: 480) {
                    ZStack {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.gray.opacity(0.6))
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottom) {
                    VideoThumbnailProgressBars(progress: video.progress, cornerRadius: 12)
                }

                if let duration = video.durationText {
                    Text(duration)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.65))
                        )
                        .foregroundColor(.white)
                        .padding(8)
                }
            }

            Text(video.title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(2)
                .foregroundStyle(.primary)

            VideoChannelIdentityLine(
                avatarURL: video.channelAvatarURL,
                channelID: video.channelId,
                channel: video.channel,
                avatarSize: 22,
                font: .system(size: 14, weight: .medium)
            )

            VideoStatsMetadataLine(
                viewCountText: video.viewCountText,
                publishedTimeText: video.publishedTimeText,
                font: .system(size: 14, weight: .medium)
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isHovered ? settings.hoverCardBackgroundColor : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .scaleEffect(isHovered ? 1.008 : 1)
        .offset(y: isHovered ? -1 : 0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

struct VideoThumbnailProgressBars: View {
    let progress: VideoProgress?
    let cornerRadius: CGFloat

    private let localProgressColor = Color(red: 0.44, green: 0.80, blue: 0.98)
    private let youtubeProgressColor = Color(red: 0.93, green: 0.13, blue: 0.13)

    var body: some View {
        GeometryReader { proxy in
            if let bar = activeBar {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.black.opacity(0.34))

                    Rectangle()
                        .fill(bar.fill)
                        .frame(width: max(proxy.size.width * bar.fraction, 0))
                }
                .frame(height: 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .allowsHitTesting(false)
    }

    private var activeBar: (fraction: Double, fill: Color)? {
        let localFraction = progress?.normalizedLocalFraction ?? 0
        if localFraction > 0 {
            return (localFraction, localProgressColor)
        }

        let youtubeFraction = progress?.normalizedYouTubeFraction ?? 0
        if youtubeFraction > 0 {
            return (youtubeFraction, youtubeProgressColor)
        }

        return nil
    }
}

struct VideoChannelIdentityLine: View {
    let avatarURL: URL?
    let channelID: String?
    let channel: String?
    let avatarSize: CGFloat
    let font: Font

    var body: some View {
        HStack(spacing: 8) {
            ChannelAvatarView(
                avatarURL: avatarURL,
                channelID: channelID,
                avatarSize: avatarSize
            )

            Text(channel ?? "Unknown channel")
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct ChannelAvatarView: View {
    let avatarURL: URL?
    let channelID: String?
    let avatarSize: CGFloat

    @StateObject private var loader = ChannelAvatarLoader()

    private var taskKey: String {
        "\(channelID ?? "none")|\(avatarURL?.absoluteString ?? "none")"
    }

    var body: some View {
        CachedAsyncImage(
            url: loader.resolvedURL ?? avatarURL,
            maxPixelSize: Int(avatarSize * 3),
            contentMode: .fill
        ) {
            Circle()
                .fill(Color.gray.opacity(0.24))
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: avatarSize * 0.46, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.8))
                )
        }
        .frame(width: avatarSize, height: avatarSize)
        .clipShape(Circle())
        .task(id: taskKey) {
            loader.load(channelID: channelID, fallbackURL: avatarURL)
        }
    }
}

struct VideoStatsMetadataLine: View {
    let viewCountText: String?
    let publishedTimeText: String?
    let font: Font

    var body: some View {
        let parts = [viewCountText, publishedTimeText].compactMap { value -> String? in
            guard let value, value.isEmpty == false else { return nil }
            return value
        }

        HStack(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, value in
                if index > 0 {
                    Text("•")
                }
                Text(value)
                    .lineLimit(1)
            }
        }
        .font(font)
        .foregroundStyle(.secondary)
    }
}
