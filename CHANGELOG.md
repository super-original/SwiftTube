# SwiftTube Changelog

This file tracks shipped app changes by version.

Future second-digit releases, for example `0.12.x -> 0.13.0`, must include:

- a codename
- a flagship feature or clear release theme
- a matching changelog entry

## 0.13.8

- Made the watch-history context-menu trash icon follow the same red destructive styling as the label, tightened the normal-view live-chat height against the actual window so the composer stops clipping offscreen, and removed the extra live-chat send context that was likely causing YouTube to reject outgoing messages with an internal error.

## 0.13.7

- Restored the SponsorBlock master control to a real switch while keeping it right-aligned, and removed the mismatched background fill from the sidebar navigation-items list.

## 0.13.6

- Trimmed the remaining card-level settings copy, moved the SponsorBlock master switch into a right-aligned control row, and merged seeking plus keybinds into a cleaner `Controls` pane to make the settings sidebar less fragmented.

## 0.13.5

- Switched the settings scene from a dedicated `Window` to the same `WindowGroup` plus unified hidden-titlebar configuration used by the main app so the native traffic lights and sidebar toggle follow the main window’s placement rules.

## 0.13.4

- Moved the settings UI off the macOS `Settings` scene into a normal app window with a custom `Settings...` command so it can use the same hidden-titlebar window shell as the main app.
- Removed more redundant settings copy, kept category descriptions terse, and added explicit agent guidance against writing marketing-style or redundant settings text again.
- Increased the standard watch-page live-chat height so suggestions stay below the fold until you scroll.

## 0.13.3

- Replaced the settings window sidebar implementation with the same native `NavigationSplitView` plus `List(selection:)` sidebar code path used by the main app, removing the custom sidebar rows entirely.

## 0.13.2

- Rebuilt the settings window sidebar into a direct row-based shell with proper selection states, matching spacing, and working clicks instead of relying on the broken list selection behavior from the previous hotfix.
- Simplified the watch side rail to just Suggestions and Live Chat, removed transcript tabs, capped the standard live-chat panel to a screen-height card with suggestions beneath it, and made fullscreen suggestions scrollable so the tab switcher never gets pushed offscreen.
- Polished live chat with hover interactions, cleaner author labels, highlighted official YouTube system notices, the refreshed `#FF0033` YouTube red token, and a corrected outgoing message payload so chat sends no longer fail immediately client-side.

## 0.13.1

- Restored the classic suggestions rail for standard videos by removing the new tab strip and card wrapper whenever the watch page only has next-up recommendations to show.
- Fixed live chat bootstrapping so the first chat fetch always starts from the real watch-page continuation before switching filters, which resolves the `Request contains an invalid argument.` failure on live streams.
- Replaced the settings window split-view shell with the app’s regular sidebar-style list layout again, removing the oversized sidebar toggle chrome and restoring normal clickable category selection.

## 0.13.0 — Pulse

Theme: Live playback, live chat, and a cleaner control surface.

- Added real livestream playback support by carrying HLS and DASH manifest URLs through the backend and teaching the MPV startup path to treat live manifests as valid playable streams instead of failing during preparation.
- Rebuilt the watch-page side rail into a full-height tabbed panel for Suggestions, Transcripts, and Live Chat, including a fullscreen sidebar toggle so chat can stay open without leaving fullscreen playback.
- Added live chat fetching and sending support, plus a redesigned avatar-free chat layout that colorizes usernames per author and keeps fast-moving messages easier to scan.
- Reworked Settings into a native split-view sidebar, folded video-grid sizing into Appearance, moved the changelog to the bottom of the category list, and cleaned up sidebar item reordering so it behaves more like the app’s other drag-and-drop lists.
- Retired the old dark baseline, promoted the previous Midnight palette into the new default Dark theme, introduced a true-black Midnight option, brightened the light themes, and added new Ruby, Meadow, and Glacier theme variants.

## 0.12.44

- Switched channel banners back to a fixed YouTube-style `16:9` aspect ratio and width-based scaling, so full-width pages no longer show side gaps and narrower windows no longer introduce top or bottom bands.

## 0.12.45

- Corrected channel banners to use the desktop-visible banner ratio `2560x338` instead of a video ratio, so channel headers stay banner-sized instead of expanding to a large hero block.

## 0.12.43

- Restored video tags in channel list view rows by switching that layout over to the shared tag-aware metadata chip renderer.
- Made channel banners scale responsively to the available detail width with fit-style rendering, which stops the banner itself from being cut off when the sidebar opens or the window narrows.

## 0.12.42

- Tightened the channel control bar by bringing button spacing closer within each group, flipping selected chips to the white subscribe-style state, and adding an `All` pseudo-filter that clears the member/public filter group back to its default state.
- Added a reusable custom video-tag system with icon, label, and color styling, then wired a green `Members only` tag into video cards, history rows, channel rows, playlist/queue rows, related videos, and compact attachment previews.
- Detected members-only and other blocked videos from InnerTube playability and badge data, so the player now keeps metadata visible and shows a clear access warning instead of hanging forever on inaccessible videos.

## 0.12.41

- Restyled the channel sort and filter controls to match the player’s pill buttons, so the browse chrome now feels consistent with the watch page actions.
- Capped community post cards to a fixed grid height, added compact attached-video previews, and moved full post reading into a dedicated “More” sheet to keep channel post grids aligned.
- Properly constrained channel pages to the split-view detail width and added an extra compact header fallback, which fixes the sidebar and window-resize clipping that was still pushing channel content offscreen.

## 0.12.40

- Replaced the channel sort dropdown with YouTube-style pill chips again, kept the official filter chips separate with dividers, and added persistent grid or list layout toggles for channel content tabs.
- Added list-row presentations for channel videos and playlists so tab content can switch between card grids and history-style rows without leaving the channel page.
- Tightened channel-page width behavior by giving the header a responsive compact layout and using channel-local adaptive grid sizing, which prevents the page from sliding offscreen when the sidebar opens.

## 0.12.39

- Switched channel-page subscription parsing over to YouTube’s real signed-in `subscribeButtonViewModel` plus `subscriptionStateEntity` payload, so refreshed channel pages now reflect the actual subscribed state from the channel header.
- Wired channel-page subscribe and unsubscribe command extraction directly from that header model, including the authenticated unsubscribe confirm flow exposed on YouTube’s own channel page.

## 0.12.38

- Stopped channel-page browse fallbacks from clearing the saved YouTube auth session, which fixes the channel subscribe flow randomly logging you out after a button press.
- Hardened the channel subscribe button state so a successful channel subscribe no longer snaps back to the unsubscribed look when a weaker follow-up payload comes back from YouTube.

## 0.12.37

- Removed the redundant top-left playback quality and speed badges from the player overlay.
- Restyled the keyboard lock indicator into a glass pill with a lock icon, and added a matching hold-speed pill that appears while spacebar speed boost is active.

## 0.12.36

- Removed the redundant channel header “more” affordances, turned channel sorting into a YouTube-style dropdown with separate filter chips, and kept the subscribe button actionable even when the page does not expose direct channel subscribe commands.
- Fixed the About tab layout so it scrolls naturally, and made raw links inside channel descriptions highlighted and clickable in the app.
- Restored playlist tab parsing for channels whose playlists are delivered through section-list grid renderers, which also preserves real playlist results for channels like Phoenix SC.

## 0.12.35

- Kept channel page headers alive while switching tabs so only the content area reloads, added a real About tab in the channel tab strip, and moved channel details out of the modal sheet.
- Split channel browse controls into separate filter and sort treatments, preserving official chip continuations while restoring the dedicated sort row style for video tabs.
- Shortened channel external links to their real destination URLs instead of showing YouTube redirect blobs, and wired the channel subscribe button to use authenticated channel-page subscription commands when available.

## 0.12.34

- Reworked channel headers to feel much closer to YouTube with a real tab strip, separate sort chips, a subscribe button, and banner layouts that no longer leave blank space or blow out the page.
- Fixed channel avatars and banners to prefer the highest-quality InnerTube image sources, which sharpens the header media noticeably on Retina displays.
- Expanded the channel details sheet with full external links, business-email entry points, and extra metadata from the official about payload.

## 0.12.33

- Added first-class channel pages with real YouTube channel tabs for Videos, Shorts, Live, Playlists, and Posts, including official sort chips where YouTube exposes them.
- Made channel names and profile pictures open the channel page from browse cards, history rows, related videos, and the player header.
- Wired the toolbar search to run official in-channel search requests while you are on a channel page, and added a details sheet backed by the channel’s official about payload.

## 0.12.32

- Restored the original simple SponsorBlock scrubber layering from the first SponsorBlock release by drawing the marker strip behind the native slider inside the same `ZStack`, and lifted the compact skip banner further above the control row.

## 0.12.31

- Lowered the sponsor segment strip inside the scrubber to match the native track position more closely, and lifted the compact skip banner so it clears the player controls.

## 0.12.30

- Removed the extra scrubber-track clipping left over from the later layout refactor so sponsor markers can sit like they did in `2e64f5b`, and redesigned the manual skip prompt into a compact bottom-right glass banner inspired by SponsorBlock.

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
