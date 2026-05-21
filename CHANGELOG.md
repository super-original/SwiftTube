# SwiftTube Changelog

This file tracks shipped app changes by version.

Future second-digit releases, for example `0.12.x -> 0.13.0`, must include:

- a codename
- a flagship feature or clear release theme
- a matching changelog entry

## 0.15.4

- Removed the extra inline scrubber material background so the native blue slider itself is the bottom and raised hover control.
- Restored the bottom-to-raised scrubber animation with inset side gaps and kept storyboard hover previews layered above the control.

## 0.15.3

- Restyled inline thumbnail scrubbers around SwiftTube blue and the native macOS slider while keeping the bottom-to-hover animation.
- Reused the main player storyboard preview bubble for inline scrubber hover previews when storyboard tiles are available, with timestamp fallback.

## 0.15.2

- Tightened inline thumbnail playback startup by reducing the stable-hover delay and applying mute before first playback starts.
- Reworked the inline scrubber into a persistent bottom timeline that animates upward with side gaps and a timestamp hover state when the pointer is near it.

## 0.15.1

- Fixed inline thumbnail playback startup so hover preview fetches the first playable stream path before loading watch-page tracking data, cutting the slow multi-request startup delay.
- Kept the thumbnail visible until MPV is prepared, preventing failed or slow inline starts from flashing a black mini-player surface.

## 0.15.0 — Keystone

Theme: YouTube-style inline thumbnail playback.

- Added native MPV inline playback for video thumbnails after a stable hover delay, with quick-hover cancellation, muted startup, mute/unmute control, lower-region scrubbing, and resume positions that carry into full playback.
- Added a reduced inline playback backend path that fetches player/watch-page stream and tracking data without loading full watch-page side content, choosing low-cost streams and skipping unsupported livestream, upcoming, blocked, or unplayable videos.
- Routed Home, Search, channel grids, watch recommendations, history rows, and playlist rows through the reusable inline thumbnail surface while preserving static thumbnail behavior when inline playback is unavailable.
- Reused the existing local progress and YouTube watchtime tracking path for inline playback so continuous watched segments are recorded without counting scrub jumps as watched time.

## 0.14.9

- Fixed saved YouTube sessions so startup no longer validates-and-deletes the local cookie file or clears auth state after authenticated request fallbacks.
- Simplified SponsorBlock onboarding to one short description plus On/Off choices.
- Tightened onboarding previews by shrinking the player-control mock, keeping compact time on one line, left-aligning the signed-in account step with the rest of onboarding, and sizing grid thumbnails as real 16:9 blocks whose title bars match their width.

## 0.14.8

- Cleaned up onboarding by keeping the shell dark during theme selection, simplifying SponsorBlock setup to a description, tightening video-grid previews, fixing player-control previews, moving account loading into the chosen sign-in row, and showing privacy after sign-in.
- Stopped startup auth checks from re-importing browser cookies automatically, so SwiftTube uses its saved YouTube session until the user explicitly connects Chrome or Safari again.
- Delayed the initial home reload until auth status is loaded, preventing the signed-out Explore feed from flashing before signed-in recommendations appear.

## 0.14.7

- Fixed explicit YouTube disconnect so it clears the saved browser reconnect state instead of signing the account back in on the next auth-status refresh.

## 0.14.6

- Tightened onboarding so theme choices no longer recolor the onboarding shell, SponsorBlock and player-control setup are separate steps, and the player-control choice uses a closer preview of the real glass control bar.
- Made browse-grid presets resolve to actual fixed column counts for Compact, Default, and Large, and equalized the onboarding grid cards so Large no longer towers over the other choices.
- Reworked account onboarding into a browser-choice flow with real app icons, skipped the account step when already signed in, and added authenticated YouTube account-menu extraction for display name and email alongside the saved avatar.

## 0.14.5

- Rebuilt onboarding around the SwiftTube blue visual identity with a Mythic-style animated progress header, single primary Next flow, and preview-led theme, playback, grid, account, and privacy steps.
- Added a watch-progress privacy setting so SwiftTube can keep local history without sending watched-video progress to YouTube, with the settings pane explaining that YouTube recommendations will stop learning from those views.

## 0.14.4

- Replaced the browse-grid width slider with Compact, Default, and Large presets, defaulting the card width to 340 pt for a YouTube-like three-column layout and letting Large actually reach two-column sizing.
- Added first-time onboarding for theme, SponsorBlock, control layout, grid density, and optional YouTube session setup, with a restart button moved into a new Advanced settings pane alongside notification testing.
- Added the compact player-control layout, moved its scrubber above the controls without the separate scrubber pill, and kept the existing standard controls as the default.
- Made immersive theater/fullscreen side panels edge-to-edge, removed the nested panel treatment there, tightened recommendation rail spacing, and made letterboxed side bars count as player hover space for control fade behavior.
- Updated SponsorBlock category copy from the official category guidelines, changed new defaults to match the manual/disabled setup, added category names to scrub-hover previews, and enlarged storyboard hover previews.
- Fed mpv cache ranges into the player timeline as buffered gray ranges and deduplicated subtitle tracks more aggressively so repeated language variants like `English` and `English (en-orig)` collapse into one option.

## 0.14.3

- Stopped the player’s local keyboard monitor from eating app-level macOS shortcuts like `Command+Q` and `Command+W` while still silencing dead unmapped player key presses, and shrank the signed-out toolbar profile glyph so it no longer clips inside the circular slot.
- Replaced the paused-resize full MPV file reload with a same-time paused-frame refresh path, and covered player reload states with a storyboard-based held-frame preview so quality switches stop flashing the video’s first frame.
- Rewrapped the watch-page side rail so immersive fullscreen/theater tabs now sit inside the same contained card treatment as live chat, restored the playlist tab to that contained treatment on the standard page, removed the extra separators again, and tightened the live-chat bottom inset so the card stops getting clipped.
- Fixed playlist identity and persistence by using YouTube’s playlist item `setVideoId` as the reorder identity, which stabilizes drag/drop for duplicate videos and makes playlist-feed continuation merging preserve the real playlist order.
- Pushed page loading states closer to their real layouts by giving channel pages, playlist library, playlist feeds, and watch history dedicated skeletons instead of falling back to the generic recommendations placeholder grid.
- Improved auth recovery again by retrying authenticated requests after refreshing the last-used browser session, so recommendations, playlist pages, and video loads can automatically recover from stale cookies instead of leaving the app half-signed-in or forcing a manual reconnect first.

## 0.14.2

- Corrected the `0.14.1` sidebar regression by restoring plain standard-watch suggestions, putting standard live chat back into its own capped contained panel, and keeping the immersive fullscreen or theater rail as the place that owns the heavy sidebar container treatment.
- Fixed auth-expiry propagation so when authenticated YouTube requests fail, SwiftTube now invalidates the stale session, refreshes auth state through the last-used browser automatically, and updates the UI instead of silently acting signed in until you press the browser button again.
- Reworked the playlist side rail again so the playlist tab no longer nests its own full-height scroll view, uses a lighter divider-based row style, and scrolls through the shared immersive container instead of fighting it.
- Rebuilt the full playlist page rows toward the history-page model by removing the bulky per-row cards, dropping the fake `Now Playing` / `Video N` labels, centering the index handle better, and tightening the overall list density.

## 0.14.1

- Moved the auth avatar control to the far-right toolbar slot, removed the browser-name text from both signed-in and signed-out states, and dropped the old backend-status green dot so the top-right chrome is just the actual account control again.
- Fixed search-result opens that could collapse the results grid without navigating by routing to the destination first and only suspending the search surface on the next run loop.
- Removed the remaining special theater-mode watch layout so theater now uses the same immersive player and edge-hover behavior as fullscreen, just without entering macOS fullscreen.
- Rebuilt the side rail into a single shared panel surface: suggestions are no longer trapped in the old capped mini-scroll box, playlist mode keeps its artwork and loop/shuffle controls visible, and the old boxed/collapsible playlist queue was replaced with a cleaner lightweight list.
- Tightened next-up loading by letting immersive suggestions scroll in one full-height rail again, adding a bottom sentinel for pagination, and backfilling missing recommendation channel identity from full video metadata when YouTube’s recommendation renderer omits the channel endpoint or avatar.

## 0.14.0 — Fix the Fucking App

Theme: performance, optimization, and quality-of-life fixes.

- Reworked auth/session recovery so SwiftTube remembers the last browser login path, reuses that browser when the session expires, shows the real signed-in YouTube avatar in the toolbar, and uses a proper logged-out fallback message instead of blaming history settings.
- Fixed search and watch-page navigation regressions by making suggestion clicks submit correctly, preserving search-results state across video opens so back navigation returns to the actual results page, and restoring next-up pagination/scrolling when the suggestions rail gets long.
- Rebuilt the watch side rail so playlist queue, suggestions, and live chat share one tab system, moved the sidebar toggle into the immersive top-right overlay, made theater mode behave like fullscreen without leaving windowed mode, widened the player in the awkward stacked watch layout, and fixed the standard suggestions/sidebar clipping bug.
- Tightened player UI polish by adding the uploaded-date format toggle, switching theater and hold-speed icons to the requested symbols, widening row hit targets across popovers and panel tabs, shrinking the extra blank menu space in affected popovers, and restoring proper destructive styling for `Remove from Watch History`.
- Improved playback fidelity by deduplicating noisy subtitle tracks, suppressing unmapped-key macOS error beeps while the player is focused, and adding a paused-resize MPV refresh path so app-driven size changes stop leaving held frames stretched until playback resumes.
- Made watch-time syncing more accurate by matching YouTube’s `videostatsWatchtimeUrl` segment behavior more closely: paused/scrubbing playback no longer emits periodic syncs, large seek jumps no longer get reported as watched time, and contiguous watch ranges are flushed in bounded segments instead of blindly trusting raw playhead position jumps.
- Fixed the settings window into a truly fixed-size shell with the broken green zoom button disabled, hid `Liked Videos` and `Watch Later` from the playlists library page, aligned playlist-detail artwork with the playlist library art, and documented that the repository’s multi-gigabyte size is coming primarily from local SwiftPM build artifacts in `SwiftTubeApp/.build`.

## 0.13.21

- Fixed the remaining post-`0.13.16` live startup regressions by keeping `WEB_PARENT_TOOLS` HLS as the first live playback candidate, only falling back to watch-page live manifests when the proven path is missing, and making live startup order explicitly prefer the reliable HLS source YouTube still serves today.
- Stopped false `This video can’t be played` banners from watch-page and mobile player responses like `The page needs to be reloaded.` whenever another player source already returned real playable streams.
- Tightened live DVR fidelity by sizing the hidden storyboard buffer from the actual live sprite-sheet shape, exposing the reverse live offset beside the scrubber, and keeping hover previews aligned with the real live archive window.
- Rebuilt the settings window into a bounded native settings shell with a fixed-width non-collapsible sidebar, app-name header, removed sidebar toggle, and zoom/max-size behavior instead of broken fullscreen expansion.

## 0.13.20

- Fixed active livestream startup by preferring YouTube's HLS live manifest over the paired DASH manifest, which the FFmpeg/mpv stack can fail to open before playback becomes ready.

## 0.13.19

- Added an mpv startup timeout for initial media loads and replacement loads so bad livestream sources fail fast instead of leaving the player stuck on `Loading video...` forever.
- Made automatic startup walk multiple live playback candidates, so if the first manifest stalls the player now falls through to the next viable stream instead of giving up on the entire livestream open.

## 0.13.18

- Stopped active livestream startup from waiting on `yt-dlp` when native live manifests are already available, so the player can open YouTube’s `WEB_PARENT_TOOLS` HLS stream immediately instead of hanging behind fallback extraction work.
- Added a hard timeout to the optional `yt-dlp` playback extraction path so helper stalls degrade to native playback fallback instead of pinning the app on `Loading video...`.

## 0.13.17

- Fixed the 0.13.16 regression where active livestreams could sit on `Loading video...` forever by keeping watch-page live data for DVR and storyboard metadata while routing actual live playback back through the proven `WEB_PARENT_TOOLS` HLS manifest path.

## 0.13.16

- Switched active livestream playback to prefer the watch-page `ytInitialPlayerResponse` path, which exposes the same native HLS and DASH manifests YouTube’s own watch page uses instead of falling back to the weaker live extraction path.
- Parsed live DASH manifest metadata to recover YouTube’s full DVR window plus live storyboard segment timeline, so the scrubber can show the whole rewind buffer and hover previews can map onto the real live storyboard archive.
- Matched YouTube’s live-preview behavior more closely by hiding storyboard hover tiles right at the live edge where the newest storyboard files have not landed yet.

## 0.13.15

- Reworked live DVR scrubbing to read MPV's actual seekable live-range window instead of pretending livestreams always run from `0...duration`, which keeps the thumb moving across the real cached range, makes the `LIVE` button seek to the true edge, and lets live hover math use the same DVR coordinates.
- Fixed live storyboard preview lookup so hover and drag thumbnails stay relative to the current DVR window instead of falling off the end of the storyboard timeline, and made live-edge thumb pinning less jittery while playback rides the moving live window.

## 0.13.13

- Reworked live DVR playback so active livestreams prefer the manifest path before quality-based stream selection, changed the player scrubber to a clickable YouTube-style `LIVE` indicator with red or gray state instead of odd live time text, showed negative hover timestamps for live DVR previews, and pulled the standard watch-page live chat card back up so it stops closer to the action row.

## 0.13.12

- Anchored the standard watch-page live-chat card to the measured player-plus-header height so it stops at the action row again, added hover timestamps to live-chat messages, and tightened live DVR behavior by preferring the DASH live manifest while snapping the scrubber thumb to the live edge when playback is effectively current.

## 0.13.11

- Pulled the standard watch-page live-chat panel back down to its earlier height, fixed replay parsing so archived livestream chats stop falling into the empty-state message, and re-anchor replay chat when you reopen the tab or finish scrubbing so it follows the playback position instead of staying stuck at the old point.

## 0.13.10

- Moved player-page tags into the stats row so live badges stop shoving the action bar downward, stopped archived livestreams and premieres from using live playback controls by keying off YouTube’s `isLiveNow` flag, disabled active-live watch progress tracking and thumbnail progress bars, and made archived-stream chat use the replay endpoint with a `Live Chat Replay` tab title.

## 0.13.9

- Expanded live-chat hover targets to the full row width, tightened row spacing, added a reusable red `Live` video tag that can coexist with `Members only`, made the live-player scrubber show stream status instead of meaningless elapsed totals, and extended the standard watch-page live-chat panel closer to a full screen-height block before suggestions begin.

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
