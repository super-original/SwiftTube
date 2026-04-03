import SwiftUI

struct VideoCard: View {
    @ObservedObject private var settings = AppSettings.shared
    let video: VideoItem
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                CachedAsyncImage(url: video.thumbnailURL, maxPixelSize: 640) {
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

            if let channel = video.channel {
                Text(channel)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                if let viewCount = video.viewCountText {
                    Text(viewCount)
                }
                if let published = video.publishedTimeText {
                    if video.viewCountText != nil {
                        Text("•")
                    }
                    Text(published)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
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
