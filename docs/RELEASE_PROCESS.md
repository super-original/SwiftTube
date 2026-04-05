# SwiftTube Release Process

## Versioning

SwiftTube uses `SwiftTubeApp/VERSION` as the source of truth for the user-visible app version.

Rules:

- do not change the first digit until the user explicitly approves `1.0`
- only change the second digit for major releases or when explicitly requested
- the third digit is the normal patch/build feature counter

## Major-release naming

For every future second-digit release, for example `0.12.x -> 0.13.0`, the release must have:

- a codename
- a flagship feature or a clear release theme
- a matching changelog entry

Example format:

```md
## 0.13.0 — Aurora

Theme: Playback intelligence and queue polish.

- ...
```

## Required release updates

For every material shipped update:

1. update the code/config/docs
2. bump `SwiftTubeApp/VERSION`
3. update `CHANGELOG.md`
4. rebuild the packaged app with `cd SwiftTubeApp && zsh build_app.sh`
5. commit the change set

## Docs that must stay aligned

- `CHANGELOG.md`
- `SwiftTubeApp/README.md`
- `AGENTS.md`
- `CLAUDE.md`
- `docs/ARCHITECTURE.md`
- `docs/PLAYBACK.md`
- `docs/RELEASE_PROCESS.md`
