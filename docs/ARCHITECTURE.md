# SwiftTube Architecture

## Overview

SwiftTube is a native macOS YouTube client built as a Swift Package Manager app.
The project is organized around four main layers:

1. SwiftUI app shell
2. In-process Swift backend actor
3. View models and optimistic mutation infrastructure
4. MPV-based playback stack

## App shell

Important files:

- `SwiftTubeApp/Sources/SwiftTubeApp/SwiftTubeApp.swift`
- `SwiftTubeApp/Sources/SwiftTubeApp/ContentView.swift`
- `SwiftTubeApp/Sources/SwiftTubeApp/SettingsView.swift`
- `SwiftTubeApp/Sources/SwiftTubeApp/AppNavigation.swift`

Responsibilities:

- create the main window and Settings window
- host Home, Search, History, playlists, and player routes
- provide shared environment objects
- own top-level UI customization such as theme selection and toolbar/search behavior

## In-process backend

Important files:

- `SwiftTubeApp/Sources/SwiftTubeApp/SwiftTubeBackend.swift`
- `SwiftTubeApp/Sources/SwiftTubeApp/YouTubeAPI.swift`
- `SwiftTubeApp/Sources/SwiftTubeApp/BackendClient.swift`
- `SwiftTubeApp/Sources/SwiftTubeApp/YouTubeAuth.swift`

Responsibilities:

- fetch feeds, search results, history, playlists, and watch metadata from YouTube
- normalize raw InnerTube-style payloads into app models
- coordinate authenticated vs public fallbacks
- handle playlist, rating, subscription, Watch Later, and history mutations
- maintain progress/watch-history state that the UI can merge in optimistically

The backend now lives inside the app process as Swift code. The old Python/FastAPI and external extractor paths are no longer part of the app architecture.

## View models and optimistic state

Important files:

- `SwiftTubeApp/Sources/SwiftTubeApp/ViewModels.swift`
- `SwiftTubeApp/Sources/SwiftTubeApp/MutationCenter.swift`
- `SwiftTubeApp/Sources/SwiftTubeApp/AppSettings.swift`

Responsibilities:

- transform backend responses into screen-specific published state
- manage pagination
- queue optimistic mutations and roll them back on failure
- emit success/error notifications through the shared notification center
- persist user preferences such as appearance, browse density, playback defaults, and notification behavior

## Playback stack

Important files:

- `SwiftTubeApp/Sources/SwiftTubeApp/PlayerView.swift`
- `SwiftTubeApp/Sources/SwiftTubeApp/PlayerPlaybackCoordinator.swift`
- `SwiftTubeApp/Sources/SwiftTubeApp/MPVPlaybackEngine.swift`
- `SwiftTubeApp/Sources/SwiftTubeApp/MPVMetalRenderView.swift`
- `SwiftTubeApp/Sources/SwiftTubeApp/SponsorBlockClient.swift`

Responsibilities:

- select startup streams and manual quality options
- drive MPV playback, scrubbing, subtitles, volume, and speed
- sync watch progress back into the local/backend model
- render storyboard scrub previews
- show SponsorBlock markers and optionally auto-skip sponsor segments

## Shared models

Important file:

- `SwiftTubeApp/Sources/SwiftTubeApp/Models.swift`

This file holds the core cross-feature models, including:

- `VideoItem`
- `VideoPlayback`
- `VideoProgress`
- `PlaylistSummary`
- `PlaylistOption`
- `CommentItem`
- `SponsorBlockSegment`

## Packaging

Important files:

- `SwiftTubeApp/VERSION`
- `SwiftTubeApp/build_app.sh`

`build_app.sh`:

- builds the app
- packages the executable and SwiftPM resource bundle
- copies branding assets and changelog data into the app bundle
- embeds frameworks
- writes `Info.plist`
- codesigns the finished app
