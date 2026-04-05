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
    let onRemoveFromWatchHistory: (() -> Void)?

    var body: some View {
        Button(action: onPlay) {
            Label("Play", systemImage: "play.fill")
        }

        if let onPlayFromHere {
            Button(action: onPlayFromHere) {
                Label("Play From Here", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
        }

        Divider()

        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(videoURL.absoluteString, forType: .string)
        } label: {
            Label("Copy Link", systemImage: "link")
        }

        Button {
            NSWorkspace.shared.open(videoURL)
        } label: {
            Label("Open in YouTube", systemImage: "safari")
        }

        if let onAddToWatchLater {
            Divider()
            Button(action: onAddToWatchLater) {
                Label("Add to Watch Later", systemImage: "clock")
            }
        }

        if let onSaveToPlaylist,
           !userPlaylists.isEmpty {
            Menu {
                ForEach(userPlaylists) { playlist in
                    Button {
                        onSaveToPlaylist(playlist.playlistId)
                    } label: {
                        Label(playlist.title, systemImage: "music.note.list")
                    }
                }
            } label: {
                Label("Save to Playlist", systemImage: "text.badge.plus")
            }
        }

        if let onMoveToWatchLater {
            Divider()
            Menu {
                Button(action: onMoveToWatchLater) {
                    Label("Watch Later", systemImage: "clock")
                }
                if let onMoveToPlaylist,
                   !userPlaylists.isEmpty {
                    Divider()
                    ForEach(userPlaylists) { playlist in
                        Button {
                            onMoveToPlaylist(playlist.playlistId)
                        } label: {
                            Label(playlist.title, systemImage: "music.note.list")
                        }
                    }
                }
            } label: {
                Label("Move to", systemImage: "folder")
            }
        } else if let onMoveToPlaylist,
                  !userPlaylists.isEmpty {
            Menu {
                ForEach(userPlaylists) { playlist in
                    Button {
                        onMoveToPlaylist(playlist.playlistId)
                    } label: {
                        Label(playlist.title, systemImage: "music.note.list")
                    }
                }
            } label: {
                Label("Move to Playlist", systemImage: "folder")
            }
        }

        if onRemoveFromCurrentPlaylist != nil || onMoveToTop != nil || onMoveToBottom != nil {
            Divider()
        }

        if let onRemoveFromWatchHistory {
            Button(role: .destructive, action: onRemoveFromWatchHistory) {
                Label {
                    Text("Remove from Watch History")
                        .foregroundStyle(.red)
                } icon: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
            }
        }

        if let onRemoveFromCurrentPlaylist {
            Button(role: .destructive, action: onRemoveFromCurrentPlaylist) {
                Label("Remove from This Playlist", systemImage: "trash")
            }
        }

        if let onMoveToTop {
            Button(action: onMoveToTop) {
                Label("Move to Top", systemImage: "arrow.up.to.line")
            }
        }

        if let onMoveToBottom {
            Button(action: onMoveToBottom) {
                Label("Move to Bottom", systemImage: "arrow.down.to.line")
            }
        }
    }

    private var videoURL: URL {
        var components = URLComponents(string: "https://youtube.com/watch")!
        components.queryItems = [URLQueryItem(name: "v", value: video.id)]
        return components.url!
    }
}
