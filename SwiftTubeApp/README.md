# SwiftTube

SwiftTube is a personal macOS YouTube client built with SwiftUI, an in-process Swift backend layer,
and MPV playback. The app focuses on native desktop browsing, playback, watch-history syncing,
playlist tools, optimistic actions, and a more intentional macOS presentation than the web app.

## Highlights

- Native Home, Search, History, playlist library, and player surfaces
- MPV-based playback with quality switching and storyboard scrubbing
- Optimistic queued mutations for likes, subscriptions, Watch Later, playlists, and history removal
- Unified in-app notification system
- Local resume tracking layered with YouTube watch progress
- SponsorBlock integration for sponsor markers and optional auto-skip
- Customizable browse-card sizing, appearance themes, shortcuts, and playback defaults

## Build and run

```bash
cd SwiftTubeApp && swift build
cd SwiftTubeApp && swift run
```

To build the packaged app bundle:

```bash
cd SwiftTubeApp && zsh build_app.sh
```

The built app bundle lands at `SwiftTubeApp/Build/SwiftTube.app`.

## Architecture

SwiftTube no longer launches a bundled Python or FastAPI server on startup.
Instead, the app uses:

- a SwiftUI macOS shell for the UI
- `SwiftTubeBackend`, an in-process Swift actor that talks to YouTube/InnerTube
- MPVKit/libmpv for all playback
- `yt-dlp` only as an external helper for specific stream/auth tasks

## Documentation

- Changelog: `CHANGELOG.md`
- Architecture guide: `docs/ARCHITECTURE.md`
- Playback guide: `docs/PLAYBACK.md`
- Release process: `docs/RELEASE_PROCESS.md`
