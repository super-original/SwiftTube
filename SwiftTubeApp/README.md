# SwiftTube macOS App

Open the built `SwiftTube.app` and it will start its in-process Swift backend automatically.

The app no longer boots a bundled Python or FastAPI bridge on launch.
Authenticated YouTube cookie import can still use `yt-dlp` as an external helper when available.
