# SwiftTube Personal Authentication Plan

## Goal

Enable a single-user, local-only sign-in flow so SwiftTube can load:

- your real Home feed instead of the current Explore fallback
- personalized watch recommendations
- account-specific actions later if you want them

This plan is intentionally optimized for a personal macOS app, not a multi-user production service.

## What the repo does today

- The backend uses unauthenticated `InnerTube("WEB")` for recommendations and watch-page metadata.
- When YouTube refuses a real Home feed because history/auth context is missing, the app falls back to Explore-like content.
- Playback now uses `yt-dlp` for higher quality streams, but recommendations are still driven by unauthenticated `innertube`.

## Recommended rollout

### Phase 1: Manual cookie auth first

This is the fastest path and matches the GitHub issue you attached.

1. Add a local Settings screen in the macOS app with:
   - a paste field for the raw YouTube cookie header
   - a short helper explaining that `SID`, `HSID`, `SSID`, `APISID`, and `SAPISID` are the important values
   - a "Validate" button and a "Remove account" button
2. Store the cookie string in the macOS Keychain.
3. On backend startup, read the cookie from the app and inject these headers into the `InnerTube` `httpx` sessions:
   - `Cookie: ...`
   - `Authorization: SAPISIDHASH <timestamp>_<sha1(timestamp + " " + sapisid + " " + origin)>`
   - `x-origin: https://www.youtube.com`
4. Reuse those headers for `client_web` and `client_player`.
5. If authenticated `FEwhat_to_watch` succeeds, stop showing the Explore fallback notice.

Why this is the best first step here:

- it is much less work than full OAuth
- it fits a private, single-user app
- it should immediately unlock personalized recommendations
- the app can still stay fully local

## Concrete backend changes

### New auth helper

Create a small backend helper that:

- parses the cookie header into key/value pairs
- extracts `SAPISID`
- generates a fresh `SAPISIDHASH` per request
- applies headers to the underlying `InnerTube(...).adaptor.session`

The current code already has a clean insertion point:

- `SwiftTubeApp/Sources/SwiftTubeApp/Resources/backend/app/main.py`

The `innertube` library is using `httpx.Client`, so we can update session headers without forking the library.

### Suggested local API surface

- `GET /auth/status`
  - returns `signedIn`, `accountName`, `lastValidatedAt`, `error`
- `POST /auth/session`
  - accepts a cookie string from the local app only
- `DELETE /auth/session`
  - clears the local auth material

For a purely local app, this can stay bound to `127.0.0.1`.

## Concrete Swift app changes

### Settings UX

Add a settings sheet or toolbar action with:

- account state badge: `Signed out`, `Validating`, `Signed in`
- cookie paste textarea
- validation feedback with exact failure reasons
- a one-click "Refresh personalized feed" action after save

### Secure storage

Use Keychain for the cookie payload instead of `UserDefaults`.

That gives you:

- better protection for account cookies
- persistence across launches
- a cleaner path if you later swap cookies for OAuth tokens

## How personalized recommendations should work

Once auth is available:

- keep `GET /recommendations` as the app's single feed endpoint
- try authenticated `browse(browse_id="FEwhat_to_watch")` first
- only fall back to Explore when auth is missing or invalid
- expose the current feed source in the response so the UI can say `Home`, `Explore fallback`, or `Signed out`

That means the home screen can stay simple while still surfacing the right state.

## What to do about OAuth

### Short version

For this app, I would not start with OAuth.

### Why

- the cookie flow is enough for a private app
- device-code / TV OAuth is more work to implement and support
- the issue thread shows the TV flow is promising, but still more brittle and more time-consuming than just supporting cookies

### When OAuth becomes worth it

Move to OAuth if either of these becomes annoying:

- cookies expire often enough to hurt UX
- you want a cleaner sign-in experience with less manual copy/paste

If that happens, the best next option is the YouTube TV device flow referenced in the issue thread.

## Recommended final architecture

1. Ship manual cookie auth first.
2. Add signed-in Home feed and remove the Explore fallback for authenticated sessions.
3. Add account status and revalidation UX in the app.
4. Only then consider TV OAuth as a follow-up project.

That order gets you personalized recommendations quickly without overbuilding.
