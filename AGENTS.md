# AGENTS.md

This file gives AI coding agents the ground truth for working in this repository.

## What SwiftTube is

SwiftTube is a personal macOS YouTube client built as a Swift Package Manager app.
It uses a native SwiftUI frontend, an in-process Swift backend actor for YouTube data
and mutations, and an MPV-based playback stack for all video playback.

There is no longer a bundled Python or FastAPI runtime in the app launch path.
Playback extraction and browser-cookie import are implemented entirely in native Swift.

## Project shape

- App package: `SwiftTubeApp/`
- Main Swift sources: `SwiftTubeApp/Sources/SwiftTubeApp/`
- Bundled app resources: `SwiftTubeApp/Sources/SwiftTubeApp/Resources/`
- Build script: `SwiftTubeApp/build_app.sh`
- App version file: `SwiftTubeApp/VERSION`
- Changelog: `CHANGELOG.md`
- Additional docs: `docs/`

## Build and run

```bash
# Build
cd SwiftTubeApp && swift build

# Release build
cd SwiftTubeApp && swift build -c release

# Run from source
cd SwiftTubeApp && swift run

# Build packaged app bundle
cd SwiftTubeApp && zsh build_app.sh
```

There are currently no automated tests.

## Core architecture

### App shell

- `SwiftTubeApp.swift` sets up the macOS window group and shared environment objects.
- `ContentView.swift` owns the main app surfaces: Home, Search, History, playlists, and player routing.
- `SettingsView.swift` owns the desktop settings window and release-notes viewer.

### In-process backend

- `SwiftTubeBackend.swift` is the app's data/backend actor.
- `YouTubeAPI.swift` handles raw HTTP requests to YouTube/InnerTube endpoints.
- `BackendClient.swift` is the UI-facing async facade used by view models.
- Authentication is managed locally through `YouTubeAuthManager` and related auth models.

### Playback

- `PlayerPlaybackCoordinator.swift` is the central playback state machine.
- `MPVPlaybackEngine.swift` wraps libmpv via MPVKit.
- `MPVMetalRenderView.swift` hosts the MPV render surface.
- Playback supports manual quality switching, storyboard scrub previews, local progress syncing, and SponsorBlock-based sponsor skipping.

### Mutations and optimistic UI

- `MutationCenter.swift` owns the queued mutation system and notification stack.
- Frontend actions apply immediately where possible, then reconcile against the backend in the background.
- Mutation completion is surfaced through the app's notification system.

## Docs to consult before making large changes

- `docs/ARCHITECTURE.md`
- `docs/PLAYBACK.md`
- `docs/RELEASE_PROCESS.md`
- `CHANGELOG.md`

## Workflow rules

- Inspect the current code before making assumptions.
- Never revert or overwrite user changes you did not make unless explicitly asked.
- Keep commits focused and small.
- After every material code or config change, create a git commit.
- After every material app change, bump `SwiftTubeApp/VERSION` before committing.
- After every version bump, rebuild the packaged app with `cd SwiftTubeApp && zsh build_app.sh`.
- Keep the About/version metadata in sync with `SwiftTubeApp/VERSION`.
- Update `CHANGELOG.md` for every shipped version change.
- When matching an existing app shell element such as a sidebar, titlebar, or settings window, reuse the same implementation pattern already used elsewhere in the app before inventing a custom approximation.
- In settings and preference UIs, keep copy terse and utilitarian. Do not add marketing-style taglines, cute product copy, or redundant explanatory blurbs. Default to short category descriptions only, and only add extra helper text when it is necessary to explain a non-obvious control.

## Versioning rules

- Do not update the first digit until the user explicitly says the app is ready for `1.0`.
- Only update the second digit for a major release or when the user explicitly wants it.
- The third digit can increase indefinitely.
- Every future second-digit release, for example `0.12.8 -> 0.13.0`, must include:
  - a release codename
  - a flagship feature or a clear release theme
  - a matching entry in `CHANGELOG.md`

## Repo cleanup expectations

When the user asks for repo cleanup or documentation work:

- prefer updating existing agent docs instead of adding contradictory files
- remove stale planning docs when they no longer match the codebase
- keep README and docs consistent with the actual implementation
- do not add throwaway assets or generated files unless they are intentionally part of the repo

## Commit guidance

- Use clear present-tense commit messages.
- Check `git status` before committing.
- Stage only the files that belong to the current change set.
- Do not commit secrets, personal cookies, browser exports, or large build artifacts.
