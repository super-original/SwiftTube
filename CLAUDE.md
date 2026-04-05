# CLAUDE.md

This repository-specific guide is for Claude Code and other AI agents that read this file.
It intentionally mirrors `AGENTS.md` so the repo has one consistent set of expectations.

## SwiftTube overview

SwiftTube is a personal macOS YouTube client built with SwiftUI and Swift Package Manager.
The app now uses an in-process Swift backend actor plus MPV playback. It does not launch a bundled Python or FastAPI backend anymore.
`yt-dlp` remains an external helper for browser-cookie import and stream extraction paths.

## Key locations

- App sources: `SwiftTubeApp/Sources/SwiftTubeApp/`
- Resources: `SwiftTubeApp/Sources/SwiftTubeApp/Resources/`
- Build/package script: `SwiftTubeApp/build_app.sh`
- App version: `SwiftTubeApp/VERSION`
- Changelog: `CHANGELOG.md`
- Supplemental docs: `docs/`

## Build commands

```bash
cd SwiftTubeApp && swift build
cd SwiftTubeApp && swift build -c release
cd SwiftTubeApp && swift run
cd SwiftTubeApp && zsh build_app.sh
```

There are no formal tests at the moment.

## Architecture map

- `SwiftTubeApp.swift`: app entry point and top-level environment setup
- `ContentView.swift`: shell UI, routing, feed/search/history/playlists
- `SettingsView.swift`: desktop settings UI and release-notes surface
- `SwiftTubeBackend.swift`: in-process backend actor for feed/search/history/player data and mutations
- `YouTubeAPI.swift`: raw YouTube/InnerTube networking layer
- `BackendClient.swift`: async facade used by view models
- `PlayerPlaybackCoordinator.swift`: playback state machine
- `MPVPlaybackEngine.swift`: MPV/libmpv wrapper
- `MutationCenter.swift`: queued optimistic mutations and notifications

## Expectations when changing the app

- Read the relevant code and docs first.
- Do not revert unrelated user work.
- Keep changes focused and easy to review.
- Commit after every material change set.
- Bump `SwiftTubeApp/VERSION` for material app changes.
- Rebuild the packaged app after version bumps with `cd SwiftTubeApp && zsh build_app.sh`.
- Update `CHANGELOG.md` whenever the version changes.

## Release rules

- The first version digit stays below `1` until the user explicitly approves `1.0`.
- The second digit only changes for major releases or when explicitly requested.
- Every future second-digit release must include a codename and a flagship theme in `CHANGELOG.md`.

## Documentation expectations

Keep these files aligned with the real codebase:

- `SwiftTubeApp/README.md`
- `AGENTS.md`
- `CLAUDE.md`
- `CHANGELOG.md`
- files in `docs/`
