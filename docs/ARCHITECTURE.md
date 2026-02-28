# Architecture

## High-Level Structure

- `reactwatch/reactwatchApp.swift`
- `reactwatch/ContentView.swift`
- `reactwatch/DualPlayerViewModel.swift`
- `reactwatch/PlayerSurfaceView.swift`
- `reactwatch/YouTubePlayerView.swift`
- `reactwatch/FFmpegRemuxer.swift`

## UI Layer

`ContentView` is the primary view and handles:

- Layout for split mode and theatre mode
- Import actions
- URL sheet for reaction URL input
- Control panels (transport, reaction offset, subtitles, audio)
- Theatre-mode PiP gestures and auto-hide controls
- Alert presentation for playback/import errors

`PlayerSurfaceView` is a platform wrapper around `AVPlayerLayer`:

- `UIViewRepresentable` on iOS/visionOS
- `NSViewRepresentable` on macOS

`YouTubePlayerView` hosts a `WKWebView`-based YouTube iframe bridge.

## State and Playback Logic

`DualPlayerViewModel` is the app state/controller layer:

- Owns two `AVPlayer` instances (`primaryPlayer`, `reactionPlayer`)
- Owns `YouTubePlayerBridge` for reaction YouTube playback
- Publishes UI state (titles, loaded state, timeline, volumes, subtitles, alerts)
- Performs synchronized seeks/starts
- Corrects drift during dual playback
- Maintains reaction offset behavior

## Sync Strategy

- One shared timeline model (`currentSeconds`, `durationSeconds`)
- On dual seek, both sources are explicitly repositioned
- During dual playback, drift is corrected by:
  - hard seek when drift exceeds threshold
  - temporary rate adjustment for minor drift (non-YouTube)
  - coarse periodic correction for YouTube
- Offset can be recalculated when one side is paused and the other continues

## URL Ingestion

- YouTube URLs: parsed to video ID and loaded in embed player
- Vimeo page URLs: player config is parsed and candidate stream URLs selected
- Other HTTP(S): treated as direct media URL for AVPlayer

## MKV Pipeline (Current)

When `.mkv` is selected:

1. Try embedded FFmpeg remux (`FFmpegRemuxer`)
2. Try additional repair/export passes in AVFoundation
3. Try AVFoundation export from source asset
4. On macOS, optional system `ffmpeg` fallback if available

Converted outputs are cached in app caches (`ConvertedMedia`) using a hash of path + size + modification date.

## Embedded FFmpeg Integration

- Local package: `Vendor/FFmpegLocal`
- Binary targets: `Libavcodec`, `Libavformat`, `Libavutil`
- Build script: `scripts/build_ffmpeg_apple.sh`
- License notice: `THIRD_PARTY_NOTICES/FFmpeg.txt`
