# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is SwiftTube

SwiftTube is a personal macOS YouTube client. It has a Swift/SwiftUI frontend that embeds and auto-manages a Python (FastAPI) backend. The app bootstraps the backend on launch, including venv creation and dependency installation.

## Build and Run

The project is a Swift Package Manager executable (swift-tools-version 6.2, macOS 26+).

```bash
# Build (from SwiftTubeApp/)
cd SwiftTubeApp && swift build

# Build release
cd SwiftTubeApp && swift build -c release

# Run (the app bootstraps its own Python backend on launch)
cd SwiftTubeApp && swift run
```

There are no tests. There is no linter configured.

## Architecture

### Two-process design

1. **Swift frontend** (`SwiftTubeApp/Sources/SwiftTubeApp/`) - SwiftUI macOS app
2. **Python backend** (`SwiftTubeApp/Sources/SwiftTubeApp/Resources/backend/`) - FastAPI server bundled as a resource, copied to `~/Library/Application Support/SwiftTube/` at runtime

The frontend spawns the backend as a `uvicorn` subprocess on `127.0.0.1:4891`. `BackendManager` handles the full lifecycle: Python discovery, venv bootstrap, dependency install, process launch, health polling. `BackendClient` is a singleton HTTP client for all API calls.

### Backend API (Python, FastAPI)

- `GET /health` - health check with instance ID
- `GET /recommendations?continuation=` - home feed via InnerTube (`innertube` library)
- `GET /video/{video_id}` - video metadata + streams (uses `yt-dlp` + InnerTube player)
- `GET /video/{video_id}/comments` - comments
- `GET /auth/status`, `POST /auth/browser`, `DELETE /auth/session` - browser cookie auth

Key backend files:
- `app/main.py` - FastAPI routes, InnerTube clients, request orchestration
- `app/playback.py` - yt-dlp stream extraction, quality scoring, stream validation
- `app/parse.py` - InnerTube response parsing (video items, metadata, comments)
- `app/auth.py` - browser cookie import via yt-dlp cookie extraction
- `app/provider.py` - authenticated yt-dlp option builder

### Playback engine abstraction

Two playback backends behind a shared `PlaybackEngine` protocol:
- `AVFoundationPlaybackEngine` - for HLS manifests and muxed streams
- `MPVPlaybackEngine` - for adaptive (separate video+audio) via MPVKit

`PlayerPlaybackCoordinator` is the central playback controller. It selects the engine based on `playbackStrategy` from the backend ("manifest" -> AVFoundation, "mpv" -> MPV, "direct" -> AVFoundation), manages quality switching, subtitles, theater/fullscreen modes, and scrubbing.

### Navigation

`AppNavigationModel` manages a stack-based navigation with back/forward between `.home` and `.video(VideoItem)` routes.

### Key environment objects

`SwiftTubeApp` (@main) creates three `@StateObject`s injected as `@EnvironmentObject`:
- `BackendManager` - backend process lifecycle
- `AppNavigationModel` - route state
- `AuthSessionModel` - YouTube auth state

## Commit conventions (from AGENTS.md)

- Create a git commit after every change set that materially updates code or configuration
- Keep commits small and focused; avoid bundling unrelated changes
- Use clear, present-tense commit messages (e.g., "Add backend bootstrap", "Fix navigation routing")
- Before committing, check `git status` and include only intended files
- Do not commit secrets or large binary artifacts
- When making material app changes, also update the user-visible app version in `SwiftTube > About`. Keep that version in sync with the build metadata used for the packaged app

## Versioning and Packaging

- The app version lives in `SwiftTubeApp/VERSION` (single line, e.g., `0.5.19`)
- Build number is auto-derived from `git rev-list --count HEAD`
- `SwiftTubeApp/build_app.sh` builds the app bundle at `SwiftTubeApp/Build/SwiftTube.app`
  - Runs `swift build`, copies the binary + resources, embeds frameworks, and codesigns
  - Reads version from `VERSION` file, writes `Info.plist` with `CFBundleShortVersionString`

## Dependencies

Swift: `MPVKit` (>= 0.41.0) for libmpv video playback

Python (`requirements.txt`): `fastapi`, `uvicorn`, `innertube`, `pydantic`, `httpx`, `yt-dlp`, `bgutil-ytdlp-pot-provider`

## Environment variables

- `SWIFTTUBE_BACKEND` - override backend base URL (default: `http://127.0.0.1:4891`)
- `SWIFTTUBE_PYTHON_PATH` - override Python executable for venv
- `SWIFTTUBE_APP_SUPPORT_DIR` - passed to backend for data storage
- `SWIFTTUBE_INSTANCE_ID` - unique per launch, used for health check identity
- `SWIFTTUBE_APP_VERSION` - passed to backend
