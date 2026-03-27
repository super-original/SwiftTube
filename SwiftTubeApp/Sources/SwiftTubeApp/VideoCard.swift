import SwiftUI

struct VideoCard: View {
    let video: VideoItem

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
                .font(.headline)
                .lineLimit(2)

            if let channel = video.channel {
                Text(channel)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
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
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}
