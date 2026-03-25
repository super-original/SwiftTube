import AppKit
import SwiftUI

struct VideoContextMenuContent: View {
    let video: VideoItem
    let userPlaylists: [PlaylistSummary]
    let onPlay: () -> Void
    let onPlayFromHere: (() -> Void)?
    let onAddToWatchLater: (() -> Void)?
    let onSaveToPlaylist: ((String) -> Void)?
    let onMoveToPlaylist: ((String) -> Void)?
    let onMoveToWatchLater: (() -> Void)?
    let onRemoveFromCurrentPlaylist: (() -> Void)?
    let onMoveToTop: (() -> Void)?
    let onMoveToBottom: (() -> Void)?

    var body: some View {
        Button("Play", action: onPlay)

        if let onPlayFromHere {
            Button("Play From Here", action: onPlayFromHere)
        }

        Divider()

        Button("Copy Link") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(videoURL.absoluteString, forType: .string)
        }

        Button("Open in YouTube") {
            NSWorkspace.shared.open(videoURL)
        }

        if let onAddToWatchLater {
            Divider()
            Button("Add to Watch Later", action: onAddToWatchLater)
        }

        if let onSaveToPlaylist,
           !userPlaylists.isEmpty {
            Menu("Save to Playlist") {
                ForEach(userPlaylists) { playlist in
                    Button(playlist.title) {
                        onSaveToPlaylist(playlist.playlistId)
                    }
                }
            }
        }

        if let onMoveToWatchLater {
            Divider()
            Menu("Move to") {
                Button("Watch Later", action: onMoveToWatchLater)
                if let onMoveToPlaylist,
                   !userPlaylists.isEmpty {
                    Divider()
                    ForEach(userPlaylists) { playlist in
                        Button(playlist.title) {
                            onMoveToPlaylist(playlist.playlistId)
                        }
                    }
                }
            }
        } else if let onMoveToPlaylist,
                  !userPlaylists.isEmpty {
            Menu("Move to Playlist") {
                ForEach(userPlaylists) { playlist in
                    Button(playlist.title) {
                        onMoveToPlaylist(playlist.playlistId)
                    }
                }
            }
        }

        if onRemoveFromCurrentPlaylist != nil || onMoveToTop != nil || onMoveToBottom != nil {
            Divider()
        }

        if let onRemoveFromCurrentPlaylist {
            Button("Remove from This Playlist", role: .destructive, action: onRemoveFromCurrentPlaylist)
        }

        if let onMoveToTop {
            Button("Move to Top", action: onMoveToTop)
        }

        if let onMoveToBottom {
            Button("Move to Bottom", action: onMoveToBottom)
        }
    }

    private var videoURL: URL {
        var components = URLComponents(string: "https://youtube.com/watch")!
        components.queryItems = [URLQueryItem(name: "v", value: video.id)]
        return components.url!
    }
}
