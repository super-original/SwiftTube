# SwiftTube Playback Guide

## Playback architecture

Playback is centered around `PlayerPlaybackCoordinator`.

It is responsible for:

- preparing and switching MPV playback sources
- tracking current time, duration, and scrubbing state
- exposing quality, subtitles, volume, and playback-speed controls
- managing theater/fullscreen state
- forwarding progress updates back to the player view model

## MPV engine

`MPVPlaybackEngine` wraps libmpv through MPVKit.

Current behavior:

- startup stream selection prefers the best compatible stream for the selected quality policy
- manual quality switching uses in-place `replaceFile` instead of creating a whole new player session when possible
- Auto quality is available only for HLS master manifests and switches MPV video tracks inside the same playback session
- adaptive Auto decisions use MPV cache/throughput telemetry and avoid direct URL replacement
- storyboard scrub previews are layered above the render surface during dragging
- debug logging is disabled by default and can be re-enabled only through the `SWIFTTUBE_PLAYBACK_DEBUG_LOG=1` environment variable
- split-stream startup remains paused until both the video file and selected external audio decoder are ready, preventing the first video frames from advancing ahead of audio
- PiP transfers the existing MPV Metal render view between narrow AppKit hosts and forces a drawable rebind after the destination window and backing scale are valid
- collapsed PiP expansion is driven continuously by drag progress and settles only when distance or inward velocity crosses the expansion threshold

## Progress and end-of-playback behavior

SwiftTube tracks:

- YouTube-reported watch progress
- local exact-resume progress

When playback ends:

- the player records a finished progress update
- playlist loop rules still apply
- the player UI now enters a recoverable finished state with replay instead of getting stuck on a dead black frame

## SponsorBlock integration

SwiftTube currently uses SponsorBlock in a read-only way:

- fetch sponsor segments for the current video
- show sponsor markers on the timeline
- optionally auto-skip sponsor segments during playback

It does not support:

- segment submission
- voting
- category editing

Current implementation notes:

- only `sponsor` category segments with `skip` action are used
- data is fetched by `SponsorBlockClient`
- marker visibility and auto-skip behavior are controlled through `AppSettings`

## Player UI ownership

`PlayerView.swift` owns:

- the stage layout
- player chrome
- scrubber UI
- comments/recommendations composition around the stage
- end-state, loading-state, and error overlays

When playback originates from a playlist, the secondary panel owns a fixed-height,
independently scrolling queue. Its header remains pinned, the current item is centered
when the queue opens or advances, and macOS 27 reorder containers send one neighbor-aware
`browse/edit_playlist` mutation through the backend.

Keep coordinator logic in `PlayerPlaybackCoordinator` when a change affects playback state.
Keep `PlayerView.swift` focused on presentation and wiring.
