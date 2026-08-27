# SwiftTube

SwiftTube is a personal, native YouTube client for macOS. It is built with SwiftUI and designed around a focused desktop experience for browsing, watching, and managing YouTube content without wrapping the website.

## Highlights

- Personalized Home, search, history, channels, and playlists
- High-quality MPV playback with quality selection, subtitles, and scrub previews
- Likes, subscriptions, Watch Later, playlist management, and watch-progress syncing
- SponsorBlock markers and optional automatic sponsor skipping
- Native macOS interface with configurable appearance and playback preferences

Playback URLs and metadata are resolved in-process by a native Swift YouTube extractor based on ongoing work and research from [yt-dlp](https://github.com/yt-dlp/yt-dlp). SwiftTube does not bundle Python or run a separate backend service.

## Build

SwiftTube requires macOS 26 or later and a current Xcode toolchain.

```bash
cd SwiftTubeApp
swift run
```

To create the packaged app:

```bash
cd SwiftTubeApp
zsh build_app.sh
```

The resulting bundle is written to `SwiftTubeApp/Build/SwiftTube.app`.

## Documentation

More detail is available in the [architecture](docs/ARCHITECTURE.md), [playback](docs/PLAYBACK.md), and [release process](docs/RELEASE_PROCESS.md) guides.

SwiftTube is an unofficial personal project and is not affiliated with YouTube or Google.
