# SwiftTube Changelog

This file tracks shipped app changes by version.

Future second-digit releases, for example `0.12.x -> 0.13.0`, must include:

- a codename
- a flagship feature or clear release theme
- a matching changelog entry

## 0.12.29

- Restored the full scrubber row structure from `2e64f5b` so the sponsor overlay uses the same slider geometry as the version that rendered correctly, while preserving the separate ultrawide scrub-overlay fix.

## 0.12.28

- Restored the sponsor marker layering and alignment from `2e64f5b`, reverting the later masking experiment while keeping the separate ultrawide scrub-overlay fix.

## 0.12.27

- Kept sponsor markers visible over the played track while masking them out under the scrubber thumb, so sponsor segments no longer paint across the knob.

## 0.12.26

- Reattached sponsor markers directly to the native slider so they align with the real scrubber track again while staying visible over the played portion.

## 0.12.25

- Restored sponsor markers to render behind the scrubber thumb and track fill instead of above them, fixing the visual stacking regression introduced during the scrubber layout fixes.

## 0.12.24

- Fixed scrubbing on non-16:9 videos by constraining the full-frame storyboard overlay to the measured player stage, so ultrawide storyboard tiles can no longer widen the chrome layout during drag.

## 0.12.23

- Rebuilt the scrubber row so the time labels are anchored independently of the slider track, preventing scrubbing-only layout negotiation from stretching the control bar on affected videos.
- Clipped the scrubber track container itself so timeline overlays cannot draw or measure outside the row bounds.

## 0.12.22

- Pinned the player stage to its measured window size during scrubbing so storyboard overlays can no longer enlarge the stage and push the chrome off to the right on affected videos.
- Clipped the full-frame scrub storyboard overlay to the stage bounds to keep unusual storyboard dimensions from leaking into layout.

## 0.12.21

- Locked the player chrome to the stage width while scrubbing so preview updates can no longer stretch the scrubber row into the right-side controls.
- Fixed the scrub-preview bubble to use its intrinsic size only, avoiding layout spillover on videos that previously widened the timeline during drag.

## 0.12.20

- Restored SponsorBlock markers above the played progress track using a non-layout overlay.
- Added debug-only scrubber width logging so intermittent sponsored-video stretch cases can be measured directly when needed.

## 0.12.19

- Moved the SponsorBlock marker strip into a true non-layout background for the scrubber so sponsored videos stop stretching the timeline row to the right during drag.

## 0.12.18

- Removed the accidental infinite-height SponsorBlock marker layout that was blowing the scrubber glass surface up into a giant pill while dragging.

## 0.12.17

- Moved SponsorBlock segment rendering completely out of the native scrubber control so sponsored videos no longer let the slider drag the rest of the player chrome around.

## 0.12.16

- Fixed the player chrome resizing while scrubbing videos with SponsorBlock segments so the timeline and right-side controls stay locked in place.

## 0.12.15

- Fixed SponsorBlock scrubber jumps so dragging into or across marked segments no longer fights the final seek position.
- Added a dedicated SponsorBlock settings category with a global toggle and per-category behavior controls.
- Expanded SponsorBlock support to cover the main skip categories, colored timeline markers, and a manual side prompt that also responds to Return.

## 0.12.14

- Rebuilt the changelog screen into a proper structured release-notes view instead of rendering the markdown as a single blob of text.
- Fixed the SponsorBlock scrubber overlay layout so the player controls keep their intended size and shape.

## 0.12.13 — Playback polish

- Fixed the broken end-of-video player state by making playback recover into a replayable finished state instead of staying on a dead black frame.
- Added SponsorBlock integration for sponsor markers on the player timeline and optional auto-skip.
- Added a release-notes viewer to Settings backed by this changelog.
- Disabled MPV playback debug logging by default.
- Cleaned up and expanded repo documentation to match the current Swift-only architecture.

## 0.12.12

- Added adjustable Home/Search video card sizing in Settings.
- Increased the default browse card size to better match YouTube’s larger desktop layout.
- Relaxed browse-card title styling so titles truncate less aggressively.

## 0.12.11

- Fixed channel avatar lookup in recommendations, history, and next-up rows.
- Tightened the player header so the subscribe button sits next to the channel summary.

## 0.12.10

- Improved fallback avatar loading so non-search surfaces can resolve real channel icons in the background.

## 0.12.9

- Simplified the History screen heading and copy.
- Added richer notification preview tooling in Settings, including custom icon/color testing.
- Polished destructive styling for history removal controls.

## 0.12.8

- Moved the unified watch-progress bar flush to the thumbnail edge.
- Prioritized the SwiftTube progress bar and removed duplicate bar rendering.
- Cleaned up the History row metadata presentation.

## 0.12.7

- Refined the player action row layout so controls stay aligned with the channel block.
- Updated notifications to use a cleaner glass-style presentation.

## 0.12.6

- Added queued optimistic mutations for likes, subscriptions, Watch Later, playlist saves, and history removal.
- Added the unified in-app notification stack with configurable visibility, placement, and auto-hide.

## 0.12.5

- Polished search flow and tightened player action behavior.

## 0.12.4

- Fixed history progress rendering and deletion flow edge cases.

## 0.12.3

- Fixed history search and watch-history removal interactions.

## 0.12.2

- Fixed playback issues and refresh behavior while searching inside History.

## 0.12.1

- Polished the History layout and search interactions.

## 0.12.0 — Timekeeper

Theme: Watch history, local resume, and progress-aware browsing.

- Added the dedicated watch-history screen.
- Added local resume syncing layered on top of YouTube history progress.
- Started the `0.12` series around playback memory and history quality-of-life.

## 0.11.26

- Reduced playback extraction overhead.

## 0.11.25

- Added fallback behavior for public playback bundles.

## 0.11.24

- Switched to richer playback stream sources.

## 0.11.23

- Restored manual quality playback options.

## 0.11.22

- Fixed browser-auth session import.

## 0.11.21

- Rewrote the backend in Swift and removed the old app-embedded FastAPI bridge from the main runtime path.

## Earlier releases

- Older release history before `0.11.21` predates the maintained changelog and will be backfilled as those versions matter again.
