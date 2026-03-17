import AVKit
import SwiftUI

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
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

    init(video: VideoItem) {
        self.video = video
        _viewModel = StateObject(wrappedValue: PlayerViewModel(video: video))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(NSColor.black).opacity(0.05))
                        if viewModel.isLoading {
                            ProgressView("Loading video...")
                        } else if let error = viewModel.errorMessage {
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 32))
                                    .foregroundColor(.secondary)
                                Text(error)
                                    .foregroundColor(.secondary)
                                Button("Retry") {
                                    viewModel.load()
                                }
                            }
                        } else if let player = viewModel.player {
                            PlayerView(player: player)
                                .onDisappear {
                                    player.pause()
                                }
                        }
                    }
                    .frame(minHeight: 420)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(video.title)
                        .font(.title)
                        .fontWeight(.semibold)

                    if let channel = video.channel {
                        Text(channel)
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 8) {
                        if let viewCount = video.viewCountText {
                            Text(viewCount)
                        }
                        if let published = video.publishedTimeText {
                            Text("•")
                            Text(published)
                        }
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
            }
            .padding(24)
        }
        .navigationTitle("Now Playing")
        .task {
            viewModel.load()
        }
    }
}
